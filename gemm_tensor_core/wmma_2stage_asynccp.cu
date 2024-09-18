// wmma + pipeline

#include <cuda_fp16.h>
#include <mma.h>
#include <cuda.h>

using namespace nvcuda;

template <
    int bm = 128, int bn = 128, int bk = 32, 
    int wm = 64, int wn = 64, int wk = 16,
    int wmma_m = 16, int wmma_n = 16, int wmma_k = 16
>
__device__ __forceinline__ void loadSmemA(half *smem, half *A, int M, int K, int k) {
    // load 128 * 32
    const int by = blockIdx.y;
    const int lane_id = threadIdx.x;
    const int warp_x = threadIdx.y;
    const int warp_y = threadIdx.z;
    const int tid = (warp_y << 6) + (warp_x << 5) + lane_id;

    #pragma unroll
    for (int i = 0; i < 4; ++i) {
        const int row = (i << 5) + (tid >> 2); // 1 thread load 128-bit, 4 threads per row
        const int col = (lane_id >> 2) << 3; // 128-bit per thread, aka 8 half per thread

        // layout: [row_out, col_out, row_in, col_in] = [8, 2, 16, 16]
        const int row_o = row >> 4;
        const int col_o = col >> 4;
        const int row_i = row & 15;
        const int col_i = col & 15;
        void *ptr = reinterpret_cast<void *>(smem + (row_o << 9) + (col_o << 8) + (row_i << 4) + col_i);
        uint32_t smem_ptr;

        asm(
            "{ .reg .u64 smem_ptr; cvta.to.shared.u64 smem_ptr, %1; cvt.u32.u64 %0, smem_ptr; }\n"
            : "=r"(smem_ptr)
            : "l"(ptr)
        );

        asm volatile(
            "cp.async.cg.shared.global [%0], [%1], %2;\n"
            :
            : "r"(smem_ptr), "l"(&A[(by * bm + row) * K + (k * bk + col)]), "n"(16)
        );
    }
}

template <
    int bm = 128, int bn = 128, int bk = 32, 
    int wm = 64, int wn = 64, int wk = 16,
    int wmma_m = 16, int wmma_n = 16, int wmma_k = 16
>
__device__ __forceinline__ void loadSmemB(half *smem, half *B, int N, int K, int k) {
    // load 128 * 32
    const int bx = blockIdx.x;
    const int lane_id = threadIdx.x;
    const int warp_x = threadIdx.y;
    const int warp_y = threadIdx.z;
    // const int tid = warp_y * 64 + warp_x * 32 + lane_id;
    const int tid = (warp_y << 6) + (warp_x << 5) + lane_id;

    #pragma unroll
    for (int i = 0; i < 4; ++i) {
        const int row = (i << 5) + (tid >> 2); // 1 thread load 128-bit, 4 threads per row
        const int col = (lane_id >> 2) << 3; // 128-bit per thread, aka 8 half per thread

        // layout: [row_out, col_out, row_in, col_in] = [8, 2, 16, 16]
        const int row_o = row >> 4;
        const int col_o = col >> 4;
        const int row_i = row & 15;
        const int col_i = col & 15;
        void *ptr = reinterpret_cast<void *>(smem + (row_o << 9) + (col_o << 8) + (row_i << 4) + col_i);
        uint32_t smem_ptr;

        asm(
            "{ .reg .u64 smem_ptr; cvta.to.shared.u64 smem_ptr, %1; cvt.u32.u64 %0, smem_ptr; }\n"
            : "=r"(smem_ptr)
            : "l"(ptr)
        );

        asm volatile(
            "cp.async.cg.shared.global [%0], [%1], %2;\n" 
            :
            : "r"(smem_ptr), "l"(&B[(bx * bn + row) * K + (k * bk + col)]), "n"(16)
        );
    }
}

template <
    int bm = 128, int bn = 128, int bk = 32, 
    int wm = 64, int wn = 64, int wk = 16,
    int wmma_m = 16, int wmma_n = 16, int wmma_k = 16
