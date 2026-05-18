#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <sys/un.h>
#include <sys/wait.h>
#include <time.h>
#ifdef __linux__
#include <sys/prctl.h>
#endif
#include <unistd.h>

static int choir_cleanup_runtime_native = 0;
static volatile sig_atomic_t choir_sigusr1_flag = 0;
static char choir_server_exit_log_buf[128];
#define CHOIR_MAX_SLEEP_MS_FOR_USLEEP (INT_MAX / 1000)

static int choir_append_literal(char *buf, int pos, int cap, const char *literal) {
    for (int i = 0; literal[i] != '\0'; i++) {
        if (pos >= cap) return -1;
        buf[pos++] = literal[i];
    }
    return pos;
}

static int choir_append_unsigned_decimal(char *buf, int pos, int cap, unsigned long long value) {
    char digits[32];
    int len = 0;
    if (value == 0) {
        digits[len++] = '0';
    } else {
        while (value > 0 && len < (int)sizeof(digits)) {
            digits[len++] = (char)('0' + (value % 10));
            value /= 10;
        }
    }
    while (len > 0) {
        if (pos >= cap) return -1;
        buf[pos++] = digits[--len];
    }
    return pos;
}

static int choir_append_signed_decimal(char *buf, int pos, int cap, long long value) {
    if (value < 0) {
        if (pos >= cap) return -1;
        buf[pos++] = '-';
        unsigned long long magnitude = (unsigned long long)(-(value + 1)) + 1u;
        return choir_append_unsigned_decimal(buf, pos, cap, magnitude);
    }
    return choir_append_unsigned_decimal(buf, pos, cap, (unsigned long long)value);
}

static int choir_format_server_exit_log_line(
    int sig,
    long long ts,
    long long pid,
    char *buf,
    int cap) {
    int pos = 0;
    pos = choir_append_literal(buf, pos, cap, "killed_by=SIG");
    if (pos < 0) return -1;
    pos = choir_append_signed_decimal(buf, pos, cap, (long long)sig);
    if (pos < 0) return -1;
    pos = choir_append_literal(buf, pos, cap, " sig=");
    if (pos < 0) return -1;
    pos = choir_append_signed_decimal(buf, pos, cap, (long long)sig);
    if (pos < 0) return -1;
    pos = choir_append_literal(buf, pos, cap, " ts=");
    if (pos < 0) return -1;
    pos = choir_append_signed_decimal(buf, pos, cap, ts);
    if (pos < 0) return -1;
    pos = choir_append_literal(buf, pos, cap, " pid=");
    if (pos < 0) return -1;
    pos = choir_append_signed_decimal(buf, pos, cap, pid);
    if (pos < 0) return -1;
    if (pos >= cap) return -1;
    buf[pos++] = '\n';
    return pos;
}

int choir_build_server_exit_log_line(int sig, int ts, int pid, char *buf, int max_size) {
    int len = choir_format_server_exit_log_line(
        sig,
        (long long)ts,
        (long long)pid,
        buf,
        max_size);
    if (len >= 0 && len < max_size) {
        buf[len] = '\0';
    }
    return len;
}

static long long choir_signal_timestamp_sec(void);

static int choir_write_server_exit_log_line_to_fd(
    int fd,
    int sig,
    long long ts,
    long long pid) {
    int len = choir_format_server_exit_log_line(
        sig,
        ts,
        pid,
        choir_server_exit_log_buf,
        (int)sizeof(choir_server_exit_log_buf));
    if (len <= 0) {
        return -1;
    }
    int written = 0;
    while (written < len) {
        ssize_t n = write(
            fd,
            choir_server_exit_log_buf + written,
            (size_t)(len - written));
        if (n < 0) {
            if (errno == EINTR) continue;
            return -1;
        }
        if (n == 0) return -1;
        written += (int)n;
    }
    return 0;
}

static int choir_append_server_exit_log_line_values(
    const char *path,
    int sig,
    long long ts,
    long long pid) {
    int fd = open(path, O_WRONLY | O_CREAT | O_APPEND, 0644);
    if (fd < 0) {
        return -1;
    }
    int rc = choir_write_server_exit_log_line_to_fd(
        fd,
        sig,
        ts,
        pid);
    close(fd);
    return rc;
}

