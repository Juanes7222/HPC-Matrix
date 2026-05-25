CC            = gcc
MPICC         = mpicc
CFLAGS        = -Wall -Wextra -I./src
OPT_FLAGS     = -O3 -march=native
PTHREAD_FLAGS = -pthread
OMP_FLAGS     = -fopenmp
NFS_DIR      ?= /mnt/share/hpc-matrix

SRC_DIR  = src
BIN_DIR  = bin
TESTS_DIR = tests

LIB_SRC          = $(SRC_DIR)/matrix_lib.c
LIB_OBJ_OPT      = $(BIN_DIR)/matrix_lib_opt.o
LIB_OBJ_NOOPT    = $(BIN_DIR)/matrix_lib_noopt.o

MATRIX_IO_SRC    = $(SRC_DIR)/mpi_nfs/matrix_io.c
MATRIX_IO_OBJ    = $(BIN_DIR)/matrix_io.o

SEQ           = $(BIN_DIR)/mul_seq
SEQ_CACHE     = $(BIN_DIR)/mul_seq_cache
THREADS       = $(BIN_DIR)/mul_threads
PROCESSES     = $(BIN_DIR)/mul_conc
OMP_OPT       = $(BIN_DIR)/mul_omp_opt
OMP_NOOPT     = $(BIN_DIR)/mul_omp_noopt
MPI_NFS_OPT   = $(BIN_DIR)/mul_mpi_nfs_opt
MPI_NFS_NOOPT = $(BIN_DIR)/mul_mpi_nfs_noopt
GEN_MATRIX    = $(BIN_DIR)/gen_matrix
VERIFY        = $(BIN_DIR)/verify_mul
VERIFY_MPI    = $(BIN_DIR)/verify_mpi

all: setup \
     $(SEQ) $(SEQ_CACHE) $(THREADS) $(PROCESSES) \
     $(OMP_OPT) $(OMP_NOOPT) \
     $(MPI_NFS_OPT) $(MPI_NFS_NOOPT) \
     $(GEN_MATRIX) $(VERIFY) $(VERIFY_MPI)

setup:
    @mkdir -p $(BIN_DIR)

$(LIB_OBJ_OPT): $(LIB_SRC)
    $(CC) $(CFLAGS) $(OPT_FLAGS) -c $< -o $@

$(LIB_OBJ_NOOPT): $(LIB_SRC)
    $(CC) $(CFLAGS) -c $< -o $@

$(MATRIX_IO_OBJ): $(MATRIX_IO_SRC)
    $(CC) $(CFLAGS) -I$(SRC_DIR)/mpi_nfs $(OPT_FLAGS) -c $< -o $@

$(SEQ): $(SRC_DIR)/sequential/mul_seq.c $(LIB_OBJ_OPT)
    $(CC) $(CFLAGS) $(OPT_FLAGS) $^ -o $@

$(SEQ_CACHE): $(SRC_DIR)/sequential/mul_seq_cache.c $(LIB_OBJ_OPT)
    $(CC) $(CFLAGS) $(OPT_FLAGS) $^ -o $@

$(THREADS): $(SRC_DIR)/threads/mul_threads.c $(LIB_OBJ_OPT)
    $(CC) $(CFLAGS) $(OPT_FLAGS) $(PTHREAD_FLAGS) $^ -o $@

$(PROCESSES): $(SRC_DIR)/processes/mul_conc.c $(LIB_OBJ_OPT)
    $(CC) $(CFLAGS) $(OPT_FLAGS) $^ -o $@

$(OMP_OPT): $(SRC_DIR)/openmp/mul_openmp.c $(LIB_OBJ_OPT)
    $(CC) $(CFLAGS) $(OPT_FLAGS) $(OMP_FLAGS) $^ -o $@

$(OMP_NOOPT): $(SRC_DIR)/openmp/mul_openmp.c $(LIB_OBJ_NOOPT)
    $(CC) $(CFLAGS) $(OMP_FLAGS) $^ -o $@

$(MPI_NFS_OPT): $(SRC_DIR)/mpi_nfs/mul_mpi_nfs.c $(MATRIX_IO_OBJ) $(LIB_OBJ_OPT)
    $(MPICC) $(CFLAGS) -I$(SRC_DIR)/mpi_nfs $(OPT_FLAGS) $^ -o $@

$(MPI_NFS_NOOPT): $(SRC_DIR)/mpi_nfs/mul_mpi_nfs.c $(MATRIX_IO_OBJ) $(LIB_OBJ_NOOPT)
    $(MPICC) $(CFLAGS) -I$(SRC_DIR)/mpi_nfs $^ -o $@

$(GEN_MATRIX): $(SRC_DIR)/mpi_nfs/gen_matrix.c $(MATRIX_IO_OBJ)
    $(CC) $(CFLAGS) -I$(SRC_DIR)/mpi_nfs $(OPT_FLAGS) $^ -o $@

$(VERIFY): $(TESTS_DIR)/correctness/verify_mul.c $(LIB_OBJ_OPT)
    $(CC) $(CFLAGS) $(OPT_FLAGS) $^ -o $@

$(VERIFY_MPI): $(TESTS_DIR)/correctness/verify_mpi.c $(MATRIX_IO_OBJ) $(LIB_OBJ_OPT)
    $(CC) $(CFLAGS) -I$(SRC_DIR)/mpi_nfs $(OPT_FLAGS) $^ -o $@

deploy: $(MPI_NFS_OPT) $(MPI_NFS_NOOPT) $(GEN_MATRIX)
    @echo "Deploying to $(NFS_DIR)"
    @mkdir -p $(NFS_DIR)/bin $(NFS_DIR)/data/input $(NFS_DIR)/results/csv \
              $(NFS_DIR)/results/logs $(NFS_DIR)/results/raw $(NFS_DIR)/tmp
    @cp $(MPI_NFS_OPT)   $(NFS_DIR)/bin/
    @cp $(MPI_NFS_NOOPT) $(NFS_DIR)/bin/
    @cp $(GEN_MATRIX)    $(NFS_DIR)/bin/
    @echo "Done -> $(NFS_DIR)/bin"

clean:
    rm -rf $(BIN_DIR)