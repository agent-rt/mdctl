// mdctl C ABI. Header for libmdctl.dylib.
// SPDX-License-Identifier: MIT
//
// Convert documents (PDF / HTML / Office / images) to Markdown using Apple
// system frameworks. macOS 14+ only.

#ifndef MDCTL_H
#define MDCTL_H

#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef enum {
    MDCTL_FORMAT_AUTO = 0,
    MDCTL_FORMAT_TXT  = 1,
    MDCTL_FORMAT_CSV  = 2,
    MDCTL_FORMAT_JSON = 3,
    MDCTL_FORMAT_XML  = 4,
    MDCTL_FORMAT_HTML = 5,
    MDCTL_FORMAT_PDF  = 6,
    MDCTL_FORMAT_DOCX = 7,
    MDCTL_FORMAT_XLSX = 8,
    MDCTL_FORMAT_PPTX = 9,
    MDCTL_FORMAT_JPEG = 10,
    MDCTL_FORMAT_PNG  = 11,
} mdctl_format_t;

typedef struct {
    int format;            // mdctl_format_t value (0 = auto-detect)
    int readable;          // -1 = unset, 0 = off, 1 = strip nav/sidebar
    int ocr;               // 0 = off, 1 = run Vision OCR on images
    const char *pdf_pages; // optional "1-3,5,7-9" or NULL
} mdctl_options_t;

// Exit / error codes (also returned by mdctl_convert):
//   0 = success
//   1 = bad input / file not found
//   2 = conversion failed
//   3 = missing external dependency
//   4 = permission denied (e.g. Vision/Speech not authorized)
//   5 = unsupported format

// Convert a file at `path` to Markdown. URLs (http://, https://) are NOT
// supported via this entry point yet — the caller should fetch and pass a
// local path or, in a future revision, bytes.
//
// On success, *out_buf is set to a heap-allocated UTF-8 buffer of length
// *out_len (NOT null-terminated). The caller must free it via mdctl_free.
// Returns 0 on success, non-zero error code on failure.
int mdctl_convert(const char *path,
                  const mdctl_options_t *opts,
                  char **out_buf,
                  size_t *out_len);

// Release a buffer returned from mdctl_convert.
void mdctl_free(char *buf, size_t len);

// Library semantic version, NUL-terminated. Static; do not free.
const char *mdctl_version(void);

#ifdef __cplusplus
}
#endif

#endif // MDCTL_H
