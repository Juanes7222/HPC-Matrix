#include "matrix_lib.h"


int** matrixGenerator(int n) {
    int **matrix = (int**)malloc(n * sizeof(int*));
    if (!matrix) { perror("malloc rows"); exit(EXIT_FAILURE); }

    for (int i = 0; i < n; i++) {
        matrix[i] = (int*)malloc(n * sizeof(int));
        if (!matrix[i]) { perror("malloc cols"); exit(EXIT_FAILURE); }
    }
    return matrix;
}


void freeMatrix(int** matrix, int n) {
    for (int i = 0; i < n; i++) free(matrix[i]);
    free(matrix);
}


void fillMatrixWithZero(int** matrix, int n) {
    for (int i = 0; i < n; i++)
        for (int j = 0; j < n; j++)
            matrix[i][j] = 0;
}


void fillMatrix(int** matrix, int n) {
    /* XOR of time and matrix address produces different seeds
     * even when two matrices are created within the same second. */
    srand((unsigned int)time(NULL) ^ (unsigned int)(size_t)matrix);
    for (int i = 0; i < n; i++)
        for (int j = 0; j < n; j++)
            matrix[i][j] = rand();
}


void matrixMultiply(int** matrix1, int** matrix2, int** result, int n) {
    matrixMultiplyRange(matrix1, matrix2, result, n, 0, n);
}


void matrixMultiplyRange(int** matrix1, int** matrix2, int** result,
                         int n, int row_start, int row_end) {
    /* Loop order i-k-j gives better cache performance than i-j-k:
     * the innermost access to matrix2[k][j] is sequential in memory,
     * which reduces cache misses on large matrices. */
    for (int i = row_start; i < row_end; i++) {
        for (int j = 0; j < n; j++)
            result[i][j] = 0;
        for (int k = 0; k < n; k++)
            for (int j = 0; j < n; j++)
                result[i][j] += matrix1[i][k] * matrix2[k][j];
    }
}


double elapsedMs(struct timespec t_start, struct timespec t_end) {
    return (t_end.tv_sec  - t_start.tv_sec)  * 1000.0
         + (t_end.tv_nsec - t_start.tv_nsec) / 1e6;
}


void printElapsed(double ms) {
    /* Single stdout line captured by the bash benchmark script. */
    printf("%.3f\n", ms);
}


void printMatrix(int** matrix, int n) {
    if (n > 10) return;

    /* Compute the widest number to align all columns evenly. */
    int max_width = 1;
    for (int i = 0; i < n; i++)
        for (int j = 0; j < n; j++) {
            int num = matrix[i][j];
            int width = (num <= 0) ? 1 : 0;
            if (num < 0) { width++; num = -num; }
            while (num > 0) { width++; num /= 10; }
            if (width > max_width) max_width = width;
        }

    for (int i = 0; i < n; i++) {
        if      (i == 0)     printf("┌ ");
        else if (i == n - 1) printf("└ ");
        else                 printf("│ ");

        for (int j = 0; j < n; j++)
            printf("%*d", max_width + 1, matrix[i][j]);

        if      (i == 0)     printf(" ┐\n");
        else if (i == n - 1) printf(" ┘\n");
        else                 printf(" │\n");
    }
}


int extractN(int argc, char *argv[]) {
    if (argc < 2) {
        fprintf(stderr, "Use: %s <N>\n", argv[0]);
        exit(EXIT_FAILURE);
    }
    int n = atoi(argv[1]);
    if (n <= 0) {
        fprintf(stderr, "Error: N must be Z+.\n");
        exit(EXIT_FAILURE);
    }
    return n;
}