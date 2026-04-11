
#include "matrix_lib.h"

int main(int argc, char *argv[]) {

    int n = extractN(argc, argv);

    int** matrix1 = matrixGenerator(n);
    int** matrix2 = matrixGenerator(n);
    int** result  = matrixGenerator(n);

    fillMatrix(matrix1, n);
    fillMatrix(matrix2, n);

    struct timespec t_start, t_end;
    clock_gettime(CLOCK_MONOTONIC, &t_start);

    matrixMultiply(matrix1, matrix2, result, n);

    clock_gettime(CLOCK_MONOTONIC, &t_end);

    printElapsed(elapsedMs(t_start, t_end));

    // printMatrix(matrix1, n);
    // printMatrix(matrix2, n);
    // printMatrix(result,  n);

    freeMatrix(matrix1, n);
    freeMatrix(matrix2, n);
    freeMatrix(result,  n);

    return EXIT_SUCCESS;
}