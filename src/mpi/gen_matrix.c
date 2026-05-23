#include "matrix_io.h"

#include <stdio.h>
#include <stdlib.h>
#include <time.h>

int main(int argc, char *argv[]) {
    if (argc != 3) {
        fprintf(stderr, "Usage: %s <N> <output.bin>\n", argv[0]);
        return EXIT_FAILURE;
    }

    int n = atoi(argv[1]);
    if (n <= 0) {
        fprintf(stderr, "N must be a positive integer\n");
        return EXIT_FAILURE;
    }

    int *m = malloc((size_t)n * n * sizeof(int));
    if (!m) { perror("malloc"); return EXIT_FAILURE; }

    srand((unsigned int)time(NULL) ^ (unsigned int)(size_t)m);
    for (int i = 0; i < n * n; i++)
        m[i] = rand() % 100;

    if (matrix_write_bin(argv[2], m, n) != 0) {
        fprintf(stderr, "Error writing to %s\n", argv[2]);
        free(m);
        return EXIT_FAILURE;
    }

    free(m);
    return EXIT_SUCCESS;
}
