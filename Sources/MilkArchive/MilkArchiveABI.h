// macOS SDK 26 supplies libarchive.tbd but omits its C headers. Opaque ABI
// declarations for the small, stable libarchive 3 reader surface used here.
// API reference: https://github.com/apple-oss-distributions/libarchive/tree/main/libarchive/libarchive
// No libarchive implementation or binary is vendored.
#include <stdint.h>
#include <sys/types.h>
#include <sys/stat.h>
#include <unistd.h>
#include <stddef.h>
struct archive;
struct archive_entry;
typedef int64_t la_int64_t;
typedef ssize_t la_ssize_t;
#define ARCHIVE_OK 0
#define ARCHIVE_EOF 1
#define AE_IFDIR S_IFDIR
#define AE_IFREG S_IFREG
struct archive *archive_read_new(void);
int archive_read_support_filter_gzip(struct archive *);
int archive_read_support_format_tar(struct archive *);
int archive_read_open_filename(struct archive *, const char *, size_t);
int archive_read_next_header(struct archive *, struct archive_entry **);
ssize_t archive_read_data(struct archive *, void *, size_t);
int archive_read_free(struct archive *);
const char *archive_error_string(struct archive *);
const char *archive_entry_pathname(struct archive_entry *);
const char *archive_entry_symlink(struct archive_entry *);
const char *archive_entry_hardlink(struct archive_entry *);
mode_t archive_entry_filetype(struct archive_entry *);
mode_t archive_entry_perm(struct archive_entry *);
int64_t archive_entry_size(struct archive_entry *);
