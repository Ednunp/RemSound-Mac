#include "UpdateSupport.h"
#include "archive.h"
#include "archive_entry.h"
#include <ctype.h>
#include <errno.h>
#include <fcntl.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>

enum { chunk_bytes = 65536, maximum_path = 1024, maximum_depth = 64,
       entry_limit = 10000, seen_capacity = 32768,
       zip_byte_limit = 250000000, expanded_byte_limit = 1000000000 };

typedef struct {
    int fd;
    int64_t offset, length;
    uint64_t read_bytes, read_limit;
    double deadline;
    int timed_out;
    int item_limit_exceeded;
    uint32_t item_limit;
    unsigned char buffer[chunk_bytes];
} Reader;

static double monotonic(void) {
    struct timespec t;
    if (clock_gettime(CLOCK_MONOTONIC, &t) != 0) return INFINITY;
    return (double)t.tv_sec + (double)t.tv_nsec / 1000000000;
}

static int expired(Reader *r) {
    if (monotonic() < r->deadline) return 0;
    r->timed_out = 1;
    return 1;
}

static la_ssize_t read_archive(struct archive *a, void *context, const void **buffer) {
    Reader *r = context;
    if (expired(r)) { archive_set_error(a, ETIMEDOUT, "Update extraction timed out"); return -1; }
    if (r->offset >= r->length) return 0;
    size_t count = (size_t)(r->length - r->offset);
    if (count > chunk_bytes) count = chunk_bytes;
    if (count > r->read_limit - r->read_bytes) {
        archive_set_error(a, EFBIG, "Update ZIP read budget exceeded"); return -1;
    }
    ssize_t received;
    do {
        if (expired(r)) { archive_set_error(a, ETIMEDOUT, "Update extraction timed out"); return -1; }
        received = pread(r->fd, r->buffer, count, (off_t)r->offset);
    } while (received < 0 && errno == EINTR);
    if (received <= 0) {
        archive_set_error(a, EIO, "Update ZIP could not be read completely"); return -1;
    }
    r->offset += received;
    r->read_bytes += (uint64_t)received;
    *buffer = r->buffer;
    return received;
}

static la_int64_t seek_archive(struct archive *a, void *context, la_int64_t offset, int whence) {
    Reader *r = context;
    if (expired(r)) { archive_set_error(a, ETIMEDOUT, "Update extraction timed out"); return -1; }
    int64_t base;
    switch (whence) {
        case SEEK_SET: base = 0; break;
        case SEEK_CUR: base = r->offset; break;
        case SEEK_END: base = r->length; break;
        default: archive_set_error(a, EINVAL, "Invalid update ZIP seek"); return -1;
    }
    if ((offset > 0 && base > INT64_MAX - offset) || offset < -base || base + offset > r->length) {
        archive_set_error(a, EINVAL, "Update ZIP seeks outside its file"); return -1;
    }
    r->offset = base + offset;
    return r->offset;
}

static RSUpdateStatus failure(RSUpdateResult *result, RSUpdateStatus status, const char *message) {
    snprintf(result->error, sizeof(result->error), "%s", message);
    return status;
}

static int safe_path(const char *path, char *clean) {
    if (!path) return 0;
    size_t length = strnlen(path, maximum_path + 1);
    if (!length || length > maximum_path || path[0] == '/') return 0;
    // Fixed release bundle names and resources use printable ASCII. Excluding
    // Unicode/colon avoids normalization and HFS filename aliases at this boundary.
    for (size_t i = 0; i < length; ++i) {
        unsigned char c = (unsigned char)path[i];
        if (c < 32 || c > 126 || c == '\\' || c == ':') return 0;
    }
    if (path[length - 1] == '/') --length;
    if (!length) return 0;
    memcpy(clean, path, length);
    clean[length] = 0;
    unsigned depth = 0;
    const char *start = clean;
    for (const char *p = clean; ; ++p) {
        if (*p && *p != '/') continue;
        size_t size = (size_t)(p - start);
        if (!size || (size == 1 && start[0] == '.') || (size == 2 && start[0] == '.' && start[1] == '.')
            || ++depth > maximum_depth) return 0;
        if (!*p) break;
        start = p + 1;
    }
    return 1;
}

