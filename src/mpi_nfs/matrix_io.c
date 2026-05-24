#include "matrix_io.h"

#include <stdio.h>
#include <stdlib.h>

int matrix_read_bin(const char *path, int **out) {
    FILE *f = fopen(path, "rb");
    if (!f) { perror(path); return -1; }

    int n;
    if (fread(&n, sizeof(int), 1, f) != 1 || n <= 0) {
        fprintf(stderr, "%s: invalid or missing header\n", path);
        fclose(f);
        return -1;
    }

    int *m = malloc((size_t)n * n * sizeof(int));
    if (!m) { perror("malloc"); fclose(f); return -1; }

    if (fread(m, sizeof(int), (size_t)n * n, f) != (size_t)n * n) {
        fprintf(stderr, "%s: truncated data (expected %d elements)\n", path, n * n);
        free(m);
        fclose(f);
        return -1;
    }

    fclose(f);
    *out = m;
    return n;
}

int matrix_write_bin(const char *path, const int *m, int n) {
    FILE *f = fopen(path, "wb");
    if (!f) { perror(path); return -1; }

    int ok = (fwrite(&n, sizeof(int), 1, f) == 1) &&
             (fwrite(m, sizeof(int), (size_t)n * n, f) == (size_t)n * n);

    fclose(f);
    if (!ok) {
        fprintf(stderr, "%s: error writing matrix data\n", path);
        return -1;
    }
    return 0;
}