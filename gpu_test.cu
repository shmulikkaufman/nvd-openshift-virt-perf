#include <stdio.h>
#include <cuda_runtime.h>

#define N (1 << 24)   // 16M elements
#define THREADS 256

__global__ void vector_add(const float *a, const float *b, float *c, int n) {
    int i = blockDim.x * blockIdx.x + threadIdx.x;
    if (i < n) c[i] = a[i] + b[i];
}

static void check(cudaError_t err, const char *file, int line) {
    if (err != cudaSuccess) {
        fprintf(stderr, "CUDA error %s:%d: %s\n", file, line, cudaGetErrorString(err));
        exit(1);
    }
}
#define CHECK(x) check((x), __FILE__, __LINE__)

static void print_device_info(int dev) {
    cudaDeviceProp p;
    CHECK(cudaGetDeviceProperties(&p, dev));

    size_t free_mem, total_mem;
    CHECK(cudaMemGetInfo(&free_mem, &total_mem));

    printf("=== GPU %d: %s ===\n", dev, p.name);
    printf("  Compute capability : %d.%d\n", p.major, p.minor);
    printf("  SMs                : %d\n", p.multiProcessorCount);
    printf("  Memory (GiB)       : %.1f total, %.1f free\n",
           total_mem / 1073741824.0, free_mem / 1073741824.0);
    printf("  ECC enabled        : %s\n", p.ECCEnabled ? "yes" : "no");
    printf("  Peer access        : ");
    int count;
    cudaGetDeviceCount(&count);
    int any = 0;
    for (int i = 0; i < count; i++) {
        if (i == dev) continue;
        int can;
        cudaDeviceCanAccessPeer(&can, dev, i);
        if (can) { printf("%d ", i); any = 1; }
    }
    if (!any) printf("none");
    printf("\n");
}

int main(void) {
    int count;
    CHECK(cudaGetDeviceCount(&count));
    printf("Found %d GPU(s)\n\n", count);
    for (int i = 0; i < count; i++)
        print_device_info(i);

    printf("\n=== Vector addition: %dM floats ===\n", N >> 20);

    float *h_a = (float *)malloc(N * sizeof(float));
    float *h_b = (float *)malloc(N * sizeof(float));
    float *h_c = (float *)malloc(N * sizeof(float));
    for (int i = 0; i < N; i++) { h_a[i] = 1.0f; h_b[i] = 2.0f; }

    float *d_a, *d_b, *d_c;
    CHECK(cudaMalloc(&d_a, N * sizeof(float)));
    CHECK(cudaMalloc(&d_b, N * sizeof(float)));
    CHECK(cudaMalloc(&d_c, N * sizeof(float)));

    cudaEvent_t t0, t1;
    CHECK(cudaEventCreate(&t0));
    CHECK(cudaEventCreate(&t1));

    CHECK(cudaMemcpy(d_a, h_a, N * sizeof(float), cudaMemcpyHostToDevice));
    CHECK(cudaMemcpy(d_b, h_b, N * sizeof(float), cudaMemcpyHostToDevice));

    int blocks = (N + THREADS - 1) / THREADS;

    CHECK(cudaEventRecord(t0));
    vector_add<<<blocks, THREADS>>>(d_a, d_b, d_c, N);
    CHECK(cudaEventRecord(t1));
    CHECK(cudaEventSynchronize(t1));
    CHECK(cudaGetLastError());

    float ms;
    CHECK(cudaEventElapsedTime(&ms, t0, t1));
    double gb = 3.0 * N * sizeof(float) / 1e9;   // 2 reads + 1 write
    printf("  Kernel time  : %.3f ms\n", ms);
    printf("  Bandwidth    : %.1f GB/s\n", gb / (ms / 1000.0));

    CHECK(cudaMemcpy(h_c, d_c, N * sizeof(float), cudaMemcpyDeviceToHost));

    int errors = 0;
    for (int i = 0; i < N; i++)
        if (h_c[i] != 3.0f) errors++;
    printf("  Errors       : %d\n", errors);
    printf("  Result       : %s\n\n", errors == 0 ? "PASS" : "FAIL");

    cudaFree(d_a); cudaFree(d_b); cudaFree(d_c);
    free(h_a); free(h_b); free(h_c);
    cudaEventDestroy(t0); cudaEventDestroy(t1);
    return errors != 0;
}
