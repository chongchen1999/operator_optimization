// wmma + pipeline

#include <cuda_fp16.h>
#include <mma.h>
#include <cuda.h>
#include "includes/commons.cuh"

const int bm = 128;
const int bn = 128;
const int bk = 32;

const int wm = 64;
const int wn = 64;
const int wk = 16;

const int wmma_m = 16;
const int wmma_n = 16;
const int wmma_k = 16;

__device__ __forceinline__ void loadSmemA(half *smem, half *A, int M, int K, int k) {
    // load 128 * 32
    const int by = blockIdx.y;
    const int lane_id = threadIdx.x;
    const int warp_x = threadIdx.y;
    const int warp_y = threadIdx.z;
    const int tid = warp_y * 64 + warp_x * 32 + lane_id;

    #pragma unroll
    for (int i = 0; i < 4; ++i) {
        const int row = i * 32 + tid / 4; // 1 thread load 128-bit, 4 threads per row
        const int col = lane_id % 4 * 8; // 128-bit per thread, aka 8 half per thread

        // layout: [row_out, col_out, row_in, col_in] = [8, 2, 16, 16]
        const int row_o = row / 16;
        const int col_o = col / 16;
        const int row_i = row % 16;
        const int col_i = col % 16;
        void *ptr = reinterpret_cast<void *>(smem + row_o * (2 * 16 * 16) + col_o * (16 * 16) + row_i * 16 + col_i);
        uint32_t smem_ptr;

        asm(
            "{ .reg .u64 smem_ptr; cvta.to.shared.u64 smem_ptr, %1; cvt.u32.u64 %0, smem_ptr; }\n"
            : "=r"(smem_ptr)
            : "l"(ptr)
        );

        asm volatile(
            "cp.async.cg.shared.global [%0], [%1], %2;\n"
            :
            : "r"(smem_ptr), "l"(&A[(by * block_tile_m + row) * K + (k * bk + col)]), "n"(16)
        );
    }
}

__device__ __forceinline__ void loadSmemB(half *smem, half *B, int N, int K, int k) {
    // load 128 * 32
    const int bx = blockIdx.x;
    const int lane_id = threadIdx.x;
    const int warp_x = threadIdx.y;
    const int warp_y = threadIdx.z;
    const int tid = warp_y * 64 + warp_x * 32 + lane_id;

    #pragma unroll
    for (int i = 0; i < 4; ++i) {
        const int row = i * 32 + tid / 4;
        const int col = tid % 4 * 8;

        // layout: [row_out, col_out, row_in, col_in] = [8, 2, 16, 16]
        const int row_o = row / 16;
        const int col_o = col / 16;
        const int row_i = row % 16;
        const int col_i = col % 16;
        void *ptr = reinterpret_cast<void *>(smem + row_o * (2 * 16 * 16) + col_o * (16 * 16) + row_i * 16 + col_i);
        uint32_t smem_ptr;

        asm(
            "{ .reg .u64 smem_ptr; cvta.to.shared.u64 smem_ptr, %1; cvt.u32.u64 %0, smem_ptr; }\n"
            : "=r"(smem_ptr)
            : "l"(ptr)
        );

        asm volatile(
            "cp.async.cg.shared.global [%0], [%1], %2;\n" 
            :
            : "r"(smem_ptr), "l"(&B[(bx * block_tile_n + row) * K + (k * bk + col)]), "n"(16)
        );
    }
}

__device__ __forceinline__ void loadSmemC(float *smem, half *C, int M, int N) {
    // load 128 * 128
    const int bx = blockIdx.x;
    const int by = blockIdx.y;
    const int lane_id = threadIdx.x;
    const int warp_x = threadIdx.y;
    const int warp_y = threadIdx.z;
    const int tid = warp_y * 64 + warp_x * 32 + lane_id;

    #pragma unroll
    for (int i = 0; i < block_tile_m; ++i) {
        const int row = i;
        const int col = tid;

        // layout: [row_out, col_out, row_in, col_in] = [8, 8, 16, 16]
        const int row_o = row / 16;
        const int col_o = col / 16;
        const int row_i = row % 16;
        const int col_i = col % 16;
        smem[row_o * (8 * 16 * 16) + col_o * (16 * 16) + row_i * 16 + col_i % 16] = 
            static_cast<float>(C[(by * block_tile_m + row) * N + bx * block_tile_n + col]);
    }
}

