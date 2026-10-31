#include "MilkArchive.h"
#include "MilkArchiveABI.h"
#include <fcntl.h>
#include <unistd.h>
#include <sys/stat.h>
#include <stdio.h>
#include <string.h>
#include <stdlib.h>
#include <errno.h>

static int parent(int root, char *path, char **leaf) {
    int fd = dup(root);
    char *part = path, *slash;
    while ((slash = strchr(part, '/'))) {
        *slash = 0;
        if (*part && strcmp(part, ".")) {
            if (mkdirat(fd, part, 0700) && errno != EEXIST) { close(fd); return -1; }
            int next = openat(fd, part, O_RDONLY|O_DIRECTORY|O_NOFOLLOW);
            close(fd); fd = next;
            if (fd < 0) return -1;
        }
        part = slash + 1;
    }
    *leaf = part; return fd;
}
int milk_extract_archive(const char *source, const char *destination, char *error, size_t error_size) {
    int root = open(destination, O_RDONLY|O_DIRECTORY|O_NOFOLLOW), result = -1;
    struct archive *a = archive_read_new(); struct archive_entry *entry;
    const char *problem = "Invalid or unsafe runtime archive";
    unsigned long long total = 0; unsigned count = 0;
    archive_read_support_filter_gzip(a); archive_read_support_format_tar(a);
    if (root < 0 || archive_read_open_filename(a, source, 65536) != ARCHIVE_OK) goto done;
    int status;
    while ((status = archive_read_next_header(a, &entry)) == ARCHIVE_OK) {
        const char *name = archive_entry_pathname(entry);
        if (!name || !*name || *name == '/' || strlen(name) > 4096 || ++count > 100000 ||
            archive_entry_symlink(entry) || archive_entry_hardlink(entry)) goto done;
        char *path = strdup(name), *scan = strdup(name), *save = NULL;
        int safe = 1;
        for (char *p = strtok_r(scan, "/", &save); p; p = strtok_r(NULL, "/", &save))
            if (!strcmp(p, "..") || strchr(p, '\\')) safe = 0;
        free(scan);
        if (!safe) { free(path); goto done; }
        size_t n = strlen(path); while (n && path[n-1] == '/') path[--n] = 0;
        if (!strcmp(path, ".") || !n) { free(path); continue; }
        char *leaf; int fd = parent(root, path, &leaf);
        if (fd < 0 || !*leaf) { if (fd >= 0) close(fd); free(path); goto done; }
        int type = archive_entry_filetype(entry), ok = 1;
        if (type == AE_IFDIR) {
            if (mkdirat(fd, leaf, 0700) && errno != EEXIST) ok = 0;
            int dir = openat(fd, leaf, O_RDONLY|O_DIRECTORY|O_NOFOLLOW);
            if (dir < 0) ok = 0; else close(dir);
        } else if (type == AE_IFREG) {
            la_int64_t size = archive_entry_size(entry);
            if (size < 0 || (unsigned long long)size > 1024ULL*1024*1024 || (total += size) > 1024ULL*1024*1024) ok = 0;
            int out = ok ? openat(fd, leaf, O_WRONLY|O_CREAT|O_EXCL|O_NOFOLLOW, 0600) : -1;
            if (out < 0) ok = 0;
            char buffer[65536]; la_ssize_t length;
            while (ok && (length = archive_read_data(a, buffer, sizeof(buffer))) > 0) {
                ssize_t offset = 0;
                while (offset < length) {
                    ssize_t written = write(out, buffer+offset, length-offset);
                    if (written <= 0) { ok = 0; break; }
                    offset += written;
                }
            }
            if (ok && length < 0) ok = 0;
            if (out >= 0) { if (fchmod(out, (archive_entry_perm(entry)&0111) ? 0700 : 0600) || fsync(out)) ok = 0; close(out); }
        } else ok = 0;
        close(fd); free(path);
        if (!ok) goto done;
    }
    if (status == ARCHIVE_EOF && count) result = 0;
done:
    if (result) snprintf(error, error_size, "%s: %s", problem, archive_error_string(a) ?: "entry rejected");
    archive_read_free(a); if (root >= 0) close(root);
    return result;
}
