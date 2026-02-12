
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

void fillMatrixWithZero(int** matrix, int n){
    for (int i = 0; i < n; i++) {
        for (int j = 0; j < n; j++) {
            matrix[i][j] = 0;
        }
    }
}

void fillMatrix(int** matrix, int n){
    srand(time(NULL) + rand());
    for (int i = 0; i < n; i++){
        for (int j = 0; j < n; j++){
            matrix[i][j] = rand() % 101;
        }
    }
}

int** matixMultiply(int** matrix1, int** matrix2, int** result, int n){
    fillMatrixWithZero(result, n);
    
    for (int i = 0; i < n; i++){
        for (int j = 0; j < n; j++){
            for (int k = 0; k < n; k++){
                result[i][j] += matrix1[i][k] * matrix2[k][j];
            }
        }
    }

    return result;
}

void printMatrix(int** matriz, int n) {
    
    int max_width = 1;
    for (int i = 0; i < n; i++) {
        for (int j = 0; j < n; j++) {
            int num = matriz[i][j];
            int width = (num == 0) ? 1 : 0;
            if (num < 0) width++;
            num = abs(num);
            while (num > 0) {
                width++;
                num /= 10;
            }
            if (width > max_width) max_width = width;
        }
    }
    
    for (int i = 0; i < n; i++) {
        if (i == 0) {
            printf("┌ ");
        } else if (i == n - 1) {
            printf("└ ");
        } else {
            printf("│ ");
        }
        
        for (int j = 0; j < n; j++) {
            printf("%*d", max_width + 1, matriz[i][j]);
        }
        
        if (i == 0) {
            printf(" ┐\n");
        } else if (i == n - 1) {
            printf(" ┘\n");
        } else {
            printf(" │\n");
        }
    }
}

int extractN(int argc, char *argv[]){
    int n;
    if (argc >= 2){
        n = atoi(argv[1]);
        if (n <= 0){
            printf("- n arg must be positive");
            exit(EXIT_FAILURE);
        }
        return n;
    } else {
        printf("- n arg not be provided");
        exit(EXIT_FAILURE);
        
    }
}

int main(int argc, char *argv[]){

    int n = extractN(argc, argv);

    int** matrix1 = matrixGenerator(n);
    int** matrix2 = matrixGenerator(n);
    int** result = matrixGenerator(n);


    fillMatrix(matrix1, n);
    fillMatrix(matrix2, n);

    matixMultiply(matrix1, matrix2, result, n);

    printMatrix(matrix1, n);
    printMatrix(matrix2, n);
    printMatrix(result, n);


}