#define _DARWIN_C_SOURCE

#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>

int main(int argc, char **argv) {
    if (argc != 3) {
        fprintf(stderr, "usage: atomic-replace SOURCE DESTINATION\n");
        return 64;
    }

    if (renameatx_np(AT_FDCWD, argv[1], AT_FDCWD, argv[2], RENAME_SWAP) != 0) {
        fprintf(stderr, "atomic-replace: cannot swap %s and %s: %s\n",
                argv[1], argv[2], strerror(errno));
        return 1;
    }
    return 0;
}
