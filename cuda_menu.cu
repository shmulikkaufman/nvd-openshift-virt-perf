/*
 * cuda_menu.cu — Interactive CUDA API Explorer
 *
 * Build:  nvcc -O2 -o cuda_menu cuda_menu.cu
 * Run:    ./cuda_menu
 *
 * Each menu item demonstrates a specific CUDA API category with the exact
 * function calls shown alongside their output, making it useful for both
 * testing GPU health and learning the CUDA runtime API.
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <cuda_runtime.h>

/* ── helpers ─────────────────────────────────────────────────────────────── */

/*
 * CHECK aborts the current menu handler on error.
 * It does NOT kill the process — the menu loop continues after the handler returns.
 */
#define CHECK(x) do {                                                    \
    cudaError_t _e = (x);                                               \
    if (_e != cudaSuccess) {                                             \
        fprintf(stderr, "\nCUDA error at %s:%d\n  %s — %s\n",          \
                __FILE__, __LINE__,                                      \
                cudaGetErrorName(_e), cudaGetErrorString(_e));          \
        return;                                                          \
    }                                                                    \
} while (0)

static void hr(void) {
    printf("─────────────────────────────────────────────────────────────────\n");
}

/* Prompt the user to select a GPU; writes the choice to *dev. Returns 0 on success. */
static int choose_gpu(int *dev) {
    int count;
    cudaGetDeviceCount(&count);
    if (count == 1) { *dev = 0; return 0; }
    printf("Select GPU (0–%d): ", count - 1);
    fflush(stdout);
    if (scanf("%d", dev) != 1 || *dev < 0 || *dev >= count) {
        printf("Invalid selection.\n");
        return -1;
    }
    return 0;
}

/* ── GPU kernels ─────────────────────────────────────────────────────────── */

/* Element-wise vector addition: c[i] = a[i] + b[i] */
__global__ void k_vadd(const float *a, const float *b, float *c, int n) {
    int i = blockDim.x * blockIdx.x + threadIdx.x;
    if (i < n) c[i] = a[i] + b[i];
}

/* In-place scalar multiply: a[i] *= s */
__global__ void k_scale(float *a, float s, int n) {
    int i = blockDim.x * blockIdx.x + threadIdx.x;
    if (i < n) a[i] *= s;
}

/* ── menu handlers ───────────────────────────────────────────────────────── */

/*
 * 1. GPU Discovery
 * Enumerate all visible GPUs and print a one-line summary for each.
 */
static void menu_discovery(void) {
    hr();
    printf("APIs: cudaGetDeviceCount  cudaGetDeviceProperties  cudaSetDevice\n");
    hr();

    int count;
    CHECK(cudaGetDeviceCount(&count));
    printf("cudaGetDeviceCount → %d GPU(s)\n\n", count);

    for (int i = 0; i < count; i++) {
        cudaDeviceProp p;
        CHECK(cudaGetDeviceProperties(&p, i));
        printf("  GPU %d : %s\n", i, p.name);
        printf("    Compute  : %d.%d\n", p.major, p.minor);
        printf("    SMs      : %d\n", p.multiProcessorCount);
        printf("    HBM      : %.1f GiB\n", p.totalGlobalMem / 1073741824.0);
        printf("    L2 cache : %.1f MiB\n", p.l2CacheSize / 1048576.0);
        printf("    Bus      : %d-bit\n", p.memoryBusWidth);
        printf("    ECC      : %s\n", p.ECCEnabled ? "on" : "off");
        printf("    PCI      : %04x:%02x:%02x\n", p.pciDomainID, p.pciBusID, p.pciDeviceID);
        printf("    Async engines : %d  (copy engine count)\n", p.asyncEngineCount);
        printf("\n");
    }
}

/*
 * 2. Full Device Properties
 * Dump every major field of cudaDeviceProp for a chosen GPU, grouped by category.
 */
static void menu_props(void) {
    hr();
    printf("APIs: cudaGetDeviceProperties (full cudaDeviceProp struct)\n");
    hr();

    int dev;
    if (choose_gpu(&dev) != 0) return;
    cudaDeviceProp p;
    CHECK(cudaGetDeviceProperties(&p, dev));

    printf("\n=== GPU %d: %s ===\n", dev, p.name);

    printf("\n[Compute]\n");
    printf("  major / minor                  : %d.%d\n", p.major, p.minor);
    printf("  multiProcessorCount            : %d\n", p.multiProcessorCount);
    printf("  maxThreadsPerMultiProcessor    : %d\n", p.maxThreadsPerMultiProcessor);
    printf("  maxThreadsPerBlock             : %d\n", p.maxThreadsPerBlock);
    printf("  maxGridSize                    : %d × %d × %d\n",
           p.maxGridSize[0], p.maxGridSize[1], p.maxGridSize[2]);
    printf("  maxThreadsDim                  : %d × %d × %d\n",
           p.maxThreadsDim[0], p.maxThreadsDim[1], p.maxThreadsDim[2]);
    printf("  warpSize                       : %d\n", p.warpSize);
    printf("  regsPerBlock                   : %d\n", p.regsPerBlock);
    printf("  regsPerMultiprocessor          : %d\n", p.regsPerMultiprocessor);
    printf("  cooperativeLaunch              : %s\n", p.cooperativeLaunch ? "yes" : "no");
    printf("  streamPrioritiesSupported      : %s\n", p.streamPrioritiesSupported ? "yes" : "no");

    printf("\n[Memory]\n");
    printf("  totalGlobalMem                 : %.3f GiB\n", p.totalGlobalMem / 1073741824.0);
    printf("  l2CacheSize                    : %.1f MiB\n", p.l2CacheSize / 1048576.0);
    printf("  sharedMemPerBlock              : %zu KiB\n", p.sharedMemPerBlock / 1024);
    printf("  sharedMemPerBlockOptin         : %zu KiB  (with opt-in large shared mem)\n",
           p.sharedMemPerBlockOptin / 1024);
    printf("  sharedMemPerMultiprocessor     : %zu KiB\n", p.sharedMemPerMultiprocessor / 1024);
    printf("  totalConstMem                  : %zu B\n", p.totalConstMem);
    printf("  memoryBusWidth                 : %d bits\n", p.memoryBusWidth);
    printf("  ECCEnabled                     : %s\n", p.ECCEnabled ? "yes" : "no");
    printf("  globalL1CacheSupported         : %s\n", p.globalL1CacheSupported ? "yes" : "no");
    printf("  localL1CacheSupported          : %s\n", p.localL1CacheSupported ? "yes" : "no");
    printf("  unifiedAddressing              : %s\n", p.unifiedAddressing ? "yes" : "no");
    printf("  managedMemory                  : %s\n", p.managedMemory ? "yes" : "no");
    printf("  concurrentManagedAccess        : %s\n", p.concurrentManagedAccess ? "yes" : "no");
    printf("  pageableMemoryAccess           : %s\n", p.pageableMemoryAccess ? "yes" : "no");
    printf("  canMapHostMemory               : %s\n", p.canMapHostMemory ? "yes" : "no");
    printf("  directManagedMemAccessFromHost : %s\n", p.directManagedMemAccessFromHost ? "yes" : "no");

    printf("\n[Execution features]\n");
    printf("  asyncEngineCount               : %d\n", p.asyncEngineCount);
    printf("  multiGpuBoardGroupID           : %d\n", p.multiGpuBoardGroupID);
    printf("  integrated                     : %s\n", p.integrated ? "yes" : "no");
    printf("  canUseHostPointerForRegisteredMem : %s\n",
           p.canUseHostPointerForRegisteredMem ? "yes" : "no");
}

