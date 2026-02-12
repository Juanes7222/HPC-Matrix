
#include <stdlib.h>
#include <stdio.h>
#include <time.h>

int** matrixGenerator(int n){
    int **matrix = (int**)malloc(n * sizeof(int*));
    for (int i=0; i < n; i++){
        matrix[i] = (int*)malloc(n * sizeof(int*));
    }

    return matrix;
}

void fillMatrix(int** matrix, int n){
    srand(time(NULL));
    for (int i = 0; i < n; i++){
        for (int j = 0; j < n; j++){
            matrix[i][j] = rand();
        }
    }
}

int** matixMultiply(int** matrix1, int** matrix2, int** result, int n){
    for (int i = 0; i < n; i++){
        for (int j = 0; j < n; j++){
            for (int k = 0; k < n; k++){
                result[i][j] = matrix1[i][k] * matrix2[k][j];
            }
        }
    }

    return result;
}

void printMatrix(int** matrix, int n){
    printf("[ ");
    for (int i = 0; i < n; i++){
        for (int j = 0; j < n; j++){
            printf("%4d ", matrix[i][j]);
        }
        printf("\n");
    }
    printf(" ]");
}

int extractN(int argc, char *argv[]){
    int n;
    if (argc >= 2){
        n = atoi(argv[1]);
        if (n <= 0){
            printf("- n arg must be positive");
            return -1;
        }
        return n;
    } else {
        printf("- n arg not be provided");
        return -1;
    }
}

void main(int argc, char *argv[]){

    int n;

    int** matrix1 = matrixGenerator(n);
    int** matrix2 = matrixGenerator(n);
    int** result = matrixGenerator(n);


    fillMatrix(matrix1, n);
    fillMatrix(matrix2, n);

    matixMultiply(matrix1, matrix2, result, n);

    printMatrix(result, n);


}