int choir_append_server_exit_log_line(const char *path, int sig, int ts, int pid) {
    return choir_append_server_exit_log_line_values(
        path,
        sig,
        (long long)ts,
        (long long)pid);
}

static void choir_write_server_exit_log_line(int sig) {
    /* .choir/server-exits.log records fatal serve signals that can bypass MoonBit logging. */
    (void)choir_append_server_exit_log_line_values(
        ".choir/server-exits.log",
        sig,
        choir_signal_timestamp_sec(),
        (long long)getpid());
}

static int choir_is_crash_signal(int sig) {
    return sig == SIGSEGV || sig == SIGABRT || sig == SIGBUS;
}

static long long choir_signal_timestamp_sec(void) {
    struct timespec ts;
    if (clock_gettime(CLOCK_REALTIME, &ts) == 0) {
        return (long long)ts.tv_sec;
    }
    return 0;
}

static void choir_sigterm_handler(int sig) {
    choir_write_server_exit_log_line(sig);
    if (choir_cleanup_runtime_native) {
        unlink(".choir/server.pid");
        unlink(".choir/server.sock");
        unlink(".choir/run_id");
    }
    if (choir_is_crash_signal(sig)) {
        kill(getpid(), sig);
    }
    _exit(128 + sig);
}

void choir_register_cleanup_runtime_artifacts(void) {
    choir_cleanup_runtime_native = 1;
    signal(SIGTERM, choir_sigterm_handler);
    signal(SIGINT, choir_sigterm_handler);
}

void choir_install_crash_handlers(void) {
    struct sigaction sa;
    memset(&sa, 0, sizeof(sa));
    sa.sa_handler = choir_sigterm_handler;
    sigemptyset(&sa.sa_mask);
    sa.sa_flags = SA_RESETHAND | SA_NODEFER;
    sigaction(SIGSEGV, &sa, NULL);
    sigaction(SIGABRT, &sa, NULL);
    sigaction(SIGBUS, &sa, NULL);
}

static void choir_sigusr1_handler(int sig) {
    (void)sig;
    choir_sigusr1_flag = 1;
}

int choir_install_sigusr1_handler(void) {
    return signal(SIGUSR1, choir_sigusr1_handler) == SIG_ERR ? -1 : 0;
}

int choir_consume_sigusr1_flag(void) {
    sigset_t set;
    sigset_t oldset;
    sigemptyset(&set);
    sigaddset(&set, SIGUSR1);
    sigprocmask(SIG_BLOCK, &set, &oldset);
    int was_set = choir_sigusr1_flag ? 1 : 0;
    choir_sigusr1_flag = 0;
    sigprocmask(SIG_SETMASK, &oldset, NULL);
    return was_set;
}

int choir_raise_sigusr1_for_test(void) {
    return raise(SIGUSR1);
}

static int choir_signal_handler_installed(int sig, int require_crash_flags) {
    struct sigaction current;
    memset(&current, 0, sizeof(current));
    if (sigaction(sig, NULL, &current) != 0) {
        return 0;
    }
    if (current.sa_handler != choir_sigterm_handler) {
        return 0;
    }
    if (require_crash_flags &&
        ((current.sa_flags & SA_RESETHAND) == 0 ||
         (current.sa_flags & SA_NODEFER) == 0)) {
        return 0;
    }
    return 1;
}

int choir_server_exit_signal_handlers_installed(void) {
    return
        choir_signal_handler_installed(SIGTERM, 0) &&
        choir_signal_handler_installed(SIGINT, 0) &&
        choir_signal_handler_installed(SIGSEGV, 1) &&
        choir_signal_handler_installed(SIGABRT, 1) &&
        choir_signal_handler_installed(SIGBUS, 1);
}

void choir_reset_server_exit_signal_handlers(void) {
    signal(SIGTERM, SIG_DFL);
    signal(SIGINT, SIG_DFL);
    signal(SIGSEGV, SIG_DFL);
    signal(SIGABRT, SIG_DFL);
    signal(SIGBUS, SIG_DFL);
    choir_cleanup_runtime_native = 0;
}

void choir_init_cleanup_runtime_artifacts(void) {
    unlink(".choir/server.pid");
    unlink(".choir/server.sock");
    unlink(".choir/run_id");
}

