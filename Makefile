CC       = gcc
MPICC    = mpicc
CFLAGS   = -Wall -Wextra -I./src
OPT_FLAGS    = -O3 -march=native
PTHREAD_FLAGS = -pthread
OMP_FLAGS     = -fopenmp

SRC_DIR  = src
BIN_DIR  = bin
TESTS_DIR = tests

# Base library
LIB_SRC = $(SRC_DIR)/matrix_lib.c
LIB_OBJ = $(BIN_DIR)/matrix_lib.o

# MPI I/O module (used by MPI targets and gen_matrix)
MATRIX_IO_SRC = $(SRC_DIR)/mpi_nfs/matrix_io.c
MATRIX_IO_OBJ = $(BIN_DIR)/matrix_io.o

# Executables
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

# MPI targets are excluded from all: they require mpicc and a cluster setup.
# The benchmark script requests them explicitly via: make -B <target> OPT_FLAGS=...
all: setup $(SEQ) $(SEQ_CACHE) $(THREADS) $(PROCESSES) $(OMP_OPT) $(OMP_NOOPT) $(VERIFY) $(VERIFY_MPI) $(GEN_MATRIX) $(MPI_NFS_NOOPT) $(MPI_NFS_OPT)

setup:
	@mkdir -p $(BIN_DIR)

$(LIB_OBJ): $(LIB_SRC)
	$(CC) $(CFLAGS) $(OPT_FLAGS) -c $< -o $@

$(MATRIX_IO_OBJ): $(MATRIX_IO_SRC)
	$(CC) $(CFLAGS) -I$(SRC_DIR)/mpi_nfs $(OPT_FLAGS) -c $< -o $@

$(SEQ): $(SRC_DIR)/sequential/mul_seq.c $(LIB_OBJ)
	$(CC) $(CFLAGS) $(OPT_FLAGS) $^ -o $@

$(SEQ_CACHE): $(SRC_DIR)/sequential/mul_seq_cache.c $(LIB_OBJ)
	$(CC) $(CFLAGS) $(OPT_FLAGS) $^ -o $@

$(THREADS): $(SRC_DIR)/threads/mul_threads.c $(LIB_OBJ)
	$(CC) $(CFLAGS) $(OPT_FLAGS) $(PTHREAD_FLAGS) $^ -o $@

$(PROCESSES): $(SRC_DIR)/processes/mul_conc.c $(LIB_OBJ)
	$(CC) $(CFLAGS) $(OPT_FLAGS) $^ -o $@

$(OMP_OPT): $(SRC_DIR)/openmp/mul_openmp.c $(LIB_OBJ)
	$(CC) $(CFLAGS) $(OPT_FLAGS) $(OMP_FLAGS) $^ -o $@

$(OMP_NOOPT): $(SRC_DIR)/openmp/mul_openmp.c $(LIB_OBJ)
	$(CC) $(CFLAGS) $(OPT_FLAGS) $(OMP_FLAGS) $^ -o $@

$(MPI_NFS_OPT): $(SRC_DIR)/mpi_nfs/mul_mpi_nfs.c $(MATRIX_IO_OBJ) $(LIB_OBJ)
	$(MPICC) $(CFLAGS) -I$(SRC_DIR)/mpi_nfs $(OPT_FLAGS) $^ -o $@

$(MPI_NFS_NOOPT): $(SRC_DIR)/mpi_nfs/mul_mpi_nfs.c $(MATRIX_IO_OBJ) $(LIB_OBJ)
	$(MPICC) $(CFLAGS) -I$(SRC_DIR)/mpi_nfs $(OPT_FLAGS) $^ -o $@

$(GEN_MATRIX): $(SRC_DIR)/mpi_nfs/gen_matrix.c $(MATRIX_IO_OBJ)
	$(CC) $(CFLAGS) -I$(SRC_DIR)/mpi_nfs $(OPT_FLAGS) $^ -o $@

$(VERIFY): $(TESTS_DIR)/correctness/verify_mul.c $(LIB_OBJ)
	$(CC) $(CFLAGS) $(OPT_FLAGS) $^ -o $@

$(VERIFY_MPI): $(TESTS_DIR)/correctness/verify_mpi.c $(MATRIX_IO_OBJ) $(LIB_OBJ)
	$(CC) $(CFLAGS) -I$(SRC_DIR)/mpi_nfs $(OPT_FLAGS) $^ -o $@

clean:
	rm -rf $(BIN_DIR)/*.o $(BIN_DIR)/*