/*
 * 3. Memory Info
 * Show live free/used HBM via cudaMemGetInfo plus compile-time limits from cudaDeviceProp.
 */
static void menu_meminfo(void) {
    hr();
    printf("APIs: cudaMemGetInfo  cudaGetDeviceProperties\n");
    hr();

    int dev;
    if (choose_gpu(&dev) != 0) return;
    CHECK(cudaSetDevice(dev));

    cudaDeviceProp p;
    CHECK(cudaGetDeviceProperties(&p, dev));

    size_t free_mem, total_mem;
    CHECK(cudaMemGetInfo(&free_mem, &total_mem));

    printf("\nGPU %d: %s\n\n", dev, p.name);

    printf("cudaMemGetInfo (live allocation view):\n");
    printf("  total  : %10.3f GiB  (%zu bytes)\n", total_mem / 1073741824.0, total_mem);
    printf("  free   : %10.3f GiB  (%zu bytes)\n", free_mem  / 1073741824.0, free_mem);
    printf("  used   : %10.3f GiB\n", (total_mem - free_mem) / 1073741824.0);

    printf("\ncudaDeviceProp fixed limits:\n");
    printf("  totalGlobalMem         : %.3f GiB\n", p.totalGlobalMem / 1073741824.0);
    printf("  l2CacheSize            : %.1f MiB\n", p.l2CacheSize / 1048576.0);
    printf("  totalConstMem          : %zu B\n", p.totalConstMem);
    printf("  sharedMemPerBlock      : %zu B  (%.0f KiB — default per-block shared)\n",
           p.sharedMemPerBlock, p.sharedMemPerBlock / 1024.0);
    printf("  sharedMemPerBlockOptin : %zu B  (%.0f KiB — after cudaFuncSetAttribute opt-in)\n",
           p.sharedMemPerBlockOptin, p.sharedMemPerBlockOptin / 1024.0);
    printf("  sharedMemPerMp         : %zu B  (%.0f KiB — L1 + shared bank per SM)\n",
           p.sharedMemPerMultiprocessor, p.sharedMemPerMultiprocessor / 1024.0);
    printf("  regsPerBlock           : %d  (32-bit registers)\n", p.regsPerBlock);
    printf("  memoryBusWidth         : %d bits\n", p.memoryBusWidth);
}

/*
 * 4. Driver and Runtime Versions
 * Distinguish the installed driver from the CUDA runtime linked at compile time.
 */
static void menu_versions(void) {
    hr();
    printf("APIs: cudaDriverGetVersion  cudaRuntimeGetVersion\n");
    hr();

    int dv, rv;
    CHECK(cudaDriverGetVersion(&dv));
    CHECK(cudaRuntimeGetVersion(&rv));

    printf("\ncudaDriverGetVersion  → %d  (CUDA %d.%d)\n",
           dv, dv / 1000, (dv % 1000) / 10);
    printf("cudaRuntimeGetVersion → %d  (CUDA %d.%d)\n",
           rv, rv / 1000, (rv % 1000) / 10);
    printf("\nNote: driver version >= runtime version is required.\n");
    printf("      If driver < runtime, kernel launch will fail at runtime.\n");

    int count;
    cudaGetDeviceCount(&count);
    printf("\nPer-GPU compute capability:\n");
    for (int i = 0; i < count; i++) {
        cudaDeviceProp p;
        cudaGetDeviceProperties(&p, i);
        printf("  GPU %d: %s — compute %d.%d\n", i, p.name, p.major, p.minor);
    }
}

/*
 * 5. Memory Allocation Types
 * Show the three main allocation paths: device, pinned host, and managed (unified).
 */
