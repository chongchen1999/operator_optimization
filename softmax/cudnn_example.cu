#include <stdlib.h>
#include <stdio.h>
#include <time.h>

#include <cudnn.h>

/**
 * Verified correctness with cuDNN 6.5-R1.
 * 
 * Author: Jon Gauthier <jon@gauthiers.net>
 * February 2015
 * 
 * How to run:
 * 
 *     export LD_LIBRARY_PATH=${CUDNN_PATH}:${LD_LIBRARY_PATH}
 *     nvcc -g -O0 -Xcompiler -std=c99 -I${CUDNN_PATH} -lcudnn cudnn_softmax.cu -o cudnn_softmax || exit 1
 *     ./cudnn_softmax
 */

void printMatrix(const double *mat, int m, int n) {
    for (int j = 0; j < n; j++) {
        for (int i = 0; i < m; i++) {
            printf("%f\n", mat[j * m + i]);
        }
        printf("\n\n");
    }
}

double *makeDiffData(int m, int c) {
  double *diff = (double *) calloc(m * c, sizeof(double));
  for (int j = 0; j < m; j++) {
    int class = rand() % c;
    printf("%d class: %d\n", j, class);
    for (int i = 0; i < c; i++)
      diff[j * c + i] = class == i ? -c / (double) m : 0;
  }

  return diff;
}

int main() {
    int m = 5, c = 4, numChannels = 1;

    srand(time(NULL));
    double *fcLayer = (double *) malloc(m * c * sizeof(double));
    for (int i = 0; i < m; i++) {
        double def = rand() % 25;
        for (int c_idx = 0; c_idx < c; c_idx++) {
            int offset = i * c + c_idx;
            fcLayer[offset] = def;
        }
    }
    printf("FC LAYER:\n");
    printMatrix(fcLayer, c, m);

    double *d_fcLayer;
    cudaMalloc((void**) &d_fcLayer, m * c * sizeof(double));
    cudaMemcpy(d_fcLayer, fcLayer, m * c * sizeof(double), cudaMemcpyHostToDevice);

    double *d_softmaxData;
    cudaMalloc((void**) &d_softmaxData, m * c * sizeof(double));

    cudnnHandle_t cudnnHandle;
    cudnnCreate(&cudnnHandle);

    // softmaxForward(n, c, h, w, dstData, &srcData);
    cudnnTensor4dDescriptor_t srcTensorDesc, sftTensorDesc;
    cudnnCreateTensor4dDescriptor(&srcTensorDesc);
    cudnnCreateTensor4dDescriptor(&sftTensorDesc);
    cudnnSetTensor4dDescriptor(srcTensorDesc, CUDNN_TENSOR_NCHW, CUDNN_DATA_DOUBLE,
            m, c, 1, 1);
    cudnnSetTensor4dDescriptor(sftTensorDesc, CUDNN_TENSOR_NCHW, CUDNN_DATA_DOUBLE,
            m, c, 1, 1);
    cudnnSoftmaxForward(cudnnHandle, CUDNN_SOFTMAX_ACCURATE, CUDNN_SOFTMAX_MODE_CHANNEL,
            srcTensorDesc, d_fcLayer, sftTensorDesc, d_softmaxData);

    cudaDeviceSynchronize();

    // Copy back
    double *result = (double *) malloc(m * c * sizeof(double));
    cudaMemcpy(result, d_softmaxData, m * c * sizeof(double), cudaMemcpyDeviceToHost);
    cudaDeviceSynchronize();

    // Log
    printf("SOFTMAX:\n");
    printMatrix(result, c, m);

    // Try backward
    cudnnTensor4dDescriptor_t diffTensorDesc;
    cudnnCreateTensor4dDescriptor(&diffTensorDesc);
    cudnnSetTensor4dDescriptor(diffTensorDesc, CUDNN_TENSOR_NCHW, CUDNN_DATA_DOUBLE,
                               m, c, 1, 1);

    double *d_gradData;
    cudaMalloc((void**) &d_gradData, m * c * sizeof(double));

    double *diffData = makeDiffData(m, c);
    double *d_diffData;
    cudaMalloc((void**) &d_diffData, m * c * sizeof(double));
    cudaMemcpy(d_diffData, diffData, m * c * sizeof(double), cudaMemcpyHostToDevice);
    cudaDeviceSynchronize();

    cudnnSoftmaxBackward(cudnnHandle, CUDNN_SOFTMAX_ACCURATE, CUDNN_SOFTMAX_MODE_CHANNEL,
                         srcTensorDesc, d_softmaxData, diffTensorDesc, d_diffData, sftTensorDesc, d_gradData);
    cudaDeviceSynchronize();

    // Copy back
    double *result_backward = (double *) malloc(m * c * sizeof(double));
    cudaMemcpy(result_backward, d_gradData, m * c * sizeof(double), cudaMemcpyDeviceToHost);
    cudaDeviceSynchronize();

    // Log
    printf("GRADIENT:\n");
    printMatrix(result_backward, c, m);

    // Destruct
    free(result);
    free(diffData);
    free(result_backward);
    free(fcLayer);

    cudnnDestroyTensor4dDescriptor(srcTensorDesc);
    cudnnDestroyTensor4dDescriptor(sftTensorDesc);
    cudnnDestroyTensor4dDescriptor(diffTensorDesc);
    cudaFree(d_fcLayer);
    cudaFree(d_softmaxData);
    cudaFree(d_gradData);
    cudaFree(d_diffData);
    cudnnDestroy(cudnnHandle);
    return 0;
}