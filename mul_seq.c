#include <stdlib.h>
#include <stdio.h>
#include <time.h>

int** matrixGenerator(int n) {
    int **matrix = (int**)malloc(n * sizeof(int*));
    if (!matrix) { perror("malloc filas"); exit(EXIT_FAILURE); }

    for (int i = 0; i < n; i++) {
        matrix[i] = (int*)malloc(n * sizeof(int));
        if (!matrix[i]) { perror("malloc columnas"); exit(EXIT_FAILURE); }
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
    srand((unsigned int)time(NULL) ^ (unsigned int)(size_t)matrix);
    for (int i = 0; i < n; i++)
        for (int j = 0; j < n; j++)
            matrix[i][j] = rand() % 101;
}


void matrixMultiply(int** matrix1, int** matrix2, int** result, int n) {
    fillMatrixWithZero(result, n);
    for (int i = 0; i < n; i++)
        for (int k = 0; k < n; k++)
            for (int j = 0; j < n; j++)
                result[i][j] += matrix1[i][k] * matrix2[k][j];
}


void printMatrix(int** matrix, int n) {
    if (n > 10) return;

    int max_width = 1;
    for (int i = 0; i < n; i++)
        for (int j = 0; j < n; j++) {
            int num = matrix[i][j], width = (num <= 0) ? 1 : 0;
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

    double elapsed_ms = (t_end.tv_sec  - t_start.tv_sec)  * 1000.0
                      + (t_end.tv_nsec - t_start.tv_nsec) / 1e6;

    printf("%.3f\n", elapsed_ms);

    printMatrix(matrix1, n);
    printMatrix(matrix2, n);
    printMatrix(result,  n);

    freeMatrix(matrix1, n);
    freeMatrix(matrix2, n);
    freeMatrix(result,  n);

    return EXIT_SUCCESS;
}