static void menu_alloc(void) {
    hr();
    printf("APIs: cudaMalloc  cudaMallocHost  cudaMallocManaged\n");
    printf("      cudaPointerGetAttributes\n");
    hr();

    int dev;
    if (choose_gpu(&dev) != 0) return;
    CHECK(cudaSetDevice(dev));

    const size_t SZ = 64 * 1024 * 1024;  /* 64 MiB */
    cudaDeviceProp p;
    cudaGetDeviceProperties(&p, dev);

    /* 1 — device memory (HBM) */
    float *d_ptr = NULL;
    printf("\n1. cudaMalloc — device/HBM memory (%zu MiB)\n", SZ >> 20);
    printf("   Only the GPU can access this pointer directly.\n");
    printf("   cudaMalloc(&d_ptr, %zu);\n", SZ);
    CHECK(cudaMalloc(&d_ptr, SZ));
    printf("   OK  device ptr = %p\n", (void *)d_ptr);

    cudaPointerAttributes attr;
    cudaPointerGetAttributes(&attr, d_ptr);
    printf("   cudaPointerGetAttributes: type=%d (1=device) device=%d\n",
           (int)attr.type, attr.device);

    /* 2 — pinned (page-locked) host memory */
    float *h_pin = NULL;
    printf("\n2. cudaMallocHost — page-locked (pinned) host memory (%zu MiB)\n", SZ >> 20);
    printf("   DMA-able: enables cudaMemcpyAsync without an intermediate staging buffer.\n");
    printf("   cudaMallocHost(&h_pin, %zu);\n", SZ);
    CHECK(cudaMallocHost(&h_pin, SZ));
    printf("   OK  host ptr  = %p\n", (void *)h_pin);

    cudaPointerGetAttributes(&attr, h_pin);
    printf("   cudaPointerGetAttributes: type=%d (0=host pinned) device=%d\n",
           (int)attr.type, attr.device);

    /* 3 — managed (unified) memory */
    if (p.managedMemory) {
        float *m_ptr = NULL;
        printf("\n3. cudaMallocManaged — unified/managed memory (%zu MiB)\n", SZ >> 20);
        printf("   CPU and GPU share one pointer; driver migrates pages on demand.\n");
        printf("   cudaMallocManaged(&m_ptr, %zu, cudaMemAttachGlobal);\n", SZ);
        CHECK(cudaMallocManaged(&m_ptr, SZ, cudaMemAttachGlobal));
        printf("   OK  managed ptr = %p\n", (void *)m_ptr);

        cudaPointerGetAttributes(&attr, m_ptr);
        printf("   cudaPointerGetAttributes: type=%d (2=managed)\n", (int)attr.type);

        /* Advise that this range will mostly be accessed by the GPU */
        printf("   cudaMemAdvise(m_ptr, %zu, cudaMemAdviseSetPreferredLocation, loc);\n", SZ);
        struct cudaMemLocation loc = { cudaMemLocationTypeDevice, dev };
        cudaMemAdvise(m_ptr, SZ, cudaMemAdviseSetPreferredLocation, loc);
        printf("   Hint set — driver will prefer GPU HBM on first access.\n");
        printf("   (Use cudaMemPrefetchAsync for eager migration if needed.)\n");
        cudaFree(m_ptr);
    } else {
        printf("\n3. Managed memory not supported on this GPU.\n");
    }

    cudaFree(d_ptr);
    cudaFreeHost(h_pin);
    printf("\nAll allocations freed.\n");
}

/*
 * 6. HBM Bandwidth Sweep
 * Run the vector-add kernel at increasing working-set sizes to show how measured
 * bandwidth rises once the dataset exceeds the L2 cache.
 */
static void menu_bandwidth(void) {
    hr();
    printf("APIs: cudaMalloc  cudaMemset  cudaEventRecord  cudaEventElapsedTime\n");
    hr();

    int dev;
    if (choose_gpu(&dev) != 0) return;
    CHECK(cudaSetDevice(dev));

    cudaDeviceProp p;
    cudaGetDeviceProperties(&p, dev);
    printf("\nGPU: %s  (L2 = %.0f MiB)\n\n", p.name, p.l2CacheSize / 1048576.0);

    size_t mb_sizes[] = { 1, 4, 16, 64, 128, 256, 512 };
    int nsizes = (int)(sizeof(mb_sizes) / sizeof(mb_sizes[0]));
    int REPS = 20;

    printf("  %-10s  %10s  %12s  %s\n", "Size", "Time(ms)", "BW (GB/s)", "Note");
    printf("  %-10s  %10s  %12s  %s\n", "----", "--------", "---------", "----");

    for (int s = 0; s < nsizes; s++) {
        size_t n = mb_sizes[s] * 1024 * 1024 / sizeof(float);
        float *d_a, *d_b, *d_c;
        if (cudaMalloc(&d_a, n * sizeof(float)) != cudaSuccess ||
            cudaMalloc(&d_b, n * sizeof(float)) != cudaSuccess ||
            cudaMalloc(&d_c, n * sizeof(float)) != cudaSuccess) {
            printf("  %3zu MiB   — skipped (allocation failed)\n", mb_sizes[s]);
            cudaFree(d_a); cudaFree(d_b); cudaFree(d_c);
            continue;
        }
        cudaMemset(d_a, 0, n * sizeof(float));
        cudaMemset(d_b, 0, n * sizeof(float));

        int threads = 256, blocks = (int)((n + threads - 1) / threads);
        /* warm-up */
        k_vadd<<<blocks, threads>>>(d_a, d_b, d_c, (int)n);
        cudaDeviceSynchronize();

        cudaEvent_t t0, t1;
        cudaEventCreate(&t0); cudaEventCreate(&t1);
        cudaEventRecord(t0);
        for (int r = 0; r < REPS; r++)
            k_vadd<<<blocks, threads>>>(d_a, d_b, d_c, (int)n);
        cudaEventRecord(t1);
        cudaEventSynchronize(t1);

        float ms; cudaEventElapsedTime(&ms, t0, t1); ms /= REPS;
        /* 3 arrays × n floats × 4 bytes (2 reads + 1 write) */
        double bw = (3.0 * n * sizeof(float) / 1e9) / (ms / 1000.0);

        const char *note = (mb_sizes[s] * 3 <= p.l2CacheSize / (1024*1024))
                           ? "<= L2, L2-bound"
                           : "> L2, HBM-bound";
        printf("  %-10zu  %10.3f  %12.1f  %s\n", mb_sizes[s], ms, bw, note);

        cudaEventDestroy(t0); cudaEventDestroy(t1);
        cudaFree(d_a); cudaFree(d_b); cudaFree(d_c);
    }

    printf("\nBandwidth rises once the 3-buffer working set exceeds the L2 cache.\n");
    printf("Peak HBM bandwidth is determined by: bus width × memory frequency.\n");
}

/*
 * 7. Kernel Timing with CUDA Events
 * Walk through the event API step by step, showing each call and why it matters.
 */
