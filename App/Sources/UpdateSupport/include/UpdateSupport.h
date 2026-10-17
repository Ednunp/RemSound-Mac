#ifndef REMSOUND_UPDATE_SUPPORT_H
#define REMSOUND_UPDATE_SUPPORT_H
#include <stdint.h>

typedef enum {
    RS_UPDATE_OK = 0,
    RS_UPDATE_INVALID = 1,
    RS_UPDATE_IO = 2,
    RS_UPDATE_ARCHIVE = 3,
    RS_UPDATE_LIMIT = 4,
    RS_UPDATE_TIMEOUT = 5
} RSUpdateStatus;

typedef struct {
    uint64_t written_bytes;
    uint32_t entries;
    uint32_t created_items;
    int created_root;
    uint64_t root_device;
    uint64_t root_inode;
    char error[256];
} RSUpdateResult;

// Creates a fresh owner-only extraction root. Never opens an existing root.
// Failure may leave partial files only inside the root it created; caller removes it.
// Call only after bounded raw ZIP metadata validation. The seekable reader
// indexes central entries before the caller can enforce its header limit.
RSUpdateStatus rs_update_extract(const char *zip_path, const char *destination,
    const char *payload_name, uint64_t maximum_zip_bytes, uint64_t maximum_output_bytes,
    uint32_t maximum_entries, double timeout_seconds, RSUpdateResult *result);
#endif
