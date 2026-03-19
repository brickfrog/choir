#include <stdio.h>
#include <stdlib.h>
#include <string.h>

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

int choir_stdin_read_line(char *buf, int max_size) {
    if (fgets(buf, max_size, stdin) == NULL) {
        return 0;
    }
    int len = strlen(buf);
    if (len > 0 && buf[len - 1] == '\n') {
        buf[len - 1] = '\0';
        return len - 1;
    }
    return len;
}

int choir_argc(void) {
    FILE* f = fopen("/proc/self/cmdline", "rb");
    if (!f) return 0;
    char buf[65536];
    int total = (int)fread(buf, 1, sizeof(buf) - 1, f);
    fclose(f);
    if (total <= 0) return 0;
    int count = 0;
    for (int i = 0; i < total; i++) {
        if (buf[i] == '\0') count++;
    }
    return count;
}

/* Writes the nth argument (0-indexed) into out (null-terminated). Returns length or 0. */
int choir_argv_get(int n, char* out, int out_size) {
    FILE* f = fopen("/proc/self/cmdline", "rb");
    if (!f) return 0;
    char buf[65536];
    int total = (int)fread(buf, 1, sizeof(buf) - 1, f);
    fclose(f);
    int idx = 0, start = 0;
    for (int i = 0; i <= total; i++) {
        if (i == total || buf[i] == '\0') {
            if (idx == n) {
                int len = i - start;
                if (len >= out_size) len = out_size - 1;
                memcpy(out, buf + start, len);
                out[len] = '\0';
                return len;
            }
            idx++;
            start = i + 1;
        }
    }
    return 0;
}