static void menu_timing(void) {
    hr();
    printf("APIs: cudaEventCreate  cudaEventRecord  cudaEventSynchronize\n");
    printf("      cudaEventElapsedTime  cudaEventDestroy\n");
    hr();

    int dev;
    if (choose_gpu(&dev) != 0) return;
    CHECK(cudaSetDevice(dev));

    const int N = 1 << 24;  /* 16M floats */
    float *d_a, *d_b, *d_c;
    CHECK(cudaMalloc(&d_a, N * sizeof(float)));
    CHECK(cudaMalloc(&d_b, N * sizeof(float)));
    CHECK(cudaMalloc(&d_c, N * sizeof(float)));
    cudaMemset(d_a, 0, N * sizeof(float));
    cudaMemset(d_b, 0, N * sizeof(float));

    int threads = 256, blocks = (N + threads - 1) / threads;

    /* warm-up to avoid first-launch latency in the measurement */
    k_vadd<<<blocks, threads>>>(d_a, d_b, d_c, N);
    cudaDeviceSynchronize();

    printf("\nStep-by-step:\n\n");

    cudaEvent_t t0, t1;
    printf("  cudaEventCreate(&t0);  → GPU hardware timestamp slot, zero cost\n");
    CHECK(cudaEventCreate(&t0));
    printf("  cudaEventCreate(&t1);\n\n");
    CHECK(cudaEventCreate(&t1));

    printf("  cudaEventRecord(t0, stream=0);  → insert timestamp into stream\n");
    CHECK(cudaEventRecord(t0, 0));

    k_vadd<<<blocks, threads>>>(d_a, d_b, d_c, N);
    printf("  k_vadd<<<blocks=%d, threads=%d>>>(...);\n", blocks, threads);

    CHECK(cudaEventRecord(t1, 0));
    printf("  cudaEventRecord(t1, stream=0);  → second timestamp\n\n");

    printf("  cudaEventSynchronize(t1);  → CPU blocks until GPU records t1\n");
    CHECK(cudaEventSynchronize(t1));

    float ms;
    CHECK(cudaEventElapsedTime(&ms, t0, t1));
    printf("  cudaEventElapsedTime(&ms, t0, t1);  → GPU-measured delta\n\n");

    double gb = 3.0 * N * sizeof(float) / 1e9;
    printf("  Kernel time : %.3f ms\n", ms);
    printf("  Bandwidth   : %.1f GB/s  (%.3f GB / %.4f s)\n",
           gb / (ms / 1000.0), gb, ms / 1000.0);

    printf("\n  Key points:\n");
    printf("  • Events are GPU hardware counters — no PCIe or host-side overhead.\n");
    printf("  • cudaEventSynchronize blocks only until that event, not the full stream.\n");
    printf("  • cudaDeviceSynchronize would also work but you lose the separate t0/t1 delta.\n");
    printf("  • Events in the same stream execute in order; across streams they race.\n");

    CHECK(cudaEventDestroy(t0));
    CHECK(cudaEventDestroy(t1));
    cudaFree(d_a); cudaFree(d_b); cudaFree(d_c);
}

/*
 * 8. Concurrent Streams
 * Launch the same workload across N independent streams and compare wall time
 * against the equivalent serial sequence in the default stream.
 */
static void menu_streams(void) {
    hr();
    printf("APIs: cudaStreamCreate  cudaStreamSynchronize  cudaStreamDestroy\n");
    printf("      cudaMemsetAsync  (async kernel launch with stream argument)\n");
    hr();

    int dev;
    if (choose_gpu(&dev) != 0) return;
    CHECK(cudaSetDevice(dev));

    const int NSTREAMS = 4;
    const int N = 1 << 22;  /* 4M per stream */
    int threads = 256, blocks = (N + threads - 1) / threads;

    float *d_a[NSTREAMS], *d_b[NSTREAMS], *d_c[NSTREAMS];
    cudaStream_t streams[NSTREAMS];

    for (int s = 0; s < NSTREAMS; s++) {
        CHECK(cudaStreamCreate(&streams[s]));
        CHECK(cudaMalloc(&d_a[s], N * sizeof(float)));
        CHECK(cudaMalloc(&d_b[s], N * sizeof(float)));
        CHECK(cudaMalloc(&d_c[s], N * sizeof(float)));
        cudaMemsetAsync(d_a[s], 0, N * sizeof(float), streams[s]);
        cudaMemsetAsync(d_b[s], 0, N * sizeof(float), streams[s]);
    }
    /* sync before timing */
    for (int s = 0; s < NSTREAMS; s++) cudaStreamSynchronize(streams[s]);

    cudaEvent_t t0, t1;
    CHECK(cudaEventCreate(&t0));
    CHECK(cudaEventCreate(&t1));

    /* --- concurrent (multi-stream) --- */
    printf("\nLaunching %d kernels in %d separate streams (GPU may overlap them):\n",
           NSTREAMS, NSTREAMS);
    CHECK(cudaEventRecord(t0, streams[0]));
    for (int s = 0; s < NSTREAMS; s++) {
        printf("  k_vadd<<<...>>> in stream[%d] (handle=%p)\n", s, (void *)streams[s]);
        k_vadd<<<blocks, threads, 0, streams[s]>>>(d_a[s], d_b[s], d_c[s], N);
    }
    CHECK(cudaEventRecord(t1, streams[NSTREAMS - 1]));
    for (int s = 0; s < NSTREAMS; s++) cudaStreamSynchronize(streams[s]);

    float ms_par;
    CHECK(cudaEventElapsedTime(&ms_par, t0, t1));

    /* --- serial (default stream) --- */
    printf("\nSame %d kernels launched serially in the default stream:\n", NSTREAMS);
    CHECK(cudaEventRecord(t0, 0));
    for (int s = 0; s < NSTREAMS; s++)
        k_vadd<<<blocks, threads>>>(d_a[s], d_b[s], d_c[s], N);
    CHECK(cudaEventRecord(t1, 0));
    CHECK(cudaEventSynchronize(t1));

    float ms_ser;
    CHECK(cudaEventElapsedTime(&ms_ser, t0, t1));

    printf("\n  Multi-stream wall time : %.3f ms\n", ms_par);
    printf("  Serial wall time       : %.3f ms\n", ms_ser);
    printf("  Ratio                  : %.2fx\n", ms_ser / ms_par);

    printf("\n  Note: for large kernels that saturate all SMs, concurrency gives no speedup.\n");
    printf("  Streams are most valuable when overlapping H2D transfer, kernel, and D2H:\n");
    printf("    stream 0: [H2D chunk 0][kernel 0][D2H chunk 0]\n");
    printf("    stream 1:              [H2D chunk 1][kernel 1][D2H chunk 1]\n");
    printf("    stream 2:                           [H2D chunk 2][kernel 2]...\n");

    for (int s = 0; s < NSTREAMS; s++) {
        cudaFree(d_a[s]); cudaFree(d_b[s]); cudaFree(d_c[s]);
        cudaStreamDestroy(streams[s]);
    }
    cudaEventDestroy(t0); cudaEventDestroy(t1);
}

