#define _GNU_SOURCE
#include <dlfcn.h>
#include <pthread.h>
#include <stddef.h>
#include <stdlib.h>
#include <string.h>

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
        handle = dlopen(
            "/opt/moon/lib/libutf8proc.so.3",
            RTLD_NOW | RTLD_LOCAL
        );
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

int choir_exec_path_nfc_library_path(char *out, int out_size) {
    if (out == NULL || out_size <= 0 || choir_utf8proc_load() != 0) {
        return -1;
    }
    Dl_info info;
    if (dladdr((void *)choir_utf8proc.map, &info) == 0 ||
        info.dli_fname == NULL) {
        return -1;
    }
    size_t length = strlen(info.dli_fname);
    if (length == 0 || length >= (size_t)out_size) {
        return -1;
    }
    memcpy(out, info.dli_fname, length);
    out[length] = '\0';
    return (int)length;
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
