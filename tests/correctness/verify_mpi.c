#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "matrix_io.h"
#include "matrix_lib.h"

/*
 * Reads A.bin, B.bin, and C.bin; computes A*B sequentially using
 * matrixMultiplyRangeFlat; compares result against C element by element.
 * Exits with 0 on PASS, 1 on FAIL or error.
 */
int main(int argc, char *argv[]) {
    if (argc != 4) {
        fprintf(stderr, "Usage: %s <A.bin> <B.bin> <C.bin>\n", argv[0]);
        return EXIT_FAILURE;
    }

    int *a = NULL, *b = NULL, *c = NULL;
    int na = matrix_read_bin(argv[1], &a);
    int nb = matrix_read_bin(argv[2], &b);
    int nc = matrix_read_bin(argv[3], &c);

    if (na < 0 || nb < 0 || nc < 0) {
        fprintf(stderr, "Error reading one or more input files\n");
        free(a); free(b); free(c);
        return EXIT_FAILURE;
    }

    if (na != nb || na != nc) {
        fprintf(stderr, "Dimension mismatch: A=%d B=%d C=%d\n", na, nb, nc);
        free(a); free(b); free(c);
        return EXIT_FAILURE;
    }

    int n = na;
    int *expected = calloc((size_t)n * n, sizeof(int));
    if (!expected) { perror("calloc"); return EXIT_FAILURE; }

    matrixMultiplyRangeFlat(a, b, expected, n, 0, n);

    int mismatches = 0;
    for (int i = 0; i < n * n; i++) {
        if (expected[i] != c[i]) {
            if (mismatches < 5)
                fprintf(stderr, "  mismatch at (%d,%d): expected %d, got %d\n",
                        i / n, i % n, expected[i], c[i]);
            mismatches++;
        }
    }

    free(a); free(b); free(c); free(expected);

    if (mismatches == 0) {
        printf("PASS  N=%-5d\n", n);
        return EXIT_SUCCESS;
    }

    printf("FAIL  N=%-5d  %d/%d elements wrong\n", n, mismatches, n * n);
    return EXIT_FAILURE;
}