/*
 * 9. Peer Access & NVLink Topology
 * Query which GPU pairs support direct peer access and inspect NVLink attributes.
 * On H100 SXM5 with NVSwitches, PerformanceRank=0 and NativeAtomics=yes.
 */
static void menu_peer(void) {
    hr();
    printf("APIs: cudaDeviceCanAccessPeer  cudaDeviceGetP2PAttribute\n");
    hr();

    int count;
    CHECK(cudaGetDeviceCount(&count));

    if (count < 2) {
        printf("Only 1 GPU visible to this process.\n");
        printf("Peer access requires at least 2 GPUs passed to the VM.\n");
        printf("Current VM spec has 1 GPU; add more GPUs to test NVLink topology.\n");
        return;
    }

    printf("\nPeer-access matrix (%d GPUs):\n\n", count);
    printf("       ");
    for (int j = 0; j < count; j++) printf("  GPU%d ", j);
    printf("\n");
    for (int i = 0; i < count; i++) {
        printf("  GPU%d ", i);
        for (int j = 0; j < count; j++) {
            if (i == j) { printf("   —   "); continue; }
            int can; cudaDeviceCanAccessPeer(&can, i, j);
            printf("  %-4s ", can ? "yes" : "no");
        }
        printf("\n");
    }

    printf("\nP2P attributes (connected pairs only):\n");
    for (int i = 0; i < count; i++) {
        for (int j = i + 1; j < count; j++) {
            int can; cudaDeviceCanAccessPeer(&can, i, j);
            if (!can) continue;
            int perf, atomic, access, arr;
            cudaDeviceGetP2PAttribute(&perf,   cudaDevP2PAttrPerformanceRank,         i, j);
            cudaDeviceGetP2PAttribute(&atomic, cudaDevP2PAttrNativeAtomicSupported,   i, j);
            cudaDeviceGetP2PAttribute(&access, cudaDevP2PAttrAccessSupported,         i, j);
            cudaDeviceGetP2PAttribute(&arr,    cudaDevP2PAttrCudaArrayAccessSupported, i, j);
            printf("\n  GPU %d ↔ GPU %d:\n", i, j);
            printf("    PerformanceRank          : %d  (0=NVLink/NVSwitch, higher=PCIe)\n", perf);
            printf("    NativeAtomicSupported    : %s\n", atomic ? "yes" : "no");
            printf("    AccessSupported          : %s\n", access ? "yes" : "no");
            printf("    CudaArrayAccessSupported : %s\n", arr    ? "yes" : "no");
        }
    }

    printf("\n  H100 SXM5 with NVSwitch: expect PerformanceRank=0, NativeAtomics=yes.\n");
    printf("  H100 PCIe without NVSwitch: expect PerformanceRank>0 or no peer access.\n");
}

/*
 * 10. P2P Memory Copy Bandwidth
 * Measure unidirectional copy bandwidth between two GPUs using cudaMemcpyPeerAsync.
 */
static void menu_p2pbw(void) {
    hr();
    printf("APIs: cudaDeviceEnablePeerAccess  cudaMemcpyPeerAsync\n");
    hr();

    int count;
    CHECK(cudaGetDeviceCount(&count));
    if (count < 2) {
        printf("Only 1 GPU visible — P2P bandwidth test needs at least 2 GPUs.\n");
        return;
    }

    int src, dst;
    printf("Source GPU (0–%d): ", count - 1);
    if (scanf("%d", &src) != 1 || src < 0 || src >= count) { printf("Invalid.\n"); return; }
    printf("Dest   GPU (0–%d): ", count - 1);
    if (scanf("%d", &dst) != 1 || dst < 0 || dst >= count || dst == src) { printf("Invalid.\n"); return; }

    int can; cudaDeviceCanAccessPeer(&can, src, dst);
    printf("\ncudaDeviceCanAccessPeer(%d→%d) = %s\n", src, dst, can ? "yes" : "no");
    if (!can) {
        printf("Direct peer access not available — transfer will route through host memory.\n");
    } else {
        cudaSetDevice(src); cudaDeviceEnablePeerAccess(dst, 0);
        cudaSetDevice(dst); cudaDeviceEnablePeerAccess(src, 0);
        printf("Peer access enabled on both devices.\n");
    }

    const size_t SZ = 512UL * 1024 * 1024;  /* 512 MiB */
    float *d_src, *d_dst;
    CHECK(cudaSetDevice(src)); CHECK(cudaMalloc(&d_src, SZ));
    CHECK(cudaSetDevice(dst)); CHECK(cudaMalloc(&d_dst, SZ));
    cudaSetDevice(src);        cudaMemset(d_src, 1, SZ);

    cudaStream_t stream;
    cudaSetDevice(src);
    CHECK(cudaStreamCreate(&stream));

    /* warm-up */
    cudaMemcpyPeerAsync(d_dst, dst, d_src, src, SZ, stream);
    cudaStreamSynchronize(stream);

    cudaEvent_t t0, t1;
    CHECK(cudaEventCreate(&t0)); CHECK(cudaEventCreate(&t1));

    int REPS = 5;
    cudaEventRecord(t0, stream);
    for (int r = 0; r < REPS; r++)
        cudaMemcpyPeerAsync(d_dst, dst, d_src, src, SZ, stream);
    cudaEventRecord(t1, stream);
    cudaStreamSynchronize(stream);

    float ms; cudaEventElapsedTime(&ms, t0, t1); ms /= REPS;
    double bw = (SZ / 1e9) / (ms / 1000.0);

    printf("\ncudaMemcpyPeerAsync GPU%d → GPU%d\n", src, dst);
    printf("  Transfer size : %.0f MiB\n", SZ / 1048576.0);
    printf("  Avg time      : %.3f ms\n", ms);
    printf("  Bandwidth     : %.1f GB/s\n", bw);
    printf("\n  H100 SXM5 NVLink bandwidth peak: ~900 GB/s bidirectional via NVSwitch.\n");

    cudaFree(d_src); cudaFree(d_dst);
    cudaStreamDestroy(stream);
    cudaEventDestroy(t0); cudaEventDestroy(t1);
}

/*
 * 11. Occupancy Calculator
 * Show active blocks and theoretical occupancy for different block sizes.
 * Use cudaOccupancyMaxPotentialBlockSize to find the compiler-recommended optimum.
 */
