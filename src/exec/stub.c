#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

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

    char *argv[] = {copy, "serve", NULL};
    execv(copy, argv);
    int err = errno;
    free(copy);
    return -err;
}