>
__device__ __forceinline__ void loadSmemC(float *smem, half *C, int M, int N) {
    // load 128 * 128
    const int bx = blockIdx.x;
    const int by = blockIdx.y;
    const int lane_id = threadIdx.x;
    const int warp_x = threadIdx.y;
    const int warp_y = threadIdx.z;
    const int tid = (warp_y << 6) + (warp_x << 5) + lane_id;

    #pragma unroll
    for (int i = 0; i < bm; ++i) {
        const int row = i;
        const int col = tid;

        // layout: [row_out, col_out, row_in, col_in] = [8, 8, 16, 16]
        const int row_o = row >> 4;
        const int col_o = col >> 4;
        const int row_i = row & 15;
        const int col_i = col & 15;
        smem[(row_o << 9) + (col_o << 8) + (row_i << 4) + col_i] = 
            static_cast<float>(C[(by * bm + row) * N + bx * bn + col]);
    }
}

template <
    int bm = 128, int bn = 128, int bk = 32, 
    int wm = 64, int wn = 64, int wk = 16,
    int wmma_m = 16, int wmma_n = 16, int wmma_k = 16
>
__device__ __forceinline__ void storeSmemC(half *C, float *smem, int M, int N) {
    // load 128 * 128
    const int bx = blockIdx.x;
    const int by = blockIdx.y;
    const int lane_id = threadIdx.x;
    const int warp_x = threadIdx.y;
    const int warp_y = threadIdx.z;
    const int tid = (warp_y << 6) + (warp_x << 5) + lane_id;

    #pragma unroll
    for (int i = 0; i < bm; ++i) {
        const int row = i;
        const int col = tid;

        // layout: [row_out, col_out, row_in, col_in] = [8, 8, 16, 16]
        const int row_o = row >> 4;
        const int col_o = col >> 4;
        const int row_i = row & 15;
        const int col_i = col & 15;
        C[(by * bm + row) * N + bx * bm + col] = 
            static_cast<half>(smem[(row_o << 9) + (col_o << 8) + (row_i << 4) + col_i]);
    }
}

template <
    int bm = 128, int bn = 128, int bk = 32, 
    int wm = 64, int wn = 64, int wk = 16,
    int wmma_m = 16, int wmma_n = 16, int wmma_k = 16
>
__device__ __forceinline__ void loadFragA(
    wmma::fragment<wmma::matrix_a, wmma_m, wmma_n, wmma_k, half, wmma::row_major> *frag, 
    half *smem, 
    int k
) {
    // load 64x16
    const int warp_y = threadIdx.z;
    #pragma unroll
    for (int i = 0; i < 4; ++i) {
        const int row = (warp_y << 6) + (i << 4);
        const int col = k * wk;
        nvcuda::wmma::load_matrix_sync(
            frag[i], 
            smem + ((row >> 4) << 9) + ((col >> 4) << 8), 
            16
        );
    }
}

template <
    int bm = 128, int bn = 128, int bk = 32, 
    int wm = 64, int wn = 64, int wk = 16,
    int wmma_m = 16, int wmma_n = 16, int wmma_k = 16
>
__device__ __forceinline__ void loadFragB(
    wmma::fragment<wmma::matrix_b, wmma_m, wmma_n, wmma_k, half, wmma::col_major> *frag, 
    half *smem, 
    int ki
) {
    // load 64x16
    int warp_x = threadIdx.y;
    for (int i = 0; i < 4; ++i) {
        const int row = (warp_x << 6) + (i << 4);
        const int col = ki * wk;
        nvcuda::wmma::load_matrix_sync(
            frag[i], 
            smem + ((row >> 4) << 9) + ((col >> 4) << 8), 
            16
        );
    }
}

template <
    int bm = 128, int bn = 128, int bk = 32, 
    int wm = 64, int wn = 64, int wk = 16,
    int wmma_m = 16, int wmma_n = 16, int wmma_k = 16
>
__device__ __forceinline__ void storeAccum(
    float *ptr, 
    wmma::fragment<wmma::accumulator, wmma_m, wmma_n, wmma_k, float> *frag
) {
    // store 64x64
    const int warp_x = threadIdx.y;
    const int warp_y = threadIdx.z;

    #pragma unroll
    for (int i = 0; i < 4; ++i) {
        #pragma unroll
        for (int j = 0; j < 4; ++j) {
            const int row = (warp_y << 6) + (i << 4);
            const int col = (warp_x << 6) + (j << 4);

            // laoyut: [8, 8, 16, 16]
            nvcuda::wmma::store_matrix_sync(
                ptr + ((row >> 4) << 9) + ((col >> 4) << 8), 
                frag[(i << 2) + j], 16, 
                nvcuda::wmma::mem_row_major
            );
        }
    }
}