static void menu_occupancy(void) {
    hr();
    printf("APIs: cudaOccupancyMaxActiveBlocksPerMultiprocessor\n");
    printf("      cudaOccupancyMaxPotentialBlockSize\n");
    hr();

    int dev;
    if (choose_gpu(&dev) != 0) return;
    CHECK(cudaSetDevice(dev));

    cudaDeviceProp p;
    cudaGetDeviceProperties(&p, dev);

    printf("\nGPU: %s\n", p.name);
    printf("maxThreadsPerMultiProcessor = %d\n\n", p.maxThreadsPerMultiProcessor);
    printf("Kernel: k_vadd (simple, register-light, no dynamic shared memory)\n\n");

    printf("  %-12s  %-14s  %-14s  %-10s\n",
           "Block size", "Active blks/SM", "Active thds/SM", "Occupancy");
    printf("  %-12s  %-14s  %-14s  %-10s\n",
           "----------", "--------------", "--------------", "---------");

    int block_sizes[] = { 32, 64, 128, 256, 512, 1024 };
    for (int b = 0; b < (int)(sizeof(block_sizes)/sizeof(block_sizes[0])); b++) {
        int active_blocks;
        cudaOccupancyMaxActiveBlocksPerMultiprocessor(
            &active_blocks, k_vadd, block_sizes[b], /*dynSharedMem=*/0);
        int active_threads = active_blocks * block_sizes[b];
        float occ = (float)active_threads / (float)p.maxThreadsPerMultiProcessor;
        printf("  %-12d  %-14d  %-14d  %.1f%%\n",
               block_sizes[b], active_blocks, active_threads, occ * 100.0f);
    }

    int min_grid, best_block;
    cudaOccupancyMaxPotentialBlockSize(&min_grid, &best_block, k_vadd, 0, 0);
    printf("\ncudaOccupancyMaxPotentialBlockSize:\n");
    printf("  Recommended block size : %d\n", best_block);
    printf("  Minimum grid size      : %d  (to fully saturate all %d SMs)\n",
           min_grid, p.multiProcessorCount);
    printf("\n  Occupancy is the ratio of active warps to the SM maximum.\n");
    printf("  Higher occupancy hides memory latency by keeping the warp scheduler busy.\n");
    printf("  100%% occupancy is not always fastest — register pressure and shared memory\n");
    printf("  limits may make a smaller block with more registers per thread faster.\n");
}

/*
 * 12. Async Memcpy Pipeline
 * Split work into chunks and overlap H2D transfer, kernel execution, and D2H
 * transfer across multiple streams to hide PCIe latency behind compute.
 */
static void menu_async(void) {
    hr();
    printf("APIs: cudaMallocHost  cudaMemcpyAsync (H2D and D2H)  cudaStreamCreate\n");
    hr();

    int dev;
    if (choose_gpu(&dev) != 0) return;
    CHECK(cudaSetDevice(dev));

    const int N_TOTAL = 1 << 24;  /* 16M elements total */
    const int NCHUNKS = 4;
    const int CHUNK   = N_TOTAL / NCHUNKS;

    /* pinned host memory required for async transfers */
    float *h_a, *h_b, *h_c;
    CHECK(cudaMallocHost(&h_a, N_TOTAL * sizeof(float)));
    CHECK(cudaMallocHost(&h_b, N_TOTAL * sizeof(float)));
    CHECK(cudaMallocHost(&h_c, N_TOTAL * sizeof(float)));
    for (int i = 0; i < N_TOTAL; i++) { h_a[i] = 1.0f; h_b[i] = 2.0f; }

    float *d_a, *d_b, *d_c;
    CHECK(cudaMalloc(&d_a, N_TOTAL * sizeof(float)));
    CHECK(cudaMalloc(&d_b, N_TOTAL * sizeof(float)));
    CHECK(cudaMalloc(&d_c, N_TOTAL * sizeof(float)));

    cudaStream_t streams[NCHUNKS];
    for (int s = 0; s < NCHUNKS; s++) CHECK(cudaStreamCreate(&streams[s]));

    int threads = 256;

    printf("\nPipeline: %d chunks × %d elements = %dM total\n\n",
           NCHUNKS, CHUNK, N_TOTAL >> 20);
    printf("  For each chunk i (in its own stream):\n");
    printf("    cudaMemcpyAsync(d_a+off, h_a+off, ..., H2D, stream[i]);\n");
    printf("    cudaMemcpyAsync(d_b+off, h_b+off, ..., H2D, stream[i]);\n");
    printf("    k_vadd<<<...>>>(d_a+off, d_b+off, d_c+off, ..., stream[i]);\n");
    printf("    cudaMemcpyAsync(h_c+off, d_c+off, ..., D2H, stream[i]);\n");
    printf("\n  GPU DMA engine runs transfers while SMs run the previous chunk's kernel.\n\n");

    cudaEvent_t t0, t1;
    CHECK(cudaEventCreate(&t0)); CHECK(cudaEventCreate(&t1));
    CHECK(cudaEventRecord(t0, streams[0]));

    for (int s = 0; s < NCHUNKS; s++) {
        int off    = s * CHUNK;
        int blocks = (CHUNK + threads - 1) / threads;
        cudaMemcpyAsync(d_a + off, h_a + off, CHUNK * sizeof(float),
                        cudaMemcpyHostToDevice, streams[s]);
        cudaMemcpyAsync(d_b + off, h_b + off, CHUNK * sizeof(float),
                        cudaMemcpyHostToDevice, streams[s]);
        k_vadd<<<blocks, threads, 0, streams[s]>>>(d_a+off, d_b+off, d_c+off, CHUNK);
        cudaMemcpyAsync(h_c + off, d_c + off, CHUNK * sizeof(float),
                        cudaMemcpyDeviceToHost, streams[s]);
    }

    CHECK(cudaEventRecord(t1, streams[NCHUNKS - 1]));
    for (int s = 0; s < NCHUNKS; s++) cudaStreamSynchronize(streams[s]);

    float ms; CHECK(cudaEventElapsedTime(&ms, t0, t1));

    int errors = 0;
    for (int i = 0; i < N_TOTAL; i++) if (h_c[i] != 3.0f) errors++;

    printf("  Pipeline time : %.3f ms  (%dM element result)\n", ms, N_TOTAL >> 20);
    printf("  Errors        : %d — %s\n", errors, errors == 0 ? "PASS" : "FAIL");
    printf("\n  Note: inside a VM, PCIe bandwidth is the bottleneck this hides.\n");
    printf("  On bare metal, async pipelines can approach copy-engine peak (~50 GB/s).\n");

    for (int s = 0; s < NCHUNKS; s++) cudaStreamDestroy(streams[s]);
    cudaFreeHost(h_a); cudaFreeHost(h_b); cudaFreeHost(h_c);
    cudaFree(d_a); cudaFree(d_b); cudaFree(d_c);
    cudaEventDestroy(t0); cudaEventDestroy(t1);
}

