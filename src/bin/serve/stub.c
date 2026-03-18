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
