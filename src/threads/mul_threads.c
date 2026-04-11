#include <pthread.h>
#include "matrix_lib.h"

typedef struct {
    int** matrix1;
    int** matrix2;
    int** result;
    int   n;
    int   row_start;
    int   row_end;
} ThreadArgs;

/* Entry point for each thread. */
static void* threadWorker(void* arg) {
    ThreadArgs* a = (ThreadArgs*)arg;
    matrixMultiplyRange(a->matrix1, a->matrix2, a->result,
                        a->n, a->row_start, a->row_end);
    return NULL;
}

/* Reads num_threads from argv[2]. */
static int extractThreads(int argc, char *argv[]) {
    if (argc < 3) {
        fprintf(stderr, "Use: %s <N> <num_threads>\n", argv[0]);
        exit(EXIT_FAILURE);
    }
    int t = atoi(argv[2]);
    if (t <= 0) {
        fprintf(stderr, "Error: num_threads must be Z+.\n");
        exit(EXIT_FAILURE);
    }
    return t;
}

int main(int argc, char *argv[]) {

    int n       = extractN(argc, argv);
    int n_threads = extractThreads(argc, argv);

    if (n_threads > n) n_threads = n;

    int** matrix1 = matrixGenerator(n);
    int** matrix2 = matrixGenerator(n);
    int** result  = matrixGenerator(n);

    fillMatrix(matrix1, n);
    fillMatrix(matrix2, n);

    pthread_t*  threads = malloc(n_threads * sizeof(pthread_t));
    ThreadArgs* args    = malloc(n_threads * sizeof(ThreadArgs));
    if (!threads || !args) { perror("malloc threads"); exit(EXIT_FAILURE); }

    /* Distribute rows as evenly as possible across threads.
     * If N is not divisible by n_threads, the last thread takes
     * the remaining rows. */
    int rows_per_thread = n / n_threads;

    struct timespec t_start, t_end;
    clock_gettime(CLOCK_MONOTONIC, &t_start);

    for (int t = 0; t < n_threads; t++) {
        args[t].matrix1   = matrix1;
        args[t].matrix2   = matrix2;
        args[t].result    = result;
        args[t].n         = n;
        args[t].row_start = t * rows_per_thread;
        args[t].row_end   = (t == n_threads - 1) ? n : (t + 1) * rows_per_thread;

        if (pthread_create(&threads[t], NULL, threadWorker, &args[t]) != 0) {
            perror("pthread_create");
            exit(EXIT_FAILURE);
        }
    }

    for (int t = 0; t < n_threads; t++) {
        if (pthread_join(threads[t], NULL) != 0) {
            perror("pthread_join");
            exit(EXIT_FAILURE);
        }
    }

    clock_gettime(CLOCK_MONOTONIC, &t_end);

    printElapsed(elapsedMs(t_start, t_end));

    // printMatrix(matrix1, n);
    // printMatrix(matrix2, n);
    // printMatrix(result,  n);

    free(threads);
    free(args);
    freeMatrix(matrix1, n);
    freeMatrix(matrix2, n);
    freeMatrix(result,  n);

    return EXIT_SUCCESS;
}