__device__ __forceinline__ void storeSmemC(half *C, float *smem, int M, int N) {
    // load 128 * 128
    const int bx = blockIdx.x;
    const int by = blockIdx.y;
    const int lane_id = threadIdx.x;
    const int warp_x = threadIdx.y;
    const int warp_y = threadIdx.z;
    const int tid = warp_y * 64 + warp_x * 32 + lane_id;

    #pragma unroll
    for (int i = 0; i < block_tile_m; ++i) {
        const int row = i;
        const int col = tid;

        // layout: [row_out, col_out, row_in, col_in] = [8, 8, 16, 16]
        const int row_o = row / 16;
        const int col_o = col / 16;
        const int row_i = row % 16;
        const int col_i = col % 16;
        C[(by * block_tile_m + row) * N + bx * block_tile_m + col] = 
            static_cast<half>(smem[row_o * (8 * 16 * 16) + col_o * (16 * 16) + row_i * 16 + col_i % 16]);
    }
}

__device__ __forceinline__ void loadFragA(
    nvcuda::wmma::fragment<nvcuda::wmma::matrix_a, wmma_m, wmma_n, wmma_k, half, nvcuda::wmma::row_major> *frag, 
    half *smem, 
    int k
) {
    // load 64x16
    const int warp_y = threadIdx.z;
    #pragma unroll
    for (int i = 0; i < 4; ++i) {
        const int row = warp_y * 64 + i * 16;
        const int col = k * wk;
        nvcuda::wmma::load_matrix_sync(frag[i], smem + row / 16 * (2 * 16 * 16) + col / 16 * (16 * 16), 16);
    }
}

__device__ __forceinline__ void loadFragB(
    nvcuda::wmma::fragment<nvcuda::wmma::matrix_b, wmma_m, wmma_n, wmma_k, half, nvcuda::wmma::col_major> *frag, 
    half *smem, 
    int ki
) {
    // load 64x16
    int warp_x = threadIdx.y;
    for (int i = 0; i < 4; ++i) {
        int row = warp_x * 64 + i * 16;
        int col = ki * wk;
        nvcuda::wmma::load_matrix_sync(frag[i], smem + row / 16 * (2 * 16 * 16) + col / 16 * (16 * 16), 16);
    }
}

__device__ __forceinline__ void storeAccum(
    float *ptr, 
    nvcuda::wmma::fragment<nvcuda::wmma::accumulator, wmma_m, wmma_n, wmma_k, float> *frag
) {
    // store 64x64
    int warp_x = threadIdx.y;
    int warp_y = threadIdx.z;
    for (int i = 0; i < 4; ++i) {
        for (int j = 0; j < 4; ++j) {
            int row = warp_y * 64 + i * 16;
            int col = warp_x * 64 + j * 16;
            // laoyut: [8, 8, 16, 16]
            nvcuda::wmma::store_matrix_sync(
                ptr + row / 16 * (8 * 16 * 16) + col / 16 * (16 * 16), 
                frag[i * 4 + j], 16, 
                nvcuda::wmma::mem_row_major
            );
        }
    }
}

__device__ __forceinline__ void warp_mma(
    nvcuda::wmma::fragment<nvcuda::wmma::matrix_a, wmma_m, wmma_n, wmma_k, half, nvcuda::wmma::row_major> *frag_a, 
    nvcuda::wmma::fragment<nvcuda::wmma::matrix_b, wmma_m, wmma_n, wmma_k, half, nvcuda::wmma::col_major> *frag_b, 
    nvcuda::wmma::fragment<nvcuda::wmma::accumulator, wmma_m, wmma_n, wmma_k, float> *accum,
    half *SA, 
    half *SB,
    const int inner_iters_k,
    const int frags_m,
    const int frags_n
) {
    #pragma unroll
    for (int k = 0; k < inner_iters_k; ++k) {
        // 64x64x16 mma for each warp
        loadFragA(frag_a, SA, k);
        loadFragB(frag_b, SB, k);

        #pragma unroll
        for (int i = 0; i < frags_m; ++i) {
            #pragma unroll
            for (int j = 0; j < frags_n; ++j) {
                // 16x16x16 for each wmma
                nvcuda::wmma::mma_sync(
                    accum[i * frags_n + j], 
                    frag_a[i], frag_b[j], 
                    accum[i * frags_n + j]
                );
            }
        }
    }
}

__device__ __forceinline__ void loadSmemAndCommit(
    half *SA, 
    half *SB, 
    half *A, 
    half *B, 
    const int k,
    const int M, 
    const int N, 
    const int K
) {
    loadSmemA(SA, A, M, K, k);
    loadSmemB(SB, B, N, K, k);
    asm volatile("cp.async.commit_group;\n" ::);
}