int choir_get_file_size(const char* path) {
    FILE* f = fopen(path, "rb");
    if (!f) return -1;
    fseek(f, 0, SEEK_END);
    long size = ftell(f);
    fclose(f);
    return (int)size;
}

int choir_system(const char* cmd) {
    return system(cmd);
}

int choir_path_entry_exists(const char* path) {
    struct stat st;
    return stat(path, &st) == 0;
}

/* Recursive delete of `path` (file or directory).  Returns 0 on success
 * (including the idempotent "already gone" case) and -1 if any step failed.
 * Symbolic links are unlinked, not followed; traversal uses lstat.  Intended
 * for test-scaffolding use under /tmp, not as a general-purpose rm. */
int choir_rm_rf(const char *path) {
    struct stat st;
    if (lstat(path, &st) != 0) {
        return 0;
    }
    if (!S_ISDIR(st.st_mode)) {
        return unlink(path) == 0 ? 0 : -1;
    }
    DIR *d = opendir(path);
    if (!d) {
        return -1;
    }
    struct dirent *ent;
    char child[4096];
    int rc = 0;
    while ((ent = readdir(d)) != NULL) {
        if (strcmp(ent->d_name, ".") == 0 || strcmp(ent->d_name, "..") == 0) {
            continue;
        }
        int n = snprintf(child, sizeof(child), "%s/%s", path, ent->d_name);
        if (n < 0 || (size_t)n >= sizeof(child)) {
            rc = -1;
            continue;
        }
        if (choir_rm_rf(child) != 0) {
            rc = -1;
        }
    }
    closedir(d);
    if (rmdir(path) != 0) {
        rc = -1;
    }
    return rc;
}

/* Writes newline-separated entry names of `path` into `buf` (skipping "." and
 * "..").  Returns bytes written, or -1 if the directory could not be opened.
 * If the buffer would overflow, stops before the entry that would not fit —
 * caller sees a partial list with no indicator (sufficient for our use: the
 * caller expects small directories like .choir/kv and .choir/worktrees). */
int choir_list_dir(const char *path, char *buf, int max_size) {
    DIR *d = opendir(path);
    if (!d) {
        return -1;
    }
    struct dirent *ent;
    int total = 0;
    while ((ent = readdir(d)) != NULL) {
        if (ent->d_name[0] == '.') {
            continue;
        }
        int len = (int)strlen(ent->d_name);
        if (total + len + 1 > max_size) {
            break;
        }
        memcpy(buf + total, ent->d_name, (size_t)len);
        buf[total + len] = '\n';
        total += len + 1;
    }
    closedir(d);
    return total;
}