template <
    int bm = 128, int bn = 128, int bk = 32, 
    int wm = 64, int wn = 64, int wk = 16,
    int wmma_m = 16, int wmma_n = 16, int wmma_k = 16
>
__device__ __forceinline__ void warpMma(
    wmma::fragment<wmma::matrix_a, wmma_m, wmma_n, wmma_k, half, wmma::row_major> *frag_a, 
    wmma::fragment<wmma::matrix_b, wmma_m, wmma_n, wmma_k, half, wmma::col_major> *frag_b, 
    wmma::fragment<wmma::accumulator, wmma_m, wmma_n, wmma_k, float> *accum,
    half *SA, half *SB,
    const int warp_iters,
    const int frags_m, const int frags_n
) {
    #pragma unroll
    for (int k = 0; k < warp_iters; ++k) {
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

template <
    int bm = 128, int bn = 128, int bk = 32, 
    int wm = 64, int wn = 64, int wk = 16,
    int wmma_m = 16, int wmma_n = 16, int wmma_k = 16
>
__device__ __forceinline__ void loadSmemAndCommit(
    half *SA, half *SB, 
    half *A, half *B, 
    const int k, 
    const int M, const int N, const int K
) {
    loadSmemA(SA, A, M, K, k);
    loadSmemB(SB, B, N, K, k);
    asm volatile("cp.async.commit_group;\n" ::);
}

/*
A is row-major
B is col-major
128 threads [x, y, z] = [32, 2, 2]
threadblock mma: 128x128x32
warp mma: 64x64x16
*/

template <
    int bm = 128, int bn = 128, int bk = 32, 
    int wm = 64, int wn = 64, int wk = 16,
    int wmma_m = 16, int wmma_n = 16, int wmma_k = 16
>
__global__ void matmul(
    half *A, half *B, half *C, 
    const int M, const int N, const int K, 
    const float alpha, const float beta
) {
    extern __shared__ char shared_storage[];
    half *SA1 = reinterpret_cast<half *>(shared_storage);
    half *SA2 = SA1 + bm * bk;
    half *SB1 = SA2 + bm * bk;
    half *SB2 = SB1 + bn * bk;
    float *SC = reinterpret_cast<float *>(shared_storage);

    const int frags_m = wm / wmma_m;
    const int frags_n = wn / wmma_n;
    wmma::fragment<wmma::matrix_a, wmma_m, wmma_n, wmma_k, half, wmma::row_major> frag_a[frags_m];
    wmma::fragment<wmma::matrix_b, wmma_m, wmma_n, wmma_k, half, wmma::col_major> frag_b[frags_n];
    wmma::fragment<wmma::accumulator, wmma_m, wmma_n, wmma_k, float> accum[frags_m * frags_n];

    for (int i = 0; i < frags_m * frags_n; ++i) {
        wmma::fill_fragment(accum[i], 0.0);
    }
    
    // prologue
    loadSmemAndCommit(SA1, SB1, A, B, 0, M, N, K);

    const int block_iters = K / bk;
    const int warp_iters = bk / wk;

    #pragma unroll
    for (int ko = 0; ko + 2 < block_iters; ko += 2) {
        loadSmemAndCommit(SA2, SB2, A, B, ko + 1, M, N, K);
        asm volatile("cp.async.wait_group %0;\n" ::"n"(1));
        __syncthreads();
        warpMma(frag_a, frag_b, accum, SA1, SB1, warp_iters, frags_m, frags_n);

        loadSmemAndCommit(SA1, SB1, A, B, ko + 2, M, N, K);
        asm volatile("cp.async.wait_group %0;\n" ::"n"(1));
        __syncthreads();
        warpMma(frag_a, frag_b, accum, SA2, SB2, warp_iters, frags_m, frags_n);
    }

    {
        int ko = (block_iters / 2 - 1) * 2;

        if (ko < block_iters) {
            warpMma(frag_a, frag_b, accum, SA1, SB1, warp_iters, frags_m, frags_n);
        }
        if (ko + 1 < block_iters) {
            warpMma(frag_a, frag_b, accum, SA2, SB2, warp_iters, frags_m, frags_n);
        }
    }

    storeAccum(SC, accum);
    __syncthreads();
    storeSmemC(C, SC, M, N);
}

template __global__ void matmul<128, 128, 32, 64, 64, 16, 16, 16, 16>(
    half *A, half *B, half *C, 
    const int M, const int N, const int K, 
    const float alpha, const float beta
);