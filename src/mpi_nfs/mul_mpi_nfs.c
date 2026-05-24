#include <mpi.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "matrix_io.h"
#include "matrix_lib.h"

/*
 * Fills rows_per_rank, sendcounts, and displs for MPI_Scatterv / MPI_Gatherv.
 * Ranks 0..(n%num_procs-1) receive one extra row to absorb the remainder.
 */
static void build_distribution(int n, int num_procs,
                                int *rows_per_rank,
                                int *sendcounts,
                                int *displs) {
    int base  = n / num_procs;
    int extra = n % num_procs;

    for (int r = 0; r < num_procs; r++) {
        rows_per_rank[r] = base + (r < extra ? 1 : 0);
        sendcounts[r]    = rows_per_rank[r] * n;
    }

    displs[0] = 0;
    for (int r = 1; r < num_procs; r++)
        displs[r] = displs[r - 1] + sendcounts[r - 1];
}

int main(int argc, char *argv[]) {
    MPI_Init(&argc, &argv);

    int rank, size;
    MPI_Comm_rank(MPI_COMM_WORLD, &rank);
    MPI_Comm_size(MPI_COMM_WORLD, &size);

    if (argc != 4) {
        if (rank == 0)
            fprintf(stderr, "Usage: %s <A.bin> <B.bin> <C.bin>\n", argv[0]);
        MPI_Abort(MPI_COMM_WORLD, 1);
    }

    /* ------------------------------------------------------------------ */
    /* I/O phase: rank 0 reads A; all ranks read B independently from NFS */
    /* ------------------------------------------------------------------ */
    MPI_Barrier(MPI_COMM_WORLD);
    double t_total_start = MPI_Wtime();
    double t_io_start    = t_total_start;

    int n       = 0;
    int *a_full = NULL;

    if (rank == 0) {
        n = matrix_read_bin(argv[1], &a_full);
        if (n < 0) {
            fprintf(stderr, "rank 0: cannot read A from %s\n", argv[1]);
            MPI_Abort(MPI_COMM_WORLD, 1);
        }
    }

    /* Broadcast N so all ranks can validate B and allocate memory. */
    MPI_Bcast(&n, 1, MPI_INT, 0, MPI_COMM_WORLD);

    int *b  = NULL;
    int n_b = matrix_read_bin(argv[2], &b);
    if (n_b < 0) {
        fprintf(stderr, "rank %d: cannot read B from %s\n", rank, argv[2]);
        MPI_Abort(MPI_COMM_WORLD, 1);
    }
    if (n_b != n) {
        fprintf(stderr, "rank %d: B is %dx%d but A is %dx%d\n",
                rank, n_b, n_b, n, n);
        MPI_Abort(MPI_COMM_WORLD, 1);
    }

    MPI_Barrier(MPI_COMM_WORLD);
    double t_io_end = MPI_Wtime();

    /* ------------------------------------------------------------------ */
    /* Distribution setup                                                   */
    /* ------------------------------------------------------------------ */
    int *rows_per_rank = malloc(size * sizeof(int));
    int *sendcounts    = malloc(size * sizeof(int));
    int *displs        = malloc(size * sizeof(int));
    if (!rows_per_rank || !sendcounts || !displs) {
        fprintf(stderr, "rank %d: malloc failed for distribution arrays\n", rank);
        MPI_Abort(MPI_COMM_WORLD, 1);
    }

    build_distribution(n, size, rows_per_rank, sendcounts, displs);

    int local_rows = rows_per_rank[rank];
    int *local_a   = malloc((size_t)local_rows * n * sizeof(int));
    int *local_c   = malloc((size_t)local_rows * n * sizeof(int));
    if (!local_a || !local_c) {
        fprintf(stderr, "rank %d: malloc failed for local arrays\n", rank);
        MPI_Abort(MPI_COMM_WORLD, 1);
    }

    /* ------------------------------------------------------------------ */
    /* Scatter rows of A                                                    */
    /* ------------------------------------------------------------------ */
    MPI_Barrier(MPI_COMM_WORLD);
    double t_scatter_start = MPI_Wtime();

    MPI_Scatterv(a_full, sendcounts, displs, MPI_INT,
                 local_a, sendcounts[rank], MPI_INT,
                 0, MPI_COMM_WORLD);

    MPI_Barrier(MPI_COMM_WORLD);
    double t_scatter_end = MPI_Wtime();

    if (rank == 0) { free(a_full); a_full = NULL; }

    /* ------------------------------------------------------------------ */
    /* Local computation                                                    */
    /* ------------------------------------------------------------------ */
    MPI_Barrier(MPI_COMM_WORLD);
    double t_compute_start = MPI_Wtime();

    memset(local_c, 0, (size_t)local_rows * n * sizeof(int));
    matrixMultiplyRangeFlat(local_a, b, local_c, n, 0, local_rows);

    MPI_Barrier(MPI_COMM_WORLD);
    double t_compute_end = MPI_Wtime();

    /* ------------------------------------------------------------------ */
    /* Gather result into C on rank 0                                       */
    /* ------------------------------------------------------------------ */
    int *c_full = NULL;
    if (rank == 0) {
        c_full = malloc((size_t)n * n * sizeof(int));
        if (!c_full) {
            fprintf(stderr, "rank 0: malloc failed for C\n");
            MPI_Abort(MPI_COMM_WORLD, 1);
        }
    }

    MPI_Barrier(MPI_COMM_WORLD);
    double t_gather_start = MPI_Wtime();

    MPI_Gatherv(local_c, sendcounts[rank], MPI_INT,
                c_full, sendcounts, displs, MPI_INT,
                0, MPI_COMM_WORLD);

    MPI_Barrier(MPI_COMM_WORLD);
    double t_gather_end = MPI_Wtime();

    double t_total_end = t_gather_end;

    /* ------------------------------------------------------------------ */
    /* Write result                                                         */
    /* ------------------------------------------------------------------ */
    if (rank == 0) {
        if (matrix_write_bin(argv[3], c_full, n) != 0)
            fprintf(stderr, "rank 0: error writing C to %s\n", argv[3]);
        free(c_full);
    }

    /* ------------------------------------------------------------------ */
    /* Timing report: max across all ranks to reflect the slowest process  */
    /* ------------------------------------------------------------------ */
    double times_local[5] = {
        t_io_end      - t_io_start,
        t_scatter_end - t_scatter_start,
        t_compute_end - t_compute_start,
        t_gather_end  - t_gather_start,
        t_total_end   - t_total_start
    };
    double times_max[5];
    MPI_Reduce(times_local, times_max, 5, MPI_DOUBLE, MPI_MAX, 0, MPI_COMM_WORLD);

    if (rank == 0) {
        printf("io=%.3f scatter=%.3f compute=%.3f gather=%.3f total=%.3f\n",
               times_max[0] * 1e3,
               times_max[1] * 1e3,
               times_max[2] * 1e3,
               times_max[3] * 1e3,
               times_max[4] * 1e3);
    }

    /* ------------------------------------------------------------------ */
    /* Cleanup                                                              */
    /* ------------------------------------------------------------------ */
    free(local_a);
    free(local_c);
    free(b);
    free(rows_per_rank);
    free(sendcounts);
    free(displs);

    MPI_Finalize();
    return EXIT_SUCCESS;
}