void choir_read_file_to_buf(const char* path, char* buf, int size) {
    FILE* f = fopen(path, "rb");
    if (!f) return;
    size_t n = fread(buf, 1, (size_t)size, f);
    (void)n;
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

int choir_set_parent_death_signal_term(void) {
#ifdef __linux__
    int rc = prctl(PR_SET_PDEATHSIG, SIGTERM, 0, 0, 0);
    if (rc == 0 && getppid() == 1) {
        raise(SIGTERM);
        _exit(0);
    }
    return rc;
#else
    return 0;
#endif
}

/**
 * Linux-only: walk `/proc/{pid}/cwd` symlinks and write decimal PIDs for every
 * process whose cwd matches `prefix` as newline-separated text into `buf`.
 *
 * A match requires `readlink(target)` to satisfy one of:
 *   - target == prefix                  (cwd is the workspace itself)
 *   - target == prefix + " (deleted)"   (workspace removed, cwd inode gone)
 *   - target starts with prefix + "/"   (cwd is nested inside the workspace)
 *   - target starts with prefix + "/"   and has the " (deleted)" suffix
 *
 * Skips the caller's own PID so choir never kills itself. Entries whose cwd
 * readlink fails (EACCES, ESRCH race, etc.) are silently ignored. Returns the
 * bytes written, capped at `max_size`; returns -1 if `/proc` cannot be opened.
 */
int choir_list_pids_with_cwd_prefix(const char *prefix, char *buf, int max_size) {
    /* An empty prefix would match via the vacuous `memcmp(_, _, 0) == 0`
     * branch and `target[0] == '/'` for almost every cwd on the system,
     * turning the helper into an enumerate-everything primitive. Reject
     * it at the FFI boundary (with a graceful zero-match) so MoonBit
     * callers that pass a stale or default-constructed workspace cannot
     * trigger a system-wide kill sweep. */
    if (!prefix || prefix[0] == '\0') {
        return 0;
    }
    if (!buf || max_size <= 0) {
        return -1;
    }
    DIR *d = opendir("/proc");
    if (!d) {
        return -1;
    }
    size_t plen = strlen(prefix);
    pid_t self_pid = getpid();
    struct dirent *ent;
    int total = 0;
    char link_path[64];
    char target[4096];
    static const char DELETED[] = " (deleted)";
    size_t del_len = sizeof(DELETED) - 1;
    while ((ent = readdir(d)) != NULL) {
        const char *name = ent->d_name;
        if (name[0] == '\0') {
            continue;
        }
        int is_num = 1;
        for (const char *p = name; *p; p++) {
            if (*p < '0' || *p > '9') { is_num = 0; break; }
        }
        if (!is_num) {
            continue;
        }
        pid_t pid = (pid_t)atoi(name);
        if (pid <= 0 || pid == self_pid) {
            continue;
        }
        int n = snprintf(link_path, sizeof(link_path), "/proc/%s/cwd", name);
        if (n < 0 || (size_t)n >= sizeof(link_path)) {
            continue;
        }
        ssize_t tlen = readlink(link_path, target, sizeof(target) - 1);
        if (tlen <= 0) {
            continue;
        }
        target[tlen] = '\0';
        size_t tlen_eff = (size_t)tlen;
        if (tlen_eff >= del_len &&
            memcmp(target + tlen_eff - del_len, DELETED, del_len) == 0) {
            tlen_eff -= del_len;
            target[tlen_eff] = '\0';
        }
        int match = 0;
        if (tlen_eff == plen && memcmp(target, prefix, plen) == 0) {
            match = 1;
        } else if (tlen_eff > plen &&
                   memcmp(target, prefix, plen) == 0 &&
                   target[plen] == '/') {
            match = 1;
        }
        if (!match) {
            continue;
        }
        char pidbuf[16];
        int pnlen = snprintf(pidbuf, sizeof(pidbuf), "%d\n", (int)pid);
        if (pnlen < 0) {
            continue;
        }
        if (total + pnlen > max_size) {
            break;
        }
        memcpy(buf + total, pidbuf, (size_t)pnlen);
        total += pnlen;
    }
    closedir(d);
    return total;
}

int choir_spawn_serve(const char* exe, int exe_len) {
    (void)exe_len; // Ensure unused param warning is avoided
    pid_t pid = fork();
    if (pid < 0) {
        return -1;
    }
    if (pid == 0) {
        // Child 1
        pid_t pid2 = fork();
        if (pid2 < 0) {
            _exit(127);
        }
        if (pid2 > 0) {
            // Child 1 exits, making Child 2 an orphan
            _exit(0);
        }
        // Child 2
        int fd = open(".choir/serve.log", O_WRONLY | O_CREAT | O_APPEND, 0644);
        if (fd >= 0) {
            dup2(fd, STDOUT_FILENO);
            dup2(fd, STDERR_FILENO);
            close(fd);
        }
        char* argv[] = { (char*)exe, "serve", NULL };
        execvp(exe, argv);
        _exit(127);
    }
    // Parent waits for Child 1
    int st = 0;
    waitpid(pid, &st, 0);
    return 0;
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

void choir_sleep_milliseconds(int ms) {
    if (ms <= 0) return;
    if (ms > CHOIR_MAX_SLEEP_MS_FOR_USLEEP) ms = CHOIR_MAX_SLEEP_MS_FOR_USLEEP;
    usleep((useconds_t)ms * 1000);
}

static int choir_term_resp_is_digit(char c) {
    return c >= '0' && c <= '9';
}

static int choir_term_resp_osc_end(const char* s, int len, int start) {
    if (start + 3 >= len || s[start] != '\033' || s[start + 1] != ']') {
        return -1;
    }
    int payload_start = -1;
    if (s[start + 2] == '4' && s[start + 3] == ';') {
        payload_start = start + 4;
    } else if (
        start + 4 < len &&
        s[start + 2] == '1' &&
        (s[start + 3] == '0' || s[start + 3] == '1') &&
        s[start + 4] == ';'
    ) {
        payload_start = start + 5;
    } else {
        return -1;
    }
    for (int j = payload_start; j < len; j++) {
        if (s[j] == '\007') return j + 1;
        if (j + 1 < len && s[j] == '\033' && s[j + 1] == '\\') return j + 2;
    }
    return -1;
}

static int choir_term_resp_primary_da_end(const char* s, int len, int start) {
    if (
        start + 3 >= len ||
        s[start] != '\033' ||
        s[start + 1] != '[' ||
        s[start + 2] != '?'
    ) {
        return -1;
    }
    int j = start + 3;
    int saw_digit = 0;
    while (j < len && (choir_term_resp_is_digit(s[j]) || s[j] == ';')) {
        if (choir_term_resp_is_digit(s[j])) saw_digit = 1;
        j++;
    }
    if (saw_digit && j < len && s[j] == 'c') return j + 1;
    return -1;
}

static int choir_term_resp_cpr_end(const char* s, int len, int start) {
    if (start + 4 >= len || s[start] != '\033' || s[start + 1] != '[') {
        return -1;
    }
    int j = start + 2;
    int row_start = j;
    while (j < len && choir_term_resp_is_digit(s[j])) j++;
    if (j == row_start || j >= len || s[j] != ';') return -1;
    j++;
    int col_start = j;
    while (j < len && choir_term_resp_is_digit(s[j])) j++;
    if (j == col_start || j >= len || s[j] != 'R') return -1;
    return j + 1;
}

static int choir_term_resp_end(const char* s, int len, int start) {
    int end = choir_term_resp_osc_end(s, len, start);
    if (end >= 0) return end;
    end = choir_term_resp_primary_da_end(s, len, start);
    if (end >= 0) return end;
    return choir_term_resp_cpr_end(s, len, start);
}

static int choir_write_all_fd(int fd, const char* buf, int len) {
    int written = 0;
    while (written < len) {
        ssize_t n = write(fd, buf + written, (size_t)(len - written));
        if (n < 0) {
            if (errno == EINTR) continue;
            return -1;
        }
        if (n == 0) return -1;
        written += (int)n;
    }
    return 0;
}

static int choir_write_stripped_terminal_responses_fd(int fd, const char* buf, int len) {
    int chunk_start = 0;
    int i = 0;
    while (i < len) {
        if (buf[i] == '\033') {
            int end = choir_term_resp_end(buf, len, i);
            if (end >= 0) {
                if (i > chunk_start && choir_write_all_fd(fd, buf + chunk_start, i - chunk_start) < 0) {
                    return -1;
                }
                i = end;
                chunk_start = i;
                continue;
            }
        }
        i++;
    }
    if (chunk_start < len) {
        return choir_write_all_fd(fd, buf + chunk_start, len - chunk_start);
    }
    return 0;
}

static void choir_stderr_append_filter_loop(int read_fd, int out_fd) {
    char buf[4096];
    for (;;) {
        ssize_t n = read(read_fd, buf, sizeof(buf));
        if (n < 0) {
            if (errno == EINTR) continue;
            break;
        }
        if (n == 0) break;
        if (out_fd >= 0 &&
            choir_write_stripped_terminal_responses_fd(out_fd, buf, (int)n) < 0) {
            close(out_fd);
            out_fd = -1;
        }
    }
    if (out_fd >= 0) close(out_fd);
    close(read_fd);
    _exit(0);
}

int choir_redirect_stderr_append(const char* path) {
    int out_fd = open(path, O_WRONLY | O_CREAT | O_APPEND, 0644);
    if (out_fd < 0) {
        return -1;
    }
    int pipefd[2];
    if (pipe(pipefd) < 0) {
        close(out_fd);
        return -1;
    }
    pid_t pid = fork();
    if (pid < 0) {
        close(out_fd);
        close(pipefd[0]);
        close(pipefd[1]);
        return -1;
    }
    if (pid == 0) {
        close(pipefd[1]);
        pid_t pid2 = fork();
        if (pid2 < 0) {
            close(out_fd);
            close(pipefd[0]);
            _exit(127);
        }
        if (pid2 > 0) {
            close(out_fd);
            close(pipefd[0]);
            _exit(0);
        }
        choir_stderr_append_filter_loop(pipefd[0], out_fd);
    }
    close(pipefd[0]);
    close(out_fd);
    int st = 0;
    if (waitpid(pid, &st, 0) < 0 || !WIFEXITED(st) || WEXITSTATUS(st) != 0) {
        close(pipefd[1]);
        return -1;
    }
    if (dup2(pipefd[1], STDERR_FILENO) < 0) {
        close(pipefd[1]);
        return -1;
    }
    close(pipefd[1]);
    return 0;
}

int choir_realpath(const char* path, char* out, int out_size) {
    if (!path || !out || out_size <= 0) return -1;
    char r_path[4096];
    if (realpath(path, r_path)) {
        int len = (int)strlen(r_path);
        if (len < out_size) {
            memcpy(out, r_path, len + 1);
            return len;
        }
    }
    return -1;
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

static void choir_rm_rf_best_effort(const char *path) {
    char *argv[] = {"rm", "-rf", (char *)path, NULL};
    choir_spawn_wait_stderr_null(argv);
}

void choir_init_cleanup_purge_artifacts(void) {
    DIR *wt = opendir(".choir/worktrees");
    if (wt) {
        struct dirent *ent;
        char path[4096];
        while ((ent = readdir(wt)) != NULL) {
            if (ent->d_name[0] == '.') {
                continue;
            }
            snprintf(path, sizeof(path), ".choir/worktrees/%s", ent->d_name);
            struct stat st;
            if (stat(path, &st) != 0) {
                continue;
            }
            if (S_ISDIR(st.st_mode)) {
                char *argv[] = {"git", "worktree", "remove", "--force", path, NULL};
                choir_spawn_wait_stderr_null(argv);
            }
        }
        closedir(wt);
    }
    choir_rm_rf_best_effort(".choir/worktrees");
    choir_rm_rf_best_effort(".choir/inline");
    choir_rm_rf_best_effort(".choir/outbox");
    choir_rm_rf_best_effort(".choir/waves");
    unlink(".choir/server.pid");
    unlink(".choir/server.sock");
    unlink(".choir/poller_state.json");
    unlink(".choir/run_id");
    DIR *kv = opendir(".choir/kv");
    if (kv) {
        struct dirent *ent;
        char kp[4096];
        while ((ent = readdir(kv)) != NULL) {
            if (ent->d_name[0] == '.') {
                continue;
            }
            const char *n = ent->d_name;
            if (strncmp(n, "lifecycle--", 11) != 0 && strncmp(n, "children--", 10) != 0 &&
                strncmp(n, "phase-dev--", 11) != 0 && strncmp(n, "phase-tl--", 10) != 0 &&
                strncmp(n, "pending-wave--", 14) != 0) {
                continue;
            }
            snprintf(kp, sizeof(kp), ".choir/kv/%s", n);
            unlink(kp);
        }
        closedir(kv);
    }
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

static int choir_git_one_line_stdout(char *argv[], char *out, int outsz) {
    if (outsz <= 1) {
        return -1;
    }
    int p[2];
    if (pipe(p) != 0) {
        return -1;
    }
    pid_t pid = fork();
    if (pid < 0) {
        close(p[0]);
        close(p[1]);
        return -1;
    }
    if (pid == 0) {
        close(p[0]);
        dup2(p[1], STDOUT_FILENO);
        int dn = open("/dev/null", O_WRONLY);
        if (dn >= 0) {
            dup2(dn, STDERR_FILENO);
            close(dn);
        }
        close(p[1]);
        execvp(argv[0], argv);
        _exit(127);
    }
    close(p[1]);
    FILE *in = fdopen(p[0], "r");
    if (!in) {
        close(p[0]);
        waitpid(pid, NULL, 0);
        return -1;
    }
    if (!fgets(out, outsz, in)) {
        fclose(in);
        waitpid(pid, NULL, 0);
        return -1;
    }
    fclose(in);
    int st = 0;
    if (waitpid(pid, &st, 0) < 0) {
        return -1;
    }
    if (!WIFEXITED(st) || WEXITSTATUS(st) != 0) {
        return -1;
    }
    size_t n = strlen(out);
    while (n > 0 && (out[n - 1] == '\n' || out[n - 1] == '\r')) {
        out[--n] = '\0';
    }
    return 0;
}

static int choir_exclude_snippet_first_line_present(
    const char *old,
    size_t oldlen,
    const char *snippet
) {
    size_t marker_len = strcspn(snippet, "\n");
    if (marker_len == 0 || oldlen < marker_len) {
        return 0;
    }
    for (size_t i = 0; i + marker_len <= oldlen; ++i) {
        if (memcmp(old + i, snippet, marker_len) == 0) {
            return 1;
        }
    }
    return 0;
}

int choir_worktree_seed_agent_runtime_gitexclude(const char *workspace, const char *snippet) {
    if (!workspace || workspace[0] == '\0' || !snippet || snippet[0] == '\0') {
        fprintf(stderr, "choir: warning: worktree seed gitexclude: missing workspace or snippet\n");
        return 0;
    }
    char *argv[] = {
        "git", "-C", (char *)workspace, "rev-parse", "--git-path", "info/exclude", NULL,
    };
    char pathbuf[8192];
    memset(pathbuf, 0, sizeof(pathbuf));
    if (choir_git_one_line_stdout(argv, pathbuf, (int)sizeof(pathbuf)) != 0) {
        fprintf(stderr, "choir: warning: worktree seed gitexclude: git rev-parse failed for %s\n", workspace);
        return 0;
    }
    if (pathbuf[0] == '\0') {
        fprintf(stderr, "choir: warning: worktree seed gitexclude: empty exclude path for %s\n", workspace);
        return 0;
    }

    char *old = NULL;
    size_t oldlen = 0;
    FILE *ef = fopen(pathbuf, "rb");
    if (ef) {
        if (fseek(ef, 0, SEEK_END) != 0) {
            fclose(ef);
            fprintf(stderr, "choir: warning: worktree seed gitexclude: seek failed on %s\n", pathbuf);
            return 0;
        }
        long sz = ftell(ef);
        if (sz < 0) {
            fclose(ef);
            fprintf(stderr, "choir: warning: worktree seed gitexclude: size failed on %s\n", pathbuf);
            return 0;
        }
        if (sz > 1048576) {
            fclose(ef);
            fprintf(stderr, "choir: warning: worktree seed gitexclude: exclude file too large %s\n", pathbuf);
            return 0;
        }
        rewind(ef);
        if (sz == 0) {
            fclose(ef);
            old = strdup("");
            if (!old) {
                fprintf(stderr, "choir: warning: worktree seed gitexclude: out of memory\n");
                return 0;
            }
            oldlen = 0;
        } else {
            old = malloc((size_t)sz + 1);
            if (!old) {
                fclose(ef);
                fprintf(stderr, "choir: warning: worktree seed gitexclude: out of memory\n");
                return 0;
            }
            size_t got = fread(old, 1, (size_t)sz, ef);
            fclose(ef);
            if (got != (size_t)sz) {
                free(old);
                fprintf(stderr, "choir: warning: worktree seed gitexclude: short read on %s\n", pathbuf);
                return 0;
            }
            old[sz] = '\0';
            oldlen = (size_t)sz;
        }
    } else {
        old = strdup("");
        if (!old) {
            fprintf(stderr, "choir: warning: worktree seed gitexclude: out of memory\n");
            return 0;
        }
        oldlen = 0;
    }

    if (choir_exclude_snippet_first_line_present(old, oldlen, snippet)) {
        free(old);
        return 0;
    }

    size_t sniplen = strlen(snippet);
    int need_nl = (oldlen > 0 && old[oldlen - 1] != '\n');
    size_t newlen = oldlen + (need_nl ? 1u : 0u) + sniplen;
    char *merged = malloc(newlen + 1);
    if (!merged) {
        free(old);
        fprintf(stderr, "choir: warning: worktree seed gitexclude: out of memory\n");
        return 0;
    }
    memcpy(merged, old, oldlen);
    if (need_nl) {
        merged[oldlen] = '\n';
        memcpy(merged + oldlen + 1, snippet, sniplen);
    } else {
        memcpy(merged + oldlen, snippet, sniplen);
    }
    merged[newlen] = '\0';
    int w = choir_write_file_sync(pathbuf, merged, (int)newlen);
    free(merged);
    free(old);
    if (w != 0) {
        fprintf(stderr, "choir: warning: worktree seed gitexclude: could not write %s\n", pathbuf);
    }
    return 0;
}
