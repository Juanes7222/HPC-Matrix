CC = gcc
CFLAGS = -Wall -Wextra -I./src
OPT_FLAGS = -O3 -march=native
PTHREAD_FLAGS = -pthread
OMP_FLAGS = -fopenmp

SRC_DIR = src
BIN_DIR = bin
TESTS_DIR = tests

# Archivo de libreria base
LIB_SRC = $(SRC_DIR)/matrix_lib.c
LIB_OBJ = $(BIN_DIR)/matrix_lib.o

# Ejecutables esperados
SEQ = $(BIN_DIR)/mul_seq
SEQ_CACHE = $(BIN_DIR)/mul_seq_cache
THREADS = $(BIN_DIR)/mul_threads
PROCESSES = $(BIN_DIR)/mul_conc
OMP_OPT   = $(BIN_DIR)/mul_omp_opt
OMP_NOOPT = $(BIN_DIR)/mul_omp_noopt
VERIFY = $(BIN_DIR)/verify_mul

all: setup $(SEQ) $(SEQ_CACHE) $(THREADS) $(PROCESSES) $(OPENMP) $(VERIFY)

setup:
	@mkdir -p $(BIN_DIR)

$(LIB_OBJ): $(LIB_SRC)
	$(CC) $(CFLAGS) $(OPT_FLAGS) -c $< -o $@

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

$(VERIFY): $(TESTS_DIR)/correctness/verify_mul.c $(LIB_OBJ)
	$(CC) $(CFLAGS) $(OPT_FLAGS) $^ -o $@

clean:
	rm -rf $(BIN_DIR)/*.o $(BIN_DIR)/*