__global__ void matmul(
    half *A, half *B, half *C, 
    int M, int N, int K, 
    float alpha, float beta
) {
    // A is row-major
    // B is col-major
    // 128 threads [x, y, z] = [32, 2, 2]
    // threadblock mma: 128x128x32
    // warp mma: 64x64x16
    extern __shared__ uint8_t shared_storage[];
    half *SA1 = reinterpret_cast<half *>(shared_storage);
    half *SA2 = SA1 + bm * bk;
    half *SA3 = SA2 + bm * bk;
    half *SA4 = SA3 + bm * bk;
    half *SB1 = SA4 + bm * bk;
    half *SB2 = SB1 + bn * bk;
    half *SB3 = SB2 + bn * bk;
    half *SB4 = SB3 + bn * bk;
    float *SC = reinterpret_cast<float *>(shared_storage);

    const int frags_m = wm / wmma_m;
    const int frags_n = wn / wmma_n;
    nvcuda::wmma::fragment<nvcuda::wmma::matrix_a, wmma_m, wmma_n, wmma_k, half, nvcuda::wmma::row_major> frag_a[frags_m];
    nvcuda::wmma::fragment<nvcuda::wmma::matrix_b, wmma_m, wmma_n, wmma_k, half, nvcuda::wmma::col_major> frag_b[frags_n];
    nvcuda::wmma::fragment<nvcuda::wmma::accumulator, wmma_m, wmma_n, wmma_k, float> accum[frags_m * frags_n];

    #pragma unroll
    for (int i = 0; i < frags_m; ++i) {
        #pragma unroll
        for (int j = 0; j < frags_n; ++j) {
            nvcuda::wmma::fill_fragment(accum[i * frags_n + j], 0.0);
        }
    }

    // prologue
    
    loadSmemAndCommit(SA1, SB1, A, B, 0, M, N, K);
    loadSmemAndCommit(SA2, SB2, A, B, 1, M, N, K);
    loadSmemAndCommit(SA3, SB3, A, B, 2, M, N, K);

    const int outter_iters_k = K / bk;
    const int inner_iters_k = bk / wk;

    for (int ko = 0; ko + 4 < outter_iters_k; ko += 4) {
        asm volatile("cp.async.wait_group %0;\n" ::"n"(2));
        __syncthreads();
        if (ko + 3 < outter_iters_k) {
            loadSmemAndCommit(SA4, SB4, A, B, ko + 3, M, N, K);
        }
        warp_mma(frag_a, frag_b, accum, SA1, SB1, inner_iters_k, frags_m, frags_n);

        asm volatile("cp.async.wait_group %0;\n" ::"n"(2));
        __syncthreads();
        if (ko + 4 < outter_iters_k) {
            loadSmemAndCommit(SA1, SB1, A, B, ko + 4, M, N, K);
        }
        warp_mma(frag_a, frag_b, accum, SA2, SB2, inner_iters_k, frags_m, frags_n);

        asm volatile("cp.async.wait_group %0;\n" ::"n"(2));
        __syncthreads();
        if (ko + 5 < outter_iters_k) {
            loadSmemAndCommit(SA2, SB2, A, B, ko + 5, M, N, K);
        }
        warp_mma(frag_a, frag_b, accum, SA3, SB3, inner_iters_k, frags_m, frags_n);

        asm volatile("cp.async.wait_group %0;\n" ::"n"(2));
        __syncthreads();
        if (ko + 6 < outter_iters_k) {
            loadSmemAndCommit(SA3, SB3, A, B, ko + 6, M, N, K);
        }
        warp_mma(frag_a, frag_b, accum, SA4, SB4, inner_iters_k, frags_m, frags_n);
    }

    // the last 4 iterations
    {
        int ko = (outter_iters_k / 4 - 1) * 4;

        if (ko < outter_iters_k) {
            warp_mma(frag_a, frag_b, accum, SA1, SB1, inner_iters_k, frags_m, frags_n);
        }
        if (ko + 1 < outter_iters_k) {
            warp_mma(frag_a, frag_b, accum, SA2, SB2, inner_iters_k, frags_m, frags_n);
        }
        if (ko + 2 < outter_iters_k) {
            warp_mma(frag_a, frag_b, accum, SA3, SB3, inner_iters_k, frags_m, frags_n);
        }
    }

    storeAccum(SC, accum);
    __syncthreads();
    storeSmemC(C, SC, M, N);
}