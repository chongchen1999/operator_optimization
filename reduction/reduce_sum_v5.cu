#include <bits/stdc++.h>
#include <cuda_runtime.h>

const int N = 1 << 25; // 2^25 elements
const int iterations = 5000;

__device__ void warp_reduce(volatile int *shared_data, const int &tid) {
    shared_data[tid] += shared_data[tid + 32];
    shared_data[tid] += shared_data[tid + 16];
    shared_data[tid] += shared_data[tid + 8];
    shared_data[tid] += shared_data[tid + 4];
    shared_data[tid] += shared_data[tid + 2];
    shared_data[tid] += shared_data[tid + 1];
}

template <int block_size>
__global__ void sum_kernel(int *data, int *partial_sums) {
    __shared__ int shared_data[block_size];
    int tid = threadIdx.x + blockDim.x * blockIdx.x;
    int offset = blockDim.x * gridDim.x;

    int sum = 0;
    int i = tid;

    // Unroll the first for-loop
    while (i < N) {
        sum += data[i];
        i += offset;
    }

    shared_data[threadIdx.x] = sum;
    __syncthreads();

    // Unroll the second for-loop
    if (blockDim.x >= 512) {
        if (threadIdx.x < 256) {
            shared_data[threadIdx.x] += shared_data[threadIdx.x + 256];
        }
        __syncthreads();
    }

    if (blockDim.x >= 256) {
        if (threadIdx.x < 128) {
            shared_data[threadIdx.x] += shared_data[threadIdx.x + 128];
        }
        __syncthreads();
    }

    if (blockDim.x >= 128) {
        if (threadIdx.x < 64) {
            shared_data[threadIdx.x] += shared_data[threadIdx.x + 64];
        }
        __syncthreads();
    }

    if (threadIdx.x < 32) {
        warp_reduce(shared_data, threadIdx.x);
    }

    if (threadIdx.x == 0) {
        partial_sums[blockIdx.x] = shared_data[0];
    }
}

void get_sum(const int *data, const int &N, int &sum) {
    for (int i = 0; i < N; ++i) {
        sum += data[i];
    }
}

int main() {
    std::srand(static_cast<unsigned>(std::time(nullptr)));
    int *host_data = (int *)malloc(N * sizeof(int));
    int cpu_sum = 0;
    for (int i = 0; i < N; ++i) {
        int random_int = std::rand() % 57;
        host_data[i] = random_int;
        cpu_sum += random_int;
    }
    printf("CPU sum: %d\n", cpu_sum);

    int *device_data;
    cudaMalloc(&device_data, N * sizeof(int));

    constexpr int grid_size = 2048;
    constexpr int block_size = 256;

    dim3 block(block_size);
    dim3 grid(grid_size);

    int *host_partial_sums = (int *)malloc(grid_size * sizeof(int));
    int *device_partial_sums;
    cudaMalloc(&device_partial_sums, grid_size * sizeof(int));

    cudaMemcpy(device_data, host_data, N * sizeof(int), cudaMemcpyHostToDevice);

    cudaEvent_t start, stop;
    cudaEventCreate(&start);
    cudaEventCreate(&stop);
    cudaEventRecord(start);
    for (int i = 0; i < iterations; ++i) {
        sum_kernel<block_size><<<grid, block>>>(device_data, device_partial_sums);
    }
    cudaEventRecord(stop);
    cudaEventSynchronize(stop);

    float milliseconds = 0;
    cudaEventElapsedTime(&milliseconds, start, stop);
    printf("Time: %f ms\n", milliseconds / iterations);

    cudaMemcpy(host_partial_sums, device_partial_sums, grid_size * sizeof(int), cudaMemcpyDeviceToHost);
    int gpu_sum = 0;
    get_sum(host_partial_sums, grid_size, gpu_sum);
    if (cpu_sum != gpu_sum) {
        printf("Error: %d != %d\n", cpu_sum, gpu_sum);
    } else {
        printf("Success!\n");
    }

    // Calculate Bandwidth
    float total_data_transferred = N * sizeof(int) + grid_size * sizeof(int); // in bytes
    float average_time_per_iteration = milliseconds / iterations / 1000; // in seconds
    float bandwidth = total_data_transferred / average_time_per_iteration / (1 << 30); // in GB/s

    printf("Bandwidth: %f GB/s\n", bandwidth);

    cudaFree(device_data);
    cudaFree(device_partial_sums);
    free(host_data);
    free(host_partial_sums);
    cudaEventDestroy(start);
    cudaEventDestroy(stop);
    return 0;
}