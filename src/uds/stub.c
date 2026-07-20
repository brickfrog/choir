#define _GNU_SOURCE

#include <stddef.h>
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/stat.h>
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

static int choir_uds_can_connect(const struct sockaddr_un *addr) {
    int fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (fd < 0) {
        return 0;
    }
    int ok = connect(fd, (const struct sockaddr *)addr, sizeof(*addr)) == 0;
    close(fd);
    return ok;
}

static int choir_set_nonblocking(int fd) {
    int flags = fcntl(fd, F_GETFL, 0);
    if (flags < 0) {
        return -1;
    }
    if (fcntl(fd, F_SETFL, flags | O_NONBLOCK) != 0) {
        return -1;
    }
    return 0;
}

#if !(defined(__linux__) && defined(SOCK_CLOEXEC))
static int choir_set_cloexec(int fd) {
    int flags = fcntl(fd, F_GETFD, 0);
    if (flags < 0) {
        return -1;
    }
    if (fcntl(fd, F_SETFD, flags | FD_CLOEXEC) != 0) {
        return -1;
    }
    return 0;
}
#endif

static int choir_accept_cloexec(int server_fd) {
#if defined(__linux__) && defined(SOCK_CLOEXEC)
    return accept4(server_fd, NULL, NULL, SOCK_CLOEXEC);
#else
    int fd = accept(server_fd, NULL, NULL);
    if (fd >= 0 && choir_set_cloexec(fd) != 0) {
        int err = errno;
        close(fd);
        errno = err;
        return -1;
    }
    return fd;
#endif
}

int choir_uds_server_create(const char *path, int path_len) {
    struct sockaddr_un addr;
    if (choir_copy_uds_path(&addr, path, path_len) != 0) {
        return -1;
    }

    if (choir_uds_can_connect(&addr)) {
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

    if (chmod(addr.sun_path, 0600) != 0) {
        close(fd);
        unlink(addr.sun_path);
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
    return choir_accept_cloexec(server_fd);
}

int choir_uds_accept_nonblocking(int server_fd) {
    int fd = choir_accept_cloexec(server_fd);
    if (fd < 0 && (errno == EAGAIN || errno == EWOULDBLOCK)) {
        return -2;
    }
    return fd;
}

int choir_uds_peer_is_current_user(int fd) {
#ifdef __linux__
    struct ucred credential;
    socklen_t len = sizeof(credential);
    if (getsockopt(fd, SOL_SOCKET, SO_PEERCRED, &credential, &len) != 0 ||
        len != sizeof(credential)) {
        return 0;
    }
    return credential.uid == geteuid() ? 1 : 0;
#else
    (void)fd;
    return 0;
#endif
}

int choir_uds_peer_pid(int fd) {
#ifdef __linux__
    struct ucred credential;
    socklen_t len = sizeof(credential);
    if (getsockopt(fd, SOL_SOCKET, SO_PEERCRED, &credential, &len) != 0 ||
        len != sizeof(credential)) {
        return -1;
    }
    return (int)credential.pid;
#else
    (void)fd;
    return -1;
#endif
}

int choir_uds_fd_has_cloexec_for_test(int fd) {
    int flags = fcntl(fd, F_GETFD, 0);
    if (flags < 0) {
        return -1;
    }
    return (flags & FD_CLOEXEC) ? 1 : 0;
}

int choir_uds_unlink_path_for_test(const char *path, int path_len) {
    struct sockaddr_un addr;
    if (choir_copy_uds_path(&addr, path, path_len) != 0) {
        return -1;
    }
    return unlink(addr.sun_path);
}

int choir_uds_getpid_for_test(void) {
    return (int)getpid();
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

int choir_uds_read_nonblocking(int fd, void *buf, int offset, int len) {
    int n = (int)read(fd, ((char *)buf) + offset, (size_t)len);
    if (n < 0 && (errno == EAGAIN || errno == EWOULDBLOCK)) {
        return -2;
    }
    return n;
}

int choir_uds_write(int fd, const void *buf, int offset, int len) {
    return (int)write(fd, ((const char *)buf) + offset, (size_t)len);
}

void choir_uds_close(int fd) {
    close(fd);
}

int choir_uds_set_nonblocking(int fd) {
    return choir_set_nonblocking(fd);
}

int choir_uds_clear_cloexec(int fd) {
    int flags = fcntl(fd, F_GETFD, 0);
    if (flags < 0) {
        return -1;
    }
    return fcntl(fd, F_SETFD, flags & ~FD_CLOEXEC);
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

    ssize_t nw = write(fd, header, (size_t)header_len);
    (void)nw;
    if (body_len > 0) {
        ssize_t nb = write(fd, body, (size_t)body_len);
        (void)nb;
    }

    /* Drain response to avoid connection reset on the agent side */
    char resp[256];
    ssize_t nr = read(fd, resp, sizeof(resp));
    (void)nr;

    close(fd);
    return 0;
}
