#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <sys/un.h>
#include <sys/wait.h>
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

/**
 * Init-time server shutdown: SIGTERM, brief delay, then SIGKILL. Ignores ESRCH (matches former
 * `kill ... 2>/dev/null` best-effort semantics).
 */
void choir_init_kill_server_pid_sequence(int pid) {
    if (pid <= 0) {
        return;
    }
    if (kill((pid_t)pid, SIGTERM) < 0 && errno != ESRCH) {
        /* best-effort */
    }
    usleep(300000);
    if (kill((pid_t)pid, SIGKILL) < 0 && errno != ESRCH) {
        /* best-effort */
    }
}

/**
 * Returns 1 if `kill(pid, 0)` succeeds (process exists and we can signal it), else 0.
 */
int choir_pid_is_alive(int pid) {
    if (pid <= 0) {
        return 0;
    }
    return kill((pid_t)pid, 0) == 0 ? 1 : 0;
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

int choir_chmod_mode(const char* path, int mode) {
    return chmod(path, (mode_t)mode);
}

int choir_symlink_force(const char* target, const char* linkpath) {
    (void)unlink(linkpath);
    return symlink(target, linkpath);
}

static volatile pid_t choir_zellij_subscribe_child = 0;

static void choir_zellij_subscribe_on_term(int sig) {
    (void)sig;
    pid_t z = choir_zellij_subscribe_child;
    if (z > 0) {
        kill(z, SIGTERM);
    }
    _exit(0);
}

/**
 * Fork a supervisor that runs `zellij --session ... subscribe pane-viewport --pane-id ... --format json`,
 * discards stderr, and overwrites snapshot_path with each complete line read from zellij stdout.
 * Returns the supervisor PID for best-effort teardown via kill_pid_best_effort, or -1 on failure.
 */
int choir_spawn_zellij_pane_viewport_subscribe(
    const char* session,
    const char* pane_id,
    const char* snapshot_path) {
    int pipefd[2];
    if (pipe(pipefd) != 0) {
        return -1;
    }
    pid_t sup = fork();
    if (sup < 0) {
        close(pipefd[0]);
        close(pipefd[1]);
        return -1;
    }
    if (sup > 0) {
        close(pipefd[0]);
        close(pipefd[1]);
        return (int)sup;
    }

    /* Supervisor: read zellij stdout and mirror each line to snapshot_path. */
    struct sigaction sa;
    memset(&sa, 0, sizeof(sa));
    sa.sa_handler = choir_zellij_subscribe_on_term;
    sigemptyset(&sa.sa_mask);
    sa.sa_flags = 0;
    sigaction(SIGTERM, &sa, NULL);
    sigaction(SIGINT, &sa, NULL);

    pid_t zj = fork();
    if (zj < 0) {
        close(pipefd[0]);
        _exit(1);
    }
    if (zj == 0) {
        close(pipefd[0]);
        int devnull = open("/dev/null", O_WRONLY);
        if (devnull >= 0) {
            dup2(devnull, STDERR_FILENO);
            close(devnull);
        }
        dup2(pipefd[1], STDOUT_FILENO);
        close(pipefd[1]);
        execlp(
            "zellij",
            "zellij",
            "--session",
            session,
            "subscribe",
            "pane-viewport",
            "--pane-id",
            pane_id,
            "--format",
            "json",
            (char*)NULL);
        _exit(127);
    }

    choir_zellij_subscribe_child = zj;
    close(pipefd[1]);

    FILE* in = fdopen(pipefd[0], "r");
    if (!in) {
        kill(zj, SIGTERM);
        waitpid(zj, NULL, 0);
        _exit(1);
    }

    char* line = NULL;
    size_t linecap = 0;
    for (;;) {
        errno = 0;
        ssize_t n = getline(&line, &linecap, in);
        if (n < 0) {
            if (errno == EINTR) {
                continue;
            }
            break;
        }
        if (n > 0 && line[n - 1] == '\n') {
            line[n - 1] = '\0';
            n--;
        }
        choir_write_file_sync(snapshot_path, line, (int)n);
    }

    free(line);
    fclose(in);
    kill(zj, SIGTERM);
    waitpid(zj, NULL, 0);
    _exit(0);
}

static int choir_spawn_wait_stderr_null(char **argv) {
    pid_t pid = fork();
    if (pid < 0) {
        return -1;
    }
    if (pid == 0) {
        int dn = open("/dev/null", O_WRONLY);
        if (dn >= 0) {
            dup2(dn, STDERR_FILENO);
            close(dn);
        }
        execvp(argv[0], argv);
        _exit(127);
    }
    int st = 0;
    if (waitpid(pid, &st, 0) < 0) {
        return -1;
    }
    if (WIFEXITED(st)) {
        return WEXITSTATUS(st);
    }
    return -1;
}

void choir_worktree_bootstrap_cleanup(const char *project_dir, const char *workspace, const char *branch) {
    char *argv_prune[] = {"git", "-C", (char *)project_dir, "worktree", "prune", NULL};
    choir_spawn_wait_stderr_null(argv_prune);
    char *argv_rmwt[] = {"git", "-C", (char *)project_dir, "worktree", "remove", "--force", (char *)workspace, NULL};
    choir_spawn_wait_stderr_null(argv_rmwt);
    char *argv_rm[] = {"rm", "-rf", (char *)workspace, NULL};
    choir_spawn_wait_stderr_null(argv_rm);
    char *argv_bd[] = {"git", "-C", (char *)project_dir, "branch", "-D", (char *)branch, NULL};
    choir_spawn_wait_stderr_null(argv_bd);
}

void choir_git_fetch_origin_branch_best_effort(const char *project_dir, const char *branch) {
    struct stat st;
    if (stat(project_dir, &st) != 0 || !S_ISDIR(st.st_mode)) {
        fprintf(stderr, "choir: warning: could not cd to project directory %s\n", project_dir);
        return;
    }
    char *argv[] = {"git", "-C", (char *)project_dir, "fetch", "origin", (char *)branch, NULL};
    int code = choir_spawn_wait_stderr_null(argv);
    if (code != 0) {
        fprintf(stderr, "choir: warning: git fetch origin %s failed\n", branch);
    }
}
