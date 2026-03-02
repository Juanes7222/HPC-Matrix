/*
 * verify_mul.c  --  Mathematical correctness test for matrixMultiply
 *
 * Uses two 4x4 matrices with hardcoded values whose product is known exactly.
 * You can verify the expected result by hand or with any calculator:
 *
 *   A = | 1  2  3  4 |     B = | 5  6  7  8 |
 *       | 5  6  7  8 |         | 1  2  3  4 |
 *       | 9  1  2  3 |         | 9  8  7  6 |
 *       | 4  5  6  7 |         | 5  4  3  2 |
 *
 *   A*B = |  54  50  46  42 |
 *         | 134 130 126 122 |
 *         |  79  84  89  94 |
 *         | 114 110 106 102 |
 *
 * Compilation (done automatically by bench_opt.sh):
 *   gcc <flags> -o bin/verify_mul_<label> verify_mul.c matrix_lib.c
 *
 * Exit codes:
 *   0  correct
 *   1  wrong result
 */

#include "matrix_lib.h"

static const int A[4][4] = {
    {1, 2, 3, 4},
    {5, 6, 7, 8},
    {9, 1, 2, 3},
    {4, 5, 6, 7},
};

static const int B[4][4] = {
    {5, 6, 7, 8},
    {1, 2, 3, 4},
    {9, 8, 7, 6},
    {5, 4, 3, 2},
};

static const int EXPECTED[4][4] = {
    { 54,  50,  46,  42},
    {134, 130, 126, 122},
    { 79,  84,  89,  94},
    {114, 110, 106, 102},
};

int main(void) {
    int n = 4;

    int **a = matrixGenerator(n);
    int **b = matrixGenerator(n);
    int **c = matrixGenerator(n);

    for (int i = 0; i < n; i++)
        for (int j = 0; j < n; j++) {
            a[i][j] = A[i][j];
            b[i][j] = B[i][j];
        }

    matrixMultiply(a, b, c, n);

    int correct = 1;
    for (int i = 0; i < n && correct; i++)
        for (int j = 0; j < n && correct; j++)
            if (c[i][j] != EXPECTED[i][j])
                correct = 0;

    if (!correct) {
        fprintf(stderr, "FAIL: result matrix does not match expected values.\n");
        fprintf(stderr, "Got:\n");
        for (int i = 0; i < n; i++) {
            for (int j = 0; j < n; j++)
                fprintf(stderr, "%5d", c[i][j]);
            fprintf(stderr, "\n");
        }
        fprintf(stderr, "Expected:\n");
        for (int i = 0; i < n; i++) {
            for (int j = 0; j < n; j++)
                fprintf(stderr, "%5d", EXPECTED[i][j]);
            fprintf(stderr, "\n");
        }
    }

    freeMatrix(a, n);
    freeMatrix(b, n);
    freeMatrix(c, n);

    return correct ? EXIT_SUCCESS : EXIT_FAILURE;
}