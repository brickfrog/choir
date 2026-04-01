#include <errno.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <sys/un.h>
#include <unistd.h>

static char choir_cleanup_cmd[4096] = {0};

static void choir_sigterm_handler(int sig) {
    (void)sig;
    if (choir_cleanup_cmd[0] != '\0') {
        system(choir_cleanup_cmd);
    }
    _exit(0);
}

void choir_register_cleanup(const char* cmd) {
    snprintf(choir_cleanup_cmd, sizeof(choir_cleanup_cmd), "%s", cmd);
    signal(SIGTERM, choir_sigterm_handler);
    signal(SIGINT, choir_sigterm_handler);
}

int choir_get_file_size(const char* path) {
    FILE* f = fopen(path, "rb");
    if (!f) return -1;
    fseek(f, 0, SEEK_END);
    long size = ftell(f);
    fclose(f);
    return (int)size;
}

void choir_read_file_to_buf(const char* path, char* buf, int size) {
    FILE* f = fopen(path, "rb");
    if (!f) return;
    fread(buf, 1, size, f);
    fclose(f);
}

void choir_exit(int code) {
    exit(code);
}

void choir_stdout_write(const char *buf, int size) {
    fwrite(buf, 1, size, stdout);
    fflush(stdout);
}

void choir_stderr_write(const char *buf, int size) {
    fwrite(buf, 1, size, stderr);
    fflush(stderr);
}

int choir_stdin_read_line(char *buf, int max_size) {
    if (fgets(buf, max_size, stdin) == NULL) {
        return -1;
    }
    int len = strlen(buf);
    if (len > 0 && buf[len - 1] == '\n') {
        buf[len - 1] = '\0';
        return len - 1;
    }
    if (feof(stdin)) {
        return len;
    }
    return -(len + 1);
}

int choir_stdin_read(char *buf, int max_size) {
    if (max_size <= 0) {
        return 0;
    }
    size_t n = fread(buf, 1, (size_t)max_size, stdin);
    return (int)n;
}

int choir_getpid(void) {
    return (int)getpid();
}

int choir_kill_pid(int pid) {
    if (pid <= 0) {
        return 0;
    }
    if (kill((pid_t)pid, SIGTERM) == 0) {
        return 0;
    }
    if (errno == ESRCH) {
        return 0;
    }
    return -1;
}

int choir_spawn_serve(const char* exe, int exe_len) {
    char cmd[4096];
    (void)exe_len;
    snprintf(cmd, sizeof(cmd),
        "%s serve >> .choir/serve.log 2>&1 &", exe);
    return system(cmd);
}

static int choir_wait_for_uds_ready(const char* path) {
    struct sockaddr_un addr;
    size_t path_len = strlen(path);
    if (path_len >= sizeof(addr.sun_path)) {
        return -1;
    }

    memset(&addr, 0, sizeof(addr));
    addr.sun_family = AF_UNIX;
    memcpy(addr.sun_path, path, path_len);
    addr.sun_path[path_len] = '\0';

    int fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (fd < 0) {
        return -1;
    }

    int ok = connect(fd, (struct sockaddr*)&addr, sizeof(addr)) == 0 ? 0 : -1;
    close(fd);
    return ok;
}

int choir_wait_for_socket(const char* path, int max_tries) {
    for (int i = 0; i < max_tries; i++) {
        if (choir_wait_for_uds_ready(path) == 0) return 0;
        usleep(200000);
    }
    return -1;
}

int choir_system(const char* cmd) {
    return system(cmd);
}

int choir_getenv(const char* name, char* out, int out_size) {
    const char* value = getenv(name);
    if (!value || out_size <= 0) {
        return 0;
    }
    int len = (int)strlen(value);
    if (len >= out_size) {
        len = out_size - 1;
    }
    memcpy(out, value, (size_t)len);
    out[len] = '\0';
    return len;
}

void choir_write_pid_file(const char* path) {
    FILE* f = fopen(path, "w");
    if (!f) return;
    fprintf(f, "%d", (int)getpid());
    fclose(f);
}

static int choir_ensure_dir_path(const char* path) {
    char tmp[4096];
    snprintf(tmp, sizeof(tmp), "%s", path);
    int len = (int)strlen(tmp);
    if (len > 0 && tmp[len-1] == '/') tmp[len-1] = '\0';
    for (int i = 1; i < len; i++) {
        if (tmp[i] == '/') {
            tmp[i] = '\0';
            mkdir(tmp, 0755);
            tmp[i] = '/';
        }
    }
    mkdir(tmp, 0755);
    return 0;
}

int choir_create_dir_all(const char* path) {
    choir_ensure_dir_path(path);
    return 0;
}

int choir_write_file_sync(const char* path, const char* content, int content_len) {
    char dir[4096];
    snprintf(dir, sizeof(dir), "%s", path);
    char* slash = strrchr(dir, '/');
    if (slash) { *slash = '\0'; choir_ensure_dir_path(dir); }
    FILE* f = fopen(path, "wb");
    if (!f) return -1;
    if (content_len > 0) fwrite(content, 1, (size_t)content_len, f);
    fclose(f);
    return 0;
}

int choir_rename_file_sync(const char* from_path, const char* to_path) {
    return rename(from_path, to_path);
}

int choir_append_file_sync(const char* path, const char* content, int content_len) {
    char dir[4096];
    snprintf(dir, sizeof(dir), "%s", path);
    char* slash = strrchr(dir, '/');
    if (slash) { *slash = '\0'; choir_ensure_dir_path(dir); }
    FILE* f = fopen(path, "ab");
    if (!f) return -1;
    if (content_len > 0) fwrite(content, 1, (size_t)content_len, f);
    fclose(f);
    return 0;
}

int choir_delete_file_sync(const char* path) {
    return remove(path);
}