static int allowed_path(const char *path, const char *prefix, int is_directory, unsigned *bundle) {
    static const char *roots[] = {"RemSound.app", "Plugins/AU/RemSound.component",
        "Plugins/VST3/RemSound.vst3", "Plugins/CLAP/RemSound.clap"};
    static const char *parents[] = {"Plugins", "Plugins/AU", "Plugins/VST3", "Plugins/CLAP"};
    size_t size = strlen(prefix);
    if (strcmp(path, prefix) == 0) return is_directory;
    if (strncmp(path, prefix, size) || path[size] != '/') return 0;
    const char *relative = path + size + 1;
    for (unsigned i = 0; i < 4; ++i) {
        size_t root_size = strlen(roots[i]);
        if (strcmp(relative, roots[i]) == 0) return is_directory;
        if (!strncmp(relative, roots[i], root_size) && relative[root_size] == '/') {
            if (!is_directory) *bundle |= 1u << i;
            return 1;
        }
        if (is_directory && strcmp(relative, parents[i]) == 0) return 1;
    }
    return 0;
}

static int record_path(char **seen, const char *path, Reader *reader) {
    char folded[maximum_path + 1];
    uint32_t hash = 2166136261u;
    size_t i;
    for (i = 0; path[i]; ++i) {
        unsigned char c = (unsigned char)path[i];
        if (c >= 'A' && c <= 'Z') c += 'a' - 'A';
        folded[i] = (char)c;
        hash = (hash ^ c) * 16777619u;
    }
    folded[i] = 0;
    for (size_t probe = 0; probe < seen_capacity; ++probe) {
        if (expired(reader)) return 0;
        size_t slot = (hash + probe) % seen_capacity;
        if (!seen[slot]) { seen[slot] = strdup(folded); return seen[slot] != NULL; }
        if (!strcmp(seen[slot], folded)) return 0;
    }
    return 0;
}

static int same_spelling(int fd, const char *component) {
    char path[maximum_path + 1];
    if (fcntl(fd, F_GETPATH, path) != 0) return 0;
    const char *name = strrchr(path, '/');
    return name && strcmp(name + 1, component) == 0;
}

static int open_directory(int parent, const char *name, Reader *reader, RSUpdateResult *result) {
    int directory = openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
    if (directory < 0 && errno == ENOENT) {
        if (result->created_items >= reader->item_limit) { reader->item_limit_exceeded = 1; return -1; }
        if (mkdirat(parent, name, 0755) != 0) return -1;
        ++result->created_items;
        directory = openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
        if (directory >= 0 && fchmod(directory, 0755) != 0) { close(directory); return -1; }
    }
    if (directory < 0 || !same_spelling(directory, name)) {
        if (directory >= 0) close(directory);
        return -1;
    }
    return directory;
}

static int parent_directory(int root, const char *path, char *leaf, Reader *reader, RSUpdateResult *result) {
    char copy[maximum_path + 1];
    strcpy(copy, path);
    int current = dup(root);
    if (current < 0) return -1;
    char *start = copy, *slash;
    while ((slash = strchr(start, '/')) != NULL) {
        *slash = 0;
        if (expired(reader)) { close(current); return -1; }
        int next = open_directory(current, start, reader, result);
        if (next < 0) {
            close(current);
            return -1;
        }
        close(current);
        current = next;
        start = slash + 1;
    }
    strcpy(leaf, start);
    return current;
}