/*
 * 13. CUDA Graphs — Capture and Replay
 * Record a sequence of kernel launches as a graph, instantiate it once, then
 * re-launch it many times with minimal CPU overhead.
 */
static void menu_graphs(void) {
    hr();
    printf("APIs: cudaStreamBeginCapture  cudaStreamEndCapture\n");
    printf("      cudaGraphInstantiate    cudaGraphLaunch\n");
    printf("      cudaGraphGetNodes      cudaGraphExecDestroy  cudaGraphDestroy\n");
    hr();

    int dev;
    if (choose_gpu(&dev) != 0) return;
    CHECK(cudaSetDevice(dev));

    const int N = 1 << 22;  /* 4M elements */
    float *d_a, *d_b, *d_c;
    CHECK(cudaMalloc(&d_a, N * sizeof(float)));
    CHECK(cudaMalloc(&d_b, N * sizeof(float)));
    CHECK(cudaMalloc(&d_c, N * sizeof(float)));
    cudaMemset(d_a, 0, N * sizeof(float));
    cudaMemset(d_b, 0, N * sizeof(float));

    int threads = 256, blocks = (N + threads - 1) / threads;

    cudaStream_t stream;
    CHECK(cudaStreamCreate(&stream));

    /* ---- Phase 1: capture ---- */
    printf("\nPhase 1: capture a 3-kernel sequence into a graph.\n");
    printf("  cudaStreamBeginCapture(stream, cudaStreamCaptureModeGlobal);\n");
    printf("  Kernels launched here are NOT executed — they become graph nodes.\n\n");

    cudaGraph_t graph;
    CHECK(cudaStreamBeginCapture(stream, cudaStreamCaptureModeGlobal));
    k_vadd <<<blocks, threads, 0, stream>>>(d_a, d_b, d_c, N);   /* node 1 */
    k_scale<<<blocks, threads, 0, stream>>>(d_c, 2.0f, N);        /* node 2 → depends on 1 */
    k_vadd <<<blocks, threads, 0, stream>>>(d_c, d_a, d_b, N);   /* node 3 → depends on 2 */
    CHECK(cudaStreamEndCapture(stream, &graph));

    size_t num_nodes = 0;
    cudaGraphGetNodes(graph, NULL, &num_nodes);
    printf("  cudaStreamEndCapture → graph captured with %zu nodes.\n\n", num_nodes);

    /* ---- Phase 2: instantiate (compile) ---- */
    printf("Phase 2: instantiate the graph into an executable.\n");
    printf("  cudaGraphInstantiate(&exec, graph, NULL, NULL, 0);\n\n");
    cudaGraphExec_t exec;
    CHECK(cudaGraphInstantiate(&exec, graph, NULL, NULL, 0));

    /* ---- Phase 3: benchmark graph vs. stream ---- */
    printf("Phase 3: launch 200 times and compare against direct stream launches.\n\n");

    cudaEvent_t t0, t1;
    CHECK(cudaEventCreate(&t0)); CHECK(cudaEventCreate(&t1));
    const int REPS = 200;

    /* warm-up */
    cudaGraphLaunch(exec, stream);
    cudaStreamSynchronize(stream);

    /* graph timing */
    cudaEventRecord(t0, stream);
    for (int r = 0; r < REPS; r++)
        cudaGraphLaunch(exec, stream);
    cudaEventRecord(t1, stream);
    cudaEventSynchronize(t1);
    float ms_graph; cudaEventElapsedTime(&ms_graph, t0, t1); ms_graph /= REPS;

    /* stream timing */
    cudaEventRecord(t0, stream);
    for (int r = 0; r < REPS; r++) {
        k_vadd <<<blocks, threads, 0, stream>>>(d_a, d_b, d_c, N);
        k_scale<<<blocks, threads, 0, stream>>>(d_c, 2.0f, N);
        k_vadd <<<blocks, threads, 0, stream>>>(d_c, d_a, d_b, N);
    }
    cudaEventRecord(t1, stream);
    cudaEventSynchronize(t1);
    float ms_stream; cudaEventElapsedTime(&ms_stream, t0, t1); ms_stream /= REPS;

    printf("  %d repetitions of 3-kernel sequence:\n", REPS);
    printf("    cudaGraphLaunch : %.4f ms/iter\n", ms_graph);
    printf("    Stream launch   : %.4f ms/iter\n", ms_stream);
    printf("    Overhead saved  : %.4f ms/iter  (%.2fx)\n",
           ms_stream - ms_graph, ms_stream / ms_graph);
    printf("\n  Why it's faster: graph launch is a single CPU→GPU submission.\n");
    printf("  Stream launch submits one command per kernel — CPU overhead adds up\n");
    printf("  when kernels are short (inference steps, simulation ticks, etc.).\n");

    cudaGraphExecDestroy(exec);
    cudaGraphDestroy(graph);
    cudaStreamDestroy(stream);
    cudaFree(d_a); cudaFree(d_b); cudaFree(d_c);
    cudaEventDestroy(t0); cudaEventDestroy(t1);
}

/*
 * 14. Error Handling
 * Walk through how CUDA surfaces errors: synchronous return codes, sticky last-error,
 * the difference between Peek and Get, and a table of common error codes.
 */
