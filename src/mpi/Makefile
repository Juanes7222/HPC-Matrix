CC     = gcc
MPICC  = mpicc
CFLAGS = -O2 -Wall -Wextra

all: gen_matrix mul_mpi_nfs

gen_matrix: gen_matrix.c matrix_io.c matrix_io.h
	$(CC) $(CFLAGS) -o gen_matrix gen_matrix.c matrix_io.c

mul_mpi_nfs: mul_mpi_nfs.c matrix_io.c matrix_io.h
	$(MPICC) $(CFLAGS) -o mul_mpi_nfs mul_mpi_nfs.c matrix_io.c

clean:
	rm -f gen_matrix mul_mpi_nfs
