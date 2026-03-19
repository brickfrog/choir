#include <stddef.h>
#include <stdio.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/time.h>
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

/* Fire-and-forget HTTP POST to a Unix domain socket.
   Returns 0 on success, -1 on failure.
   5-second send/recv timeout so a dead agent never blocks the server. */
int choir_uds_http_post(const char *sock_path, int path_len,
                        const char *body, int body_len) {
    struct sockaddr_un addr;
    if (choir_copy_uds_path(&addr, sock_path, path_len) != 0) return -1;

    int fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (fd < 0) return -1;

    struct timeval tv = {5, 0};
    setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, sizeof(tv));
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));

    if (connect(fd, (struct sockaddr *)&addr, sizeof(addr)) != 0) {
        close(fd);
        return -1;
    }

    char header[256];
    int header_len = snprintf(header, sizeof(header),
        "POST / HTTP/1.0\r\n"
        "Content-Type: application/json\r\n"
        "Content-Length: %d\r\n"
        "\r\n",
        body_len);

    write(fd, header, (size_t)header_len);
    if (body_len > 0) {
        write(fd, body, (size_t)body_len);
    }

    /* Drain response to avoid connection reset on the agent side */
    char resp[256];
    read(fd, resp, sizeof(resp));

    close(fd);
    return 0;
}
