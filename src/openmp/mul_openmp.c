#include <omp.h>
#include "matrix_lib.h"

/*
 * Reads num_threads from argv[2].
 * Exits with a descriptive message if the argument is missing or invalid.
 */
static int extractThreadCount(int argc, char *argv[]) {
    if (argc < 3) {
        fprintf(stderr, "Use: %s <N> <num_threads>\n", argv[0]);
        exit(EXIT_FAILURE);
    }
    int threads = atoi(argv[2]);
    if (threads <= 0) {
        fprintf(stderr, "Error: num_threads must be a positive integer.\n");
        exit(EXIT_FAILURE);
    }
    return threads;
}

/*
 * Multiplies matrix1 * matrix2 and writes the output to result.
 * Row-level parallelism: each thread owns a contiguous block of rows.
 * schedule(static) distributes iterations evenly at compile time,
 * which is optimal for the uniform workload of dense matrix multiplication.
 */
static void multiplyWithOpenMP(int **matrix1, int **matrix2, int **result, int n) {
    #pragma omp parallel for schedule(static)
    for (int i = 0; i < n; i++) {
        for (int j = 0; j < n; j++) {
            result[i][j] = 0;
            for (int k = 0; k < n; k++)
                result[i][j] += matrix1[i][k] * matrix2[k][j];
        }
    }
}

/*
 * Same as multiplyWithOpenMP but accesses matrix2 in transposed order.
 * Eliminates column-stride cache misses on matrix2 for large N.
 * matrix2 is assumed to already be stored transposed: matrix2T[j][k].
 */
static void multiplyTransposedWithOpenMP(int **matrix1, int **matrix2T, int **result, int n) {
    #pragma omp parallel for schedule(static)
    for (int i = 0; i < n; i++) {
        for (int j = 0; j < n; j++) {
            result[i][j] = 0;
            for (int k = 0; k < n; k++)
                result[i][j] += matrix1[i][k] * matrix2T[j][k];
        }
    }
}

int main(int argc, char *argv[]) {
    int n         = extractN(argc, argv);
    int n_threads = extractThreadCount(argc, argv);

    if (n_threads > n) n_threads = n;
    omp_set_num_threads(n_threads);

    int **matrix1 = matrixGenerator(n);
    int **matrix2 = matrixGenerator(n);
    int **result  = matrixGenerator(n);

    fillMatrix(matrix1, n);
    fillMatrix(matrix2, n);

    struct timespec t_start, t_end;
    clock_gettime(CLOCK_MONOTONIC, &t_start);

    multiplyWithOpenMP(matrix1, matrix2, result, n);

    clock_gettime(CLOCK_MONOTONIC, &t_end);

    printElapsed(elapsedMs(t_start, t_end));

   //  printMatrix(matrix1, n);
   //  printMatrix(matrix2, n);
   //  printMatrix(result, n);

    freeMatrix(matrix1, n);
    freeMatrix(matrix2, n);
    freeMatrix(result, n);

    return EXIT_SUCCESS;
}