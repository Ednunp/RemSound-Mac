Synthetic updater ZIP fixtures, version 1.2.3. No real application, user data or credentials.
Four bundle Info.plist placeholders contain 1234567890; executable contains fixture executable.
Malformed variants exercise path/type/CRC/size/ZIP64/duplicate checks. budget expands to100000 bytes; during-deadline expands to100000000 bytes.
FIFO must be refused by raw metadata preflight even when libarchive normalizes it to a regular file.
descriptor-valid uses ordinary signed data descriptors from a non-seekable ZIP writer; central-count-small understates five actual entries as four and must fail raw inspection.

compression-bzip2/lzma: tiny truthful ZIPs with unsupported release compression, refused during raw inspection before native decoder allocation. No large dictionary or OOM test.
compression-local-lzma: central entries claim stored compression while the tiny local bodies are LZMA; native method refusal is checked before the decoded-data read.