RSUpdateStatus rs_update_extract(const char *zip_path, const char *destination,
    const char *payload_name, uint64_t maximum_zip_bytes, uint64_t maximum_output_bytes,
    uint32_t maximum_entries, double timeout_seconds, RSUpdateResult *result) {
    if (!result) return RS_UPDATE_INVALID;
    memset(result, 0, sizeof(*result));
    char prefix[maximum_path + 1];
    if (!zip_path || !destination || !safe_path(payload_name, prefix) || strchr(prefix, '/')
        || strlen(prefix) > 128 || maximum_zip_bytes == 0 || maximum_zip_bytes > zip_byte_limit
        || maximum_output_bytes == 0 || maximum_output_bytes > expanded_byte_limit
        || maximum_entries == 0 || maximum_entries > entry_limit
        || !isfinite(timeout_seconds) || timeout_seconds < 0 || timeout_seconds > 360)
        return failure(result, RS_UPDATE_INVALID, "Invalid update extraction limits or payload name.");

    Reader *reader = calloc(1, sizeof(*reader));
    if (reader) reader->fd = -1;
    unsigned char *output = malloc(chunk_bytes);
    char **seen = calloc(seen_capacity, sizeof(*seen));
    struct archive *archive = NULL;
    int root = -1, file = -1;
    RSUpdateStatus status = RS_UPDATE_ARCHIVE;
    unsigned bundle = 0;
    if (!reader || !output || !seen) { status = failure(result, RS_UPDATE_IO, "Update extraction memory is unavailable."); goto done; }
    reader->deadline = monotonic() + timeout_seconds;
    reader->read_limit = maximum_zip_bytes * 4;
    reader->item_limit = maximum_entries;
    if (expired(reader)) { status = failure(result, RS_UPDATE_TIMEOUT, "Update extraction timed out."); goto done; }
    reader->fd = open(zip_path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC);
    struct stat st;
    if (reader->fd < 0 || fstat(reader->fd, &st) != 0 || !S_ISREG(st.st_mode)
        || st.st_size <= 0 || (uint64_t)st.st_size > maximum_zip_bytes) {
        status = failure(result, RS_UPDATE_INVALID, "Update ZIP is not a bounded regular file."); goto done;
    }
    reader->length = st.st_size;
    if (mkdir(destination, 0700) != 0) {
        status = failure(result, RS_UPDATE_IO, "The update extraction folder must be new."); goto done;
    }
    result->created_root = 1;
    root = open(destination, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
    if (root < 0 || fstat(root, &st) != 0 || st.st_uid != geteuid() || (st.st_mode & 0777) != 0700) {
        status = failure(result, RS_UPDATE_IO, "The private update extraction folder could not be opened."); goto done;
    }
    result->root_device = (uint64_t)st.st_dev;
    result->root_inode = (uint64_t)st.st_ino;
    archive = archive_read_new();
    if (!archive || archive_read_support_filter_none(archive) != ARCHIVE_OK
        || archive_read_support_format_zip_seekable(archive) != ARCHIVE_OK
        || archive_read_set_seek_callback(archive, seek_archive) != ARCHIVE_OK
        || archive_read_open2(archive, reader, NULL, read_archive, NULL, NULL) != ARCHIVE_OK) {
        status = failure(result, RS_UPDATE_ARCHIVE, "The update ZIP could not be opened safely."); goto done;
    }
    for (;;) {
        if (expired(reader)) { status = failure(result, RS_UPDATE_TIMEOUT, "Update extraction timed out."); goto done; }
        struct archive_entry *entry = NULL;
        int code = archive_read_next_header(archive, &entry);
        if (code == ARCHIVE_EOF) break;
        if (code != ARCHIVE_OK || archive_format(archive) != ARCHIVE_FORMAT_ZIP
            || archive_filter_count(archive) != 1 || archive_filter_code(archive, 0) != ARCHIVE_FILTER_NONE) {
            status = failure(result, RS_UPDATE_ARCHIVE, "The update ZIP has invalid or unsupported metadata."); goto done;
        }
        // The reader chooses the local header's method, which may disagree with raw central metadata.
        // Its format name describes that choice before the first decoded data read.
        const char *format_name = archive_format_name(archive);
        const char *compression = format_name ? strrchr(format_name, '(') : NULL;
        if (!compression || (strcmp(compression, "(uncompressed)") != 0
            && strcmp(compression, "(deflation)") != 0)) {
            status = failure(result, RS_UPDATE_ARCHIVE, "The update ZIP uses unsupported compression."); goto done;
        }
        if (result->entries >= maximum_entries) {
            status = failure(result, RS_UPDATE_LIMIT, "The update ZIP contains too many entries."); goto done;
        }
        ++result->entries;
        mode_t type = archive_entry_filetype(entry);
        int is_directory = type == AE_IFDIR;
        int64_t declared = archive_entry_size(entry);
        if ((type != AE_IFREG && !is_directory) || archive_entry_symlink(entry) || archive_entry_hardlink(entry)
            || archive_entry_sparse_count(entry) != 0 || archive_entry_is_encrypted(entry)
            || !archive_entry_size_is_set(entry) || declared < 0 || (is_directory && declared != 0)) {
            status = failure(result, RS_UPDATE_ARCHIVE, "The update ZIP contains links or unsupported entry types."); goto done;
        }
        if ((uint64_t)declared > maximum_output_bytes - result->written_bytes) {
            status = failure(result, RS_UPDATE_LIMIT, "The update ZIP exceeds the extracted byte budget."); goto done;
        }
        char path[maximum_path + 1], leaf[maximum_path + 1];
        if (!safe_path(archive_entry_pathname(entry), path)
            || !allowed_path(path, prefix, is_directory, &bundle) || !record_path(seen, path, reader)) {
            status = failure(result, RS_UPDATE_ARCHIVE, "The update ZIP contains unexpected or duplicate paths."); goto done;
        }
        int parent = parent_directory(root, path, leaf, reader, result);
        if (parent < 0) { status = failure(result, RS_UPDATE_IO, "An update directory is unsafe or unavailable."); goto done; }
        if (is_directory) {
            file = open_directory(parent, leaf, reader, result);
            close(parent);
            if (file < 0 || !same_spelling(file, leaf)) {
                status = failure(result, RS_UPDATE_ARCHIVE, "The update ZIP contains a directory alias."); goto done;
            }
        } else {
            if (result->created_items >= reader->item_limit) {
                close(parent); status = failure(result, RS_UPDATE_LIMIT, "The update ZIP creates too many files or directories."); goto done;
            }
            file = openat(parent, leaf, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0600);
            close(parent);
            if (file < 0) { status = failure(result, RS_UPDATE_IO, "An update file is duplicate or unavailable."); goto done; }
            ++result->created_items;
        }
        uint64_t actual = 0;
        for (;;) {
            if (expired(reader)) { status = failure(result, RS_UPDATE_TIMEOUT, "Update extraction timed out."); goto done; }
            la_ssize_t count = archive_read_data(archive, output, chunk_bytes);
            if (count < 0) { status = failure(result, RS_UPDATE_ARCHIVE, "The update ZIP data or checksum is invalid."); goto done; }
            if (count == 0) break;
            if (is_directory || (uint64_t)count > maximum_output_bytes - result->written_bytes) {
                status = failure(result, RS_UPDATE_LIMIT, "The update ZIP exceeds the actual extracted byte budget."); goto done;
            }
            actual += (uint64_t)count;
            size_t offset = 0;
            while (offset < (size_t)count) {
                if (expired(reader)) { status = failure(result, RS_UPDATE_TIMEOUT, "Update extraction timed out."); goto done; }
                ssize_t written = write(file, output + offset, (size_t)count - offset);
                if (written < 0 && errno == EINTR) continue;
                if (written <= 0) { status = failure(result, RS_UPDATE_IO, "An update file could not be written."); goto done; }
                offset += (size_t)written;
                result->written_bytes += (uint64_t)written;
            }
        }
        if (actual != (uint64_t)declared) {
            status = failure(result, RS_UPDATE_ARCHIVE, "Update ZIP sizes disagree with extracted data."); goto done;
        }
        if (!is_directory && fchmod(file, 0600 | (archive_entry_perm(entry) & 0555)) != 0) {
            status = failure(result, RS_UPDATE_IO, "Update executable permissions could not be preserved."); goto done;
        }
        int closed = close(file);
        file = -1;
        if (closed != 0) { status = failure(result, RS_UPDATE_IO, "An update file could not be closed."); goto done; }
    }
    if (bundle != 15u) { status = failure(result, RS_UPDATE_ARCHIVE, "The update ZIP is missing a required bundle."); goto done; }
    if (archive_read_close(archive) != ARCHIVE_OK) {
        status = failure(result, RS_UPDATE_ARCHIVE, "The update ZIP did not finish cleanly."); goto done;
    }
    status = RS_UPDATE_OK;
done:
    if (reader && reader->item_limit_exceeded)
        status = failure(result, RS_UPDATE_LIMIT, "The update ZIP creates too many files or directories.");
    if (reader && reader->timed_out) status = failure(result, RS_UPDATE_TIMEOUT, "Update extraction timed out.");
    if (file >= 0) close(file);
    if (archive) archive_read_free(archive);
    if (root >= 0) close(root);
    if (reader && reader->fd >= 0) close(reader->fd);
    if (seen) for (size_t i = 0; i < seen_capacity; ++i) free(seen[i]);
    free(seen);
    free(reader);
    free(output);
    return status;
}