static void menu_errors(void) {
    hr();
    printf("APIs: cudaGetLastError  cudaPeekAtLastError\n");
    printf("      cudaGetErrorString  cudaGetErrorName\n");
    hr();

    printf("\n1. Successful call:\n");
    int count;
    cudaError_t err = cudaGetDeviceCount(&count);
    printf("   cudaGetDeviceCount(&count)  →  %s (%d)\n",
           cudaGetErrorName(err), (int)err);

    printf("\n2. Invalid device (out of range):\n");
    err = cudaSetDevice(9999);
    printf("   cudaSetDevice(9999)\n");
    printf("     cudaGetErrorName   → %s\n", cudaGetErrorName(err));
    printf("     cudaGetErrorString → %s\n", cudaGetErrorString(err));
    cudaGetLastError();  /* clear the sticky error */

    printf("\n3. Allocation beyond GPU memory (10 TiB):\n");
    float *p = NULL;
    err = cudaMalloc((void **)&p, 10ULL * 1024 * 1024 * 1024 * 1024);
    printf("   cudaMalloc(10TiB)  →  %s\n", cudaGetErrorName(err));
    cudaGetLastError();

    printf("\n4. cudaPeekAtLastError vs cudaGetLastError:\n");
    printf("   Both return the sticky last error, but only GetLastError clears it.\n\n");
    cudaSetDevice(9998);               /* seed a sticky error */
    printf("   After cudaSetDevice(9998):\n");
    err = cudaPeekAtLastError();
    printf("     cudaPeekAtLastError()  → %s  (NOT cleared)\n", cudaGetErrorName(err));
    err = cudaPeekAtLastError();
    printf("     cudaPeekAtLastError()  → %s  (still there)\n", cudaGetErrorName(err));
    err = cudaGetLastError();
    printf("     cudaGetLastError()     → %s  (cleared now)\n", cudaGetErrorName(err));
    err = cudaGetLastError();
    printf("     cudaGetLastError()     → %s  (clean)\n", cudaGetErrorName(err));
    cudaSetDevice(0);                  /* back to a valid device */

    printf("\n5. Selected error codes:\n");
    struct { cudaError_t code; const char *note; } table[] = {
        { cudaSuccess,                   "all good" },
        { cudaErrorInvalidValue,         "bad argument (NULL ptr, out-of-range enum)" },
        { cudaErrorMemoryAllocation,     "cudaMalloc/cudaMallocHost OOM" },
        { cudaErrorInvalidDevice,        "cudaSetDevice with bad index" },
        { cudaErrorInitializationError,  "driver not initialized, or multiple-init race" },
        { cudaErrorNotReady,             "cudaEventQuery/cudaStreamQuery — op still running" },
        { cudaErrorSystemNotReady,       "Fabric Manager not running (H100 SXM5 needs it)" },
        { cudaErrorLaunchFailure,        "kernel crashed (segfault, stack overflow, etc.)" },
        { cudaErrorIllegalAddress,       "kernel dereferenced a bad pointer" },
        { cudaErrorInsufficientDriver,   "installed driver too old for this CUDA runtime" },
    };
    for (int i = 0; i < (int)(sizeof(table)/sizeof(table[0])); i++) {
        printf("    %3d  %-32s  %s\n",
               (int)table[i].code,
               cudaGetErrorName(table[i].code),
               table[i].note);
    }

    printf("\n  Best practice: every CUDA call site should check the return value.\n");
    printf("  After any kernel launch, call cudaGetLastError() to catch launch errors.\n");
    printf("  Use cudaPeekAtLastError() in asserts when you don't want to clear state.\n");
}

/* ── main menu loop ──────────────────────────────────────────────────────── */

typedef struct { int id; const char *label; void (*fn)(void); } MenuItem;

static const MenuItem MENU[] = {
    {  1, "GPU discovery & basic info",          menu_discovery },
    {  2, "Full device properties",               menu_props     },
    {  3, "Memory info & limits",                 menu_meminfo   },
    {  4, "Driver & runtime versions",            menu_versions  },
    {  5, "Memory allocation types",              menu_alloc     },
    {  6, "HBM bandwidth sweep",                  menu_bandwidth },
    {  7, "Kernel timing with CUDA events",       menu_timing    },
    {  8, "Concurrent streams",                   menu_streams   },
    {  9, "Peer access & NVLink topology",        menu_peer      },
    { 10, "P2P copy bandwidth",                   menu_p2pbw     },
    { 11, "Kernel occupancy calculator",          menu_occupancy },
    { 12, "Async memcpy pipeline",                menu_async     },
    { 13, "CUDA graphs — capture & replay",       menu_graphs    },
    { 14, "Error handling",                       menu_errors    },
};
#define NMENU ((int)(sizeof(MENU)/sizeof(MENU[0])))

static void print_menu(int gpu_count) {
    printf("\n┌─────────────────────────────────────────────────────────┐\n");
    printf("│  CUDA API Explorer  (%d GPU%s)                           │\n",
           gpu_count, gpu_count == 1 ? " " : "s");
    printf("├─────────────────────────────────────────────────────────┤\n");
    for (int i = 0; i < NMENU; i++)
        printf("│  %2d. %-52s│\n", MENU[i].id, MENU[i].label);
    printf("├─────────────────────────────────────────────────────────┤\n");
    printf("│   0. Exit                                               │\n");
    printf("└─────────────────────────────────────────────────────────┘\n");
    printf("Choice: ");
    fflush(stdout);
}

int main(void) {
    int count;
    cudaError_t init = cudaGetDeviceCount(&count);
    if (init != cudaSuccess || count == 0) {
        fprintf(stderr, "No CUDA GPUs available: %s\n", cudaGetErrorString(init));
        return 1;
    }

    printf("CUDA API Explorer  —  %d GPU(s) visible\n", count);
    printf("Build: nvcc -O2 -o cuda_menu cuda_menu.cu\n");

    int choice;
    for (;;) {
        print_menu(count);
        if (scanf("%d", &choice) != 1) {
            /* flush bad input */
            int c; while ((c = getchar()) != '\n' && c != EOF);
            continue;
        }
        /* drain the newline scanf left behind */
        int c; while ((c = getchar()) != '\n' && c != EOF);

        if (choice == 0) { printf("Goodbye.\n"); return 0; }

        int found = 0;
        for (int i = 0; i < NMENU; i++) {
            if (MENU[i].id == choice) {
                printf("\n");
                MENU[i].fn();
                found = 1;
                break;
            }
        }
        if (!found) printf("Unknown option — enter 0–%d.\n", NMENU);

        printf("\n[Press Enter to return to menu]");
        fflush(stdout);
        while ((c = getchar()) != '\n' && c != EOF);
    }
}
