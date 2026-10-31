#include <stddef.h>
// Extract regular files/directories only, rooted using openat. No links or special files.
int milk_extract_archive(const char *archive, const char *destination, char *error, size_t error_size);
