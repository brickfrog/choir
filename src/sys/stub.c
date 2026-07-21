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

static volatile sig_atomic_t choir_cleanup_runtime_native = 0;

int choir_rm_rf(const char *path);
static volatile sig_atomic_t choir_sigusr1_flag = 0;
static struct sigaction choir_saved_sigpipe_for_test;
static int choir_saved_sigpipe_for_test_valid = 0;
#define CHOIR_MAX_SLEEP_MS_FOR_USLEEP (INT_MAX / 1000)
#ifdef CLOCK_REALTIME_COARSE
#define CHOIR_SIGNAL_EXIT_CLOCK CLOCK_REALTIME_COARSE
#else
#define CHOIR_SIGNAL_EXIT_CLOCK CLOCK_REALTIME
#endif

int choir_mint_local_token(char *out, int out_size) {
    unsigned char random_bytes[32];
    static const char hex[] = "0123456789abcdef";
    if (out == NULL || out_size < 65) {
        return -1;
    }
    int fd = open("/dev/urandom", O_RDONLY | O_CLOEXEC);
    if (fd < 0) {
        return -1;
    }
    size_t offset = 0;
    while (offset < sizeof(random_bytes)) {
        ssize_t read_count = read(fd, random_bytes + offset, sizeof(random_bytes) - offset);
        if (read_count < 0 && errno == EINTR) {
            continue;
        }
        if (read_count <= 0) {
            close(fd);
            memset(random_bytes, 0, sizeof(random_bytes));
            return -1;
        }
        offset += (size_t)read_count;
    }
    close(fd);
    for (size_t i = 0; i < sizeof(random_bytes); i++) {
        out[i * 2] = hex[random_bytes[i] >> 4];
        out[i * 2 + 1] = hex[random_bytes[i] & 0x0f];
    }
    out[64] = '\0';
    memset(random_bytes, 0, sizeof(random_bytes));
    return 64;
}

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
    char buf[128];
    int len = choir_format_server_exit_log_line(
        sig,
        ts,
        pid,
        buf,
        (int)sizeof(buf));
    if (len <= 0) {
        return -1;
    }
    int written = 0;
    while (written < len) {
        ssize_t n = write(
            fd,
            buf + written,
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
    /* .choir/logs/server-exits.log records fatal serve signals that can bypass MoonBit logging. */
    (void)choir_append_server_exit_log_line_values(
        ".choir/logs/server-exits.log",
        sig,
        choir_signal_timestamp_sec(),
        (long long)getpid());
}

static int choir_is_crash_signal(int sig) {
    return sig == SIGSEGV || sig == SIGABRT || sig == SIGBUS;
}

static long long choir_signal_timestamp_sec(void) {
    struct timespec ts;
    /* signal-safety(7): clock_gettime is async-signal-safe; use coarse realtime when present. */
    if (clock_gettime(CHOIR_SIGNAL_EXIT_CLOCK, &ts) == 0) {
        return (long long)ts.tv_sec;
    }
    return 0;
}

static void choir_sigterm_handler(int sig) {
    choir_write_server_exit_log_line(sig);
    if (choir_cleanup_runtime_native) {
        unlink(".choir/run/server.pid");
        unlink(".choir/run/server.sock");
        unlink(".choir/run/run_id");
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

static int choir_unblock_signal_for_test(int sig) {
    sigset_t set;
    sigemptyset(&set);
    sigaddset(&set, sig);
    return sigprocmask(SIG_UNBLOCK, &set, NULL);
}

int choir_unblock_sigusr1_for_test(void) {
    return choir_unblock_signal_for_test(SIGUSR1);
}

static int choir_write_pid_file_for_test(const char *path, pid_t pid) {
    int fd = open(path, O_WRONLY | O_CREAT | O_TRUNC, 0644);
    if (fd < 0) {
        return -1;
    }
    char buf[32];
    int len = snprintf(buf, sizeof(buf), "%ld", (long)pid);
    if (len <= 0 || len >= (int)sizeof(buf)) {
        close(fd);
        return -1;
    }
    int written = 0;
    while (written < len) {
        ssize_t n = write(fd, buf + written, (size_t)(len - written));
        if (n < 0) {
            if (errno == EINTR) continue;
            close(fd);
            return -1;
        }
        if (n == 0) {
            close(fd);
            return -1;
        }
        written += (int)n;
    }
    close(fd);
    return 0;
}

static void choir_touch_file_for_test(const char *path) {
    int fd = open(path, O_WRONLY | O_CREAT | O_TRUNC, 0644);
    if (fd >= 0) {
        close(fd);
    }
}

int choir_spawn_sigterm_unblocked_pgroup_for_test(
    const char *pid_path,
    const char *sidecar_path,
    const char *sentinel_path) {
    pid_t pid = fork();
    if (pid < 0) {
        return -1;
    }
    if (pid == 0) {
        if (setsid() < 0) {
            _exit(127);
        }
        (void)choir_unblock_signal_for_test(SIGTERM);
        pid_t self = getpid();
        if (choir_write_pid_file_for_test(pid_path, self) != 0 ||
            choir_write_pid_file_for_test(sidecar_path, self) != 0) {
            _exit(127);
        }
        sleep(30);
        choir_touch_file_for_test(sentinel_path);
        _exit(0);
    }
    return (int)pid;
}

int choir_spawn_leader_exited_pgroup_for_test(
    const char *pgid_path,
    const char *child_path,
    const char *sentinel_path) {
    pid_t leader = fork();
    if (leader < 0) {
        return -1;
    }
    if (leader == 0) {
        if (setsid() < 0) {
            _exit(127);
        }
        (void)choir_unblock_signal_for_test(SIGTERM);
        pid_t self = getpid();
        if (choir_write_pid_file_for_test(pgid_path, self) != 0) {
            _exit(127);
        }
        pid_t child = fork();
        if (child < 0) {
            _exit(127);
        }
        if (child == 0) {
            (void)choir_unblock_signal_for_test(SIGTERM);
            pid_t child_self = getpid();
            if (choir_write_pid_file_for_test(child_path, child_self) != 0) {
                _exit(127);
            }
            sleep(30);
            choir_touch_file_for_test(sentinel_path);
            _exit(0);
        }
        _exit(0);
    }
    return (int)leader;
}

int choir_spawn_nested_sessions_for_test(
    const char *root_path,
    const char *child_path,
    const char *sentinel_path) {
    pid_t root = fork();
    if (root < 0) return -1;
    if (root == 0) {
        if (setsid() < 0) _exit(127);
        (void)choir_unblock_signal_for_test(SIGTERM);
        if (choir_write_pid_file_for_test(root_path, getpid()) != 0) _exit(127);
        pid_t child = fork();
        if (child < 0) _exit(127);
        if (child == 0) {
            if (setsid() < 0) _exit(127);
            (void)choir_unblock_signal_for_test(SIGTERM);
            if (choir_write_pid_file_for_test(child_path, getpid()) != 0) _exit(127);
            sleep(30);
            choir_touch_file_for_test(sentinel_path);
            _exit(0);
        }
        sleep(30);
        choir_touch_file_for_test(sentinel_path);
        _exit(0);
    }
    return (int)root;
}

int choir_ignore_sigpipe(void) {
    return signal(SIGPIPE, SIG_IGN) == SIG_ERR ? -1 : 0;
}

int choir_sigpipe_ignored_for_test(void) {
    struct sigaction current;
    memset(&current, 0, sizeof(current));
    if (sigaction(SIGPIPE, NULL, &current) != 0) {
        return -1;
    }
    return current.sa_handler == SIG_IGN ? 1 : 0;
}

int choir_reset_sigpipe_default_for_test(void) {
    return signal(SIGPIPE, SIG_DFL) == SIG_ERR ? -1 : 0;
}

int choir_save_sigpipe_for_test(void) {
    memset(&choir_saved_sigpipe_for_test, 0, sizeof(choir_saved_sigpipe_for_test));
    if (sigaction(SIGPIPE, NULL, &choir_saved_sigpipe_for_test) != 0) {
        choir_saved_sigpipe_for_test_valid = 0;
        return -1;
    }
    choir_saved_sigpipe_for_test_valid = 1;
    return 0;
}

int choir_restore_sigpipe_for_test(void) {
    if (!choir_saved_sigpipe_for_test_valid) {
        return -1;
    }
    int rc = sigaction(SIGPIPE, &choir_saved_sigpipe_for_test, NULL);
    choir_saved_sigpipe_for_test_valid = 0;
    return rc;
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
    unlink(".choir/run/server.pid");
    unlink(".choir/run/server.sock");
    unlink(".choir/run/run_id");
    (void)choir_rm_rf(".choir/run/codex-conductor");
}

int choir_get_file_size(const char* path) {
    FILE* f = fopen(path, "rb");
    if (!f) return -1;
    fseek(f, 0, SEEK_END);
    long size = ftell(f);
    fclose(f);
    return (int)size;
}

long long choir_file_mtime_sec(const char* path) {
    struct stat st;
    if (stat(path, &st) != 0) {
        return -1;
    }
    return (long long)st.st_mtime;
}

int choir_system(const char* cmd) {
    return system(cmd);
}

int choir_path_entry_exists(const char* path) {
    struct stat st;
    return stat(path, &st) == 0;
}

int choir_path_executable(const char* path) {
    struct stat st;
    if (stat(path, &st) != 0) {
        return 0;
    }
    if (!S_ISREG(st.st_mode)) {
        return 0;
    }
    return access(path, X_OK) == 0;
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
 * callers use it only for bounded local directories. */
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

int choir_list_dir_all(const char *path, char *buf, int max_size) {
    DIR *d = opendir(path);
    if (!d) {
        return -1;
    }
    struct dirent *ent;
    int total = 0;
    while ((ent = readdir(d)) != NULL) {
        if (strcmp(ent->d_name, ".") == 0 || strcmp(ent->d_name, "..") == 0) {
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

int choir_read_file_prefix(const char *path, char *buf, int max_size) {
    if (path == NULL || buf == NULL || max_size <= 0 || max_size > 65536) {
        return -1;
    }
    int fd = open(path, O_RDONLY | O_CLOEXEC);
    if (fd < 0) {
        return -1;
    }
    int total = 0;
    while (total < max_size) {
        ssize_t n = read(fd, buf + total, (size_t)(max_size - total));
        if (n < 0 && errno == EINTR) {
            continue;
        }
        if (n <= 0) {
            break;
        }
        total += (int)n;
    }
    close(fd);
    return total;
}

static int choir_buffer_contains(
    const char *buffer,
    int buffer_size,
    const char *needle
) {
    size_t needle_size = strlen(needle);
    if (needle_size == 0 || needle_size > (size_t)buffer_size) {
        return 0;
    }
    for (int offset = 0; offset + (int)needle_size <= buffer_size; offset++) {
        if (memcmp(buffer + offset, needle, needle_size) == 0) {
            return 1;
        }
    }
    return 0;
}

static int choir_environment_has_entry(
    const char *buffer,
    int buffer_size,
    const char *entry
) {
    size_t entry_size = strlen(entry);
    int offset = 0;
    while (offset < buffer_size) {
        int end = offset;
        while (end < buffer_size && buffer[end] != '\0') {
            end++;
        }
        if ((size_t)(end - offset) == entry_size &&
            memcmp(buffer + offset, entry, entry_size) == 0) {
            return 1;
        }
        offset = end + 1;
    }
    return 0;
}

int choir_pgid_has_process_identity(
    int pgid,
    const char *environment_entry,
    const char *command_fragment
) {
    if (pgid <= 1 || environment_entry == NULL || command_fragment == NULL) {
        return 0;
    }
    DIR *proc = opendir("/proc");
    if (proc == NULL) {
        return 0;
    }
    struct dirent *entry;
    char path[128];
    char environment[65536];
    char command[65536];
    int matched = 0;
    while ((entry = readdir(proc)) != NULL) {
        char *end = NULL;
        errno = 0;
        long raw_pid = strtol(entry->d_name, &end, 10);
        if (errno != 0 || end == entry->d_name || *end != '\0' ||
            raw_pid <= 1 || raw_pid > INT_MAX || getpgid((pid_t)raw_pid) != pgid) {
            continue;
        }
        int written = snprintf(
            path, sizeof(path), "/proc/%ld/environ", raw_pid
        );
        if (written <= 0 || (size_t)written >= sizeof(path)) {
            continue;
        }
        int environment_size = choir_read_file_prefix(
            path, environment, (int)sizeof(environment)
        );
        written = snprintf(path, sizeof(path), "/proc/%ld/cmdline", raw_pid);
        if (written <= 0 || (size_t)written >= sizeof(path)) {
            continue;
        }
        int command_size = choir_read_file_prefix(
            path, command, (int)sizeof(command)
        );
        if (environment_size > 0 && command_size > 0 &&
            choir_environment_has_entry(
                environment, environment_size, environment_entry
            ) &&
            choir_buffer_contains(command, command_size, command_fragment)) {
            matched = 1;
            break;
        }
    }
    closedir(proc);
    return matched;
}

int choir_pgid_has_non_zombie_process(int pgid) {
    if (pgid <= 1) {
        return 0;
    }
    DIR *proc = opendir("/proc");
    if (proc == NULL) {
        return 0;
    }
    struct dirent *entry;
    char path[128];
    char stat_buffer[4096];
    int running = 0;
    while ((entry = readdir(proc)) != NULL) {
        char *end = NULL;
        errno = 0;
        long raw_pid = strtol(entry->d_name, &end, 10);
        if (errno != 0 || end == entry->d_name || *end != '\0' ||
            raw_pid <= 1 || raw_pid > INT_MAX || getpgid((pid_t)raw_pid) != pgid) {
            continue;
        }
        int written = snprintf(path, sizeof(path), "/proc/%ld/stat", raw_pid);
        if (written <= 0 || (size_t)written >= sizeof(path)) {
            continue;
        }
        int stat_size = choir_read_file_prefix(
            path, stat_buffer, (int)sizeof(stat_buffer) - 1
        );
        if (stat_size <= 0) {
            continue;
        }
        stat_buffer[stat_size] = '\0';
        char *close = strrchr(stat_buffer, ')');
        if (close != NULL && close[1] == ' ' &&
            close[2] != 'Z' && close[2] != 'X') {
            running = 1;
            break;
        }
    }
    closedir(proc);
    return running;
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

int choir_getppid(void) {
    return (int)getppid();
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

int choir_kill_pgid(int pgid) {
    // Guard pgid <= 1: kill(-1, SIGTERM) is the broadcast form (signal every
    // process the caller can signal), and pgid 0/1 are reserved (init's pgrp
    // in container PID namespaces). The intent is bounded-pgroup cleanup.
    if (pgid <= 1) {
        return 0;
    }
    if (kill(-(pid_t)pgid, SIGTERM) == 0) {
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

#define CHOIR_MAX_SERVER_TREE_PIDS 4096

static int choir_proc_ppid(pid_t pid, pid_t *ppid_out) {
    char path[64];
    char stat_line[4096];
    snprintf(path, sizeof(path), "/proc/%ld/stat", (long)pid);
    int fd = open(path, O_RDONLY | O_CLOEXEC);
    if (fd < 0) return -1;
    ssize_t n = read(fd, stat_line, sizeof(stat_line) - 1);
    close(fd);
    if (n <= 0) return -1;
    stat_line[n] = '\0';
    char *close_paren = strrchr(stat_line, ')');
    char state = '\0';
    long parent = -1;
    if (close_paren == NULL ||
        sscanf(close_paren + 1, " %c %ld", &state, &parent) != 2 ||
        parent < 0) {
        return -1;
    }
    *ppid_out = (pid_t)parent;
    return 0;
}

static int choir_pid_in_list(const pid_t *pids, int count, pid_t pid) {
    for (int i = 0; i < count; i++) {
        if (pids[i] == pid) return 1;
    }
    return 0;
}

static int choir_collect_process_tree(pid_t root, pid_t *pids, int capacity) {
    if (root <= 1 || capacity <= 0) return 0;
    int count = 1;
    pids[0] = root;
    int changed = 1;
    while (changed && count < capacity) {
        changed = 0;
        DIR *proc = opendir("/proc");
        if (proc == NULL) break;
        struct dirent *entry;
        while ((entry = readdir(proc)) != NULL && count < capacity) {
            char *end = NULL;
            long raw = strtol(entry->d_name, &end, 10);
            if (entry->d_name[0] == '\0' || end == NULL || *end != '\0' || raw <= 1) {
                continue;
            }
            pid_t candidate = (pid_t)raw;
            if (choir_pid_in_list(pids, count, candidate)) continue;
            pid_t parent = -1;
            if (choir_proc_ppid(candidate, &parent) == 0 &&
                choir_pid_in_list(pids, count, parent)) {
                pids[count++] = candidate;
                changed = 1;
            }
        }
        closedir(proc);
    }
    return count;
}

/*
 * Stop the exact detached server tree, including provider children that call
 * setsid(2) and therefore leave the daemon's process group. The /proc walk is
 * rooted at the recorded daemon PID; it never signals unrelated processes.
 */
void choir_init_kill_server_tree_sequence(int pid) {
    if (pid <= 1) return;
    pid_t pids[CHOIR_MAX_SERVER_TREE_PIDS];
    int count = choir_collect_process_tree((pid_t)pid, pids, CHOIR_MAX_SERVER_TREE_PIDS);
    for (int i = count - 1; i >= 0; i--) {
        if (kill(pids[i], SIGTERM) < 0 && errno != ESRCH) { /* best-effort */ }
    }
    if (kill(-(pid_t)pid, SIGTERM) < 0 && errno != ESRCH) { /* best-effort */ }
    usleep(300000);
    for (int i = count - 1; i >= 0; i--) {
        if (kill(pids[i], SIGKILL) < 0 && errno != ESRCH) { /* best-effort */ }
    }
    if (kill(-(pid_t)pid, SIGKILL) < 0 && errno != ESRCH) { /* best-effort */ }
}

/**
 * Owned-pgroup teardown: SIGTERM the process group, brief delay, then SIGKILL.
 * Groups <= 1 are rejected as no-op: 0 is the caller's own group and 1
 * triggers the broadcast form (and is init's pgrp in container PID
 * namespaces), both wider than the bounded-pgroup-cleanup intent. Ignores
 * ESRCH (best-effort).
 */
void choir_kill_pgid_sequence(int pgid) {
    if (pgid <= 1) {
        return;
    }
    if (kill(-(pid_t)pgid, SIGTERM) < 0 && errno != ESRCH) {
        /* best-effort */
    }
    usleep(300000);
    if (kill(-(pid_t)pgid, SIGKILL) < 0 && errno != ESRCH) {
        /* best-effort */
    }
}

/**
 * Test-only: reap a direct child with waitpid(2) so a follow-up
 * `kill(pid, 0)` probe does not see a zombie. Returns the pid on success,
 * -1 on failure.
 */
int choir_wait_pid_reap_for_test(int pid) {
    if (pid <= 0) {
        return -1;
    }
    if (waitpid((pid_t)pid, NULL, 0) < 0) {
        return -1;
    }
    return pid;
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

/**
 * Returns 1 if `kill(-pgid, 0)` proves at least one process is still in the
 * group. EPERM still proves liveness: the group exists but is not signalable by
 * this process.
 */
int choir_pgid_is_alive(int pgid) {
    if (pgid <= 1) {
        return 0;
    }
    if (kill(-(pid_t)pgid, 0) == 0) {
        return 1;
    }
    return errno == EPERM ? 1 : 0;
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
        /*
         * Make the detached server the leader of a bounded process group.
         * `choir stop` can then terminate the daemon and every child that
         * inherits its group without touching the caller's process group.
         */
        if (setsid() < 0) {
            _exit(127);
        }
        /* logs/ may not exist yet: detached child opens the log before serve boots. */
        mkdir(".choir", 0755);
        mkdir(".choir/logs", 0755);
        int fd = open(".choir/logs/serve.log", O_WRONLY | O_CREAT | O_APPEND, 0644);
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

int choir_spawn_goal_worker(const char* exe, int exe_len, const char* cwd, int cwd_len) {
    (void)exe_len;
    (void)cwd_len;
    pid_t pid = fork();
    if (pid < 0) {
        return -1;
    }
    if (pid == 0) {
        if (chdir(cwd) != 0) {
            _exit(127);
        }
        char* argv[] = { (char*)exe, "run-goals", NULL };
        execvp(exe, argv);
        _exit(127);
    }
    return (int)pid;
}

int choir_child_process_state(int pid) {
    if (pid <= 1) {
        return -3;
    }
    int status = 0;
    pid_t result = waitpid((pid_t)pid, &status, WNOHANG);
    if (result == 0) {
        return -2;
    }
    if (result < 0) {
        return -3;
    }
    if (WIFEXITED(status)) {
        return WEXITSTATUS(status);
    }
    if (WIFSIGNALED(status)) {
        return 128 + WTERMSIG(status);
    }
    return -3;
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
        int copy_len = out_size - 1;
        memcpy(out, value, (size_t)copy_len);
        out[copy_len] = '\0';
        return len;
    }
    memcpy(out, value, (size_t)len);
    out[len] = '\0';
    return len;
}

int choir_get_parent_env(const char* name, char* out, int out_size) {
#ifdef __linux__
    if (!name || !out || out_size <= 0 || strchr(name, '=') != NULL) return 0;
    char path[64];
    int path_len = snprintf(path, sizeof(path), "/proc/%ld/environ", (long)getppid());
    if (path_len <= 0 || path_len >= (int)sizeof(path)) return 0;
    int fd = open(path, O_RDONLY | O_CLOEXEC);
    if (fd < 0) return 0;
    char environment[65536];
    ssize_t total = 0;
    while (total < (ssize_t)sizeof(environment)) {
        ssize_t count = read(fd, environment + total, sizeof(environment) - (size_t)total);
        if (count < 0) {
            if (errno == EINTR) continue;
            close(fd);
            return 0;
        }
        if (count == 0) break;
        total += count;
    }
    close(fd);
    size_t name_len = strlen(name);
    ssize_t offset = 0;
    while (offset < total) {
        size_t remaining = (size_t)(total - offset);
        size_t entry_len = strnlen(environment + offset, remaining);
        if (entry_len == remaining) break;
        if (entry_len > name_len &&
            memcmp(environment + offset, name, name_len) == 0 &&
            environment[offset + (ssize_t)name_len] == '=') {
            const char *value = environment + offset + name_len + 1;
            int value_len = (int)(entry_len - name_len - 1);
            if (value_len >= out_size) return value_len;
            memcpy(out, value, (size_t)value_len);
            out[value_len] = '\0';
            return value_len;
        }
        offset += (ssize_t)entry_len + 1;
    }
#else
    (void)name;
    (void)out;
    (void)out_size;
#endif
    return 0;
}

int choir_setenv(const char* name, const char* value) {
    if (!name || !value) return -EINVAL;
    if (setenv(name, value, 1) != 0) return -errno;
    return 0;
}

int choir_unsetenv(const char* name) {
    if (!name) return -EINVAL;
    if (unsetenv(name) != 0) return -errno;
    return 0;
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

void choir_init_cleanup_purge_artifacts(void) {
    (void)choir_rm_rf(".choir/state");
    (void)choir_rm_rf(".choir/run");
}
