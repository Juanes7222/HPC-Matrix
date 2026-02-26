#include <sys/mman.h>
#include <sys/wait.h>
#include <unistd.h>
#include "matrix_lib.h"

/* Reads num_processes from argv[2]. */
static int extractProcesses(int argc, char *argv[]) {
    if (argc < 3) {
        fprintf(stderr, "Use: %s <N> <num_processes>\n", argv[0]);
        exit(EXIT_FAILURE);
    }
    int p = atoi(argv[2]);
    if (p <= 0) {
        fprintf(stderr, "Error: num_processes must be Z+.\n");
        exit(EXIT_FAILURE);
    }
    return p;
}

/*
 * Allocates a flat int array in shared memory and returns an int** whose
 * row pointers map into it. This lets matrixMultiplyRange work unmodified
 * while all processes write to the same physical pages.
 */
static int** sharedResultMatrix(int n) {
    /* Flat shared block: all processes read and write the same pages. */
    int *data = mmap(NULL, (size_t)n * n * sizeof(int),
                     PROT_READ | PROT_WRITE,
                     MAP_SHARED | MAP_ANONYMOUS, -1, 0);
    if (data == MAP_FAILED) { perror("mmap"); exit(EXIT_FAILURE); }

    /* Row pointer array lives in regular memory; only the parent uses it
     * as a navigation aid. Each child inherits a copy of these pointers
     * but they all point into the same shared pages. */
    int **matrix = malloc(n * sizeof(int*));
    if (!matrix) { perror("malloc result rows"); exit(EXIT_FAILURE); }

    for (int i = 0; i < n; i++)
        matrix[i] = data + i * n;

    return matrix;
}

int main(int argc, char *argv[]) {

    int n         = extractN(argc, argv);
    int n_procs   = extractProcesses(argc, argv);

    if (n_procs > n) n_procs = n;

    int** matrix1 = matrixGenerator(n);
    int** matrix2 = matrixGenerator(n);
    int** result  = sharedResultMatrix(n);

    fillMatrix(matrix1, n);
    fillMatrix(matrix2, n);

    /* Distribute rows as evenly as possible across processes.
     * The last process takes any remaining rows when N % n_procs != 0. */
    int rows_per_proc = n / n_procs;

    pid_t *pids = malloc(n_procs * sizeof(pid_t));
    if (!pids) { perror("malloc pids"); exit(EXIT_FAILURE); }

    struct timespec t_start, t_end;
    clock_gettime(CLOCK_MONOTONIC, &t_start);

    for (int p = 0; p < n_procs; p++) {
        int row_start = p * rows_per_proc;
        int row_end   = (p == n_procs - 1) ? n : (p + 1) * rows_per_proc;

        pids[p] = fork();
        if (pids[p] < 0) {
            perror("fork");
            exit(EXIT_FAILURE);
        }

        if (pids[p] == 0) {
            /* Child: compute assigned rows and exit. */
            matrixMultiplyRange(matrix1, matrix2, result, n, row_start, row_end);
            exit(EXIT_SUCCESS);
        }
    }

    /* Parent: wait for every child to finish. */
    int all_ok = 1;
    for (int p = 0; p < n_procs; p++) {
        int status;
        waitpid(pids[p], &status, 0);
        if (!WIFEXITED(status) || WEXITSTATUS(status) != 0)
            all_ok = 0;
    }

    clock_gettime(CLOCK_MONOTONIC, &t_end);

    if (!all_ok) {
        fprintf(stderr, "Error: one or more child processes failed.\n");
        exit(EXIT_FAILURE);
    }

    printElapsed(elapsedMs(t_start, t_end));

    printMatrix(matrix1, n);
    printMatrix(matrix2, n);
    printMatrix(result,  n);

    /* Unmap the shared result block. */
    munmap(result[0], (size_t)n * n * sizeof(int));

    free(pids);
    free(result);
    freeMatrix(matrix1, n);
    freeMatrix(matrix2, n);

    return EXIT_SUCCESS;
}