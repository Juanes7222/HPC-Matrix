#ifndef MATRIX_LIB_H
#define MATRIX_LIB_H

#include <stdlib.h>
#include <stdio.h>
#include <time.h>



/*
 * Allocates memory for an NxN integer matrix.
 * Calls perror and exits if malloc fails.
 */
int** matrixGenerator(int n);

/*
 * Frees memory allocated by matrixGenerator.
 */
void freeMatrix(int** matrix, int n);


/*
 * Fills the matrix with zeros.
 */
void fillMatrixWithZero(int** matrix, int n);

/*
 * Fills the matrix with random integers in [0, 100].
 * Seeds rand() with a XOR of time and the matrix address so that
 * two matrices created in the same second get different values.
 */
void fillMatrix(int** matrix, int n);

/*
 * Multiplies matrix1 * matrix2 and writes the result to result.
 */
void matrixMultiply(int** matrix1, int** matrix2, int** result, int n);

/*
 * Multiplies only rows [row_start, row_end) of matrix1 * matrix2.
 * Called by each thread or child process with its assigned row range.
 */
void matrixMultiplyRange(int** matrix1, int** matrix2, int** result,
                         int n, int row_start, int row_end);

/*
 * Multiplies matrix1 * matrix2 using the transposed access pattern.
 */
void matrixMultiplyWithTransposed(int** matrix1, int** matrix2, int** result, int n);

/*
 * Multiplies only rows [row_start, row_end) of matrix1 * matrix2 using the transposed access pattern.
 * Called by each thread or child process with its assigned row range.
 */
void matrixMultiplyRangeWithTransposed(int** matrix1, int** matrix2, int** result,
                                       int n, int row_start, int row_end);

/*
 * Returns wall time in milliseconds between t_start and t_end.
 * Intended for use with clock_gettime(CLOCK_MONOTONIC, ...).
 */
double elapsedMs(struct timespec t_start, struct timespec t_end);

/*
 * Prints elapsed time in milliseconds to stdout with 3 decimal places.
 * This is the only stdout output; the bash script captures it for the CSV.
 */
void printElapsed(double ms);


/*
 * Prints the matrix with Unicode box-drawing borders.
 * Does nothing if n > 10 to avoid flooding the terminal during benchmarks.
 */
void printMatrix(int** matrix, int n);


/*
 * Reads N from the first command-line argument.
 * Exits with an error message if the argument is missing or not positive.
 */
int extractN(int argc, char *argv[]);

#endif   