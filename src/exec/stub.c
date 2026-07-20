#include <dirent.h>
#include <dlfcn.h>
#include <errno.h>
#include <fcntl.h>
#include <pthread.h>
#include <stddef.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

typedef ptrdiff_t choir_utf8proc_ssize_t;

typedef struct {
    void *handle;
    choir_utf8proc_ssize_t (*map)(
        const unsigned char *,
        choir_utf8proc_ssize_t,
        unsigned char **,
        int
    );
} choir_utf8proc_api;

static choir_utf8proc_api choir_utf8proc;
static pthread_once_t choir_utf8proc_once = PTHREAD_ONCE_INIT;
static int choir_utf8proc_load_result = -1;

static void choir_utf8proc_load_once(void) {
    void *handle = dlopen("libutf8proc.so.3", RTLD_NOW | RTLD_LOCAL);
    if (handle == NULL) {
        handle = dlopen("libutf8proc.so", RTLD_NOW | RTLD_LOCAL);
    }
    if (handle == NULL) {
        return;
    }
    *(void **)(&choir_utf8proc.map) = dlsym(handle, "utf8proc_map");
    if (choir_utf8proc.map == NULL) {
        dlclose(handle);
        memset(&choir_utf8proc, 0, sizeof(choir_utf8proc));
        return;
    }
    choir_utf8proc.handle = handle;
    choir_utf8proc_load_result = 0;
}

static int choir_utf8proc_load(void) {
    if (pthread_once(&choir_utf8proc_once, choir_utf8proc_load_once) != 0) {
        return -1;
    }
    return choir_utf8proc_load_result;
}

int choir_exec_path_nfc_available(void) {
    return choir_utf8proc_load() == 0;
}

int choir_exec_path_is_nfc(const char *path, int path_len) {
    if (path == NULL || path_len < 0 || choir_utf8proc_load() != 0) {
        return -1;
    }
    unsigned char *normalized = NULL;
    const int stable_compose = (1 << 1) | (1 << 3);
    choir_utf8proc_ssize_t normalized_len = choir_utf8proc.map(
        (const unsigned char *)path,
        (choir_utf8proc_ssize_t)path_len,
        &normalized,
        stable_compose
    );
    if (normalized_len < 0 || normalized == NULL) {
        free(normalized);
        return -1;
    }
    int result = normalized_len == (choir_utf8proc_ssize_t)path_len &&
        memcmp(path, normalized, (size_t)path_len) == 0;
    free(normalized);
    return result;
}

/*
 * Close every open fd in this process that is not stdio (0/1/2) and not the
 * listener fd we want to inherit. Without this, accepted client sockets (and
 * any other inherited fd) survive the execve and the new process holds them
 * open — clients that were mid-request see a hung connection instead of a
 * clean reset. Linux-only via /proc/self/fd, matching choir's target.
 */
static void choir_exec_close_non_inherited_fds(int keep_fd) {
    DIR *d = opendir("/proc/self/fd");
    if (d == NULL) {
        return;
    }
    int dir_fd = dirfd(d);
    struct dirent *entry;
    while ((entry = readdir(d)) != NULL) {
        if (entry->d_name[0] < '0' || entry->d_name[0] > '9') {
            continue;
        }
        int fd = atoi(entry->d_name);
        if (fd <= 2 || fd == keep_fd || fd == dir_fd) {
            continue;
        }
        close(fd);
    }
    closedir(d);
}

static char *choir_exec_copy_path(const char *path, int path_len) {
    if (path == NULL || path_len <= 0) {
        errno = EINVAL;
        return NULL;
    }
    char *copy = (char *)malloc((size_t)path_len + 1);
    if (copy == NULL) {
        errno = ENOMEM;
        return NULL;
    }
    memcpy(copy, path, (size_t)path_len);
    copy[path_len] = '\0';
    return copy;
}

int choir_exec_path_executable(const char *path, int path_len) {
    char *copy = choir_exec_copy_path(path, path_len);
    if (copy == NULL) {
        return -errno;
    }
    if (access(copy, X_OK) != 0) {
        int err = errno;
        free(copy);
        return -err;
    }
    free(copy);
    return 0;
}

int choir_exec_replace_self(const char *path, int path_len, int inherited_uds_fd) {
    char *copy = choir_exec_copy_path(path, path_len);
    if (copy == NULL) {
        return -errno;
    }
    if (access(copy, X_OK) != 0) {
        int err = errno;
        free(copy);
        return -err;
    }

    char fd_buf[32];
    snprintf(fd_buf, sizeof(fd_buf), "%d", inherited_uds_fd);
    if (setenv("CHOIR_INHERIT_UDS_FD", fd_buf, 1) != 0) {
        int err = errno;
        free(copy);
        return -err;
    }

    /*
     * Close all non-stdio, non-listener fds before execve so accepted client
     * sockets don't leak into the new process. The listener fd needs to keep
     * its FD_CLOEXEC=0 setting (that's set elsewhere in the reload path);
     * everything else is closed unconditionally.
     */
    choir_exec_close_non_inherited_fds(inherited_uds_fd);

    char *argv[] = {copy, "serve", NULL};
    execv(copy, argv);
    int err = errno;
    free(copy);
    return -err;
}
