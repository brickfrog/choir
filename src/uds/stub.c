#include <stddef.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <unistd.h>

static int choir_copy_uds_path(struct sockaddr_un *addr, const char *path, int path_len) {
    if (path_len < 0) {
        return -1;
    }
    if ((size_t)path_len >= sizeof(addr->sun_path)) {
        return -1;
    }

    memset(addr, 0, sizeof(*addr));
    addr->sun_family = AF_UNIX;
    if (path_len > 0) {
        memcpy(addr->sun_path, path, (size_t)path_len);
    }
    addr->sun_path[path_len] = '\0';
    return 0;
}

int choir_uds_server_create(const char *path, int path_len) {
    struct sockaddr_un addr;
    if (choir_copy_uds_path(&addr, path, path_len) != 0) {
        return -1;
    }

    unlink(addr.sun_path);

    int fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (fd < 0) {
        return -1;
    }

    if (bind(fd, (struct sockaddr *)&addr, sizeof(addr)) != 0) {
        close(fd);
        return -1;
    }

    if (listen(fd, SOMAXCONN) != 0) {
        close(fd);
        unlink(addr.sun_path);
        return -1;
    }

    return fd;
}

int choir_uds_accept(int server_fd) {
    return accept(server_fd, NULL, NULL);
}

int choir_uds_client_connect(const char *path, int path_len) {
    struct sockaddr_un addr;
    if (choir_copy_uds_path(&addr, path, path_len) != 0) {
        return -1;
    }

    int fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (fd < 0) {
        return -1;
    }

    if (connect(fd, (struct sockaddr *)&addr, sizeof(addr)) != 0) {
        close(fd);
        return -1;
    }

    return fd;
}

int choir_uds_read(int fd, void *buf, int offset, int len) {
    return (int)read(fd, ((char *)buf) + offset, (size_t)len);
}

int choir_uds_write(int fd, const void *buf, int offset, int len) {
    return (int)write(fd, ((const char *)buf) + offset, (size_t)len);
}

void choir_uds_close(int fd) {
    close(fd);
}
