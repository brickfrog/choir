#include <stdlib.h>
#include <sys/wait.h>

int choir_exec_system(const char *cmd) {
    int status = system(cmd);
    if (status == -1) {
        return -1;
    }
    if (WIFEXITED(status)) {
        return WEXITSTATUS(status);
    }
    // If it didn't exit normally, return a non-zero status
    return status;
}
