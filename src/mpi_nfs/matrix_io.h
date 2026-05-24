#ifndef MATRIX_IO_H
#define MATRIX_IO_H

/*
 * Binary format: 4-byte int N, followed by N*N 4-byte ints in row-major order.
 * Element (i,j) is stored at offset i*N + j.
 */

/* Reads matrix from path. Allocates *out and returns N, or -1 on error. */
int matrix_read_bin(const char *path, int **out);

/* Writes N followed by N*N elements to path. Returns 0 on success, -1 on error. */
int matrix_write_bin(const char *path, const int *m, int n);

#endif
