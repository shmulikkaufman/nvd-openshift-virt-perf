#!/bin/bash
# GPUDirect RDMA bandwidth test — single node loopback
#
# Runs server and client on the same VM using two different GPUs.
# Server listens on GPU 0, client connects to localhost using GPU 1.
# Tests: GPU mem -> RDMA NIC -> loopback -> RDMA NIC -> GPU mem
#
# Prerequisites inside VM:
#   - SR-IOV VF interface present (mlx5_0 visible in /dev/infiniband/)
#   - nvidia-peermem loaded (modprobe nvidia-peermem)
#   - perftest installed (apt install perftest)
#
# Usage: ./gdr-singlenode.sh [rdma-device] [server-gpu] [client-gpu]
#   ./gdr-singlenode.sh mlx5_0 0 1

RDMA_DEV=${1:-mlx5_0}
SERVER_GPU=${2:-0}
CLIENT_GPU=${3:-1}
SIZE=$((4*1024*1024*1024))   # 4 GiB
DURATION=30                  # seconds

echo "=== GPUDirect RDMA Loopback — Single Node ==="
echo "  RDMA device : $RDMA_DEV"
echo "  Server GPU  : $SERVER_GPU"
echo "  Client GPU  : $CLIENT_GPU"
echo "  Message size: $SIZE bytes"
echo ""

# Verify prerequisites
if ! ls /dev/infiniband/uverbs* &>/dev/null; then
  echo "ERROR: No RDMA devices found. SR-IOV VF not attached to VM."
  exit 1
fi
if ! lsmod | grep -q nvidia_peermem; then
  echo "ERROR: nvidia-peermem not loaded. Run: modprobe nvidia-peermem"
  exit 1
fi

# Start server in background
echo "Starting server (GPU $SERVER_GPU)..."
ib_write_bw \
  -d "$RDMA_DEV" \
  --use_cuda="$SERVER_GPU" \
  -s "$SIZE" \
  -D "$DURATION" \
  --report_gbits \
  -R &
SERVER_PID=$!

sleep 2

# Run client
echo "Starting client (GPU $CLIENT_GPU)..."
ib_write_bw \
  -d "$RDMA_DEV" \
  --use_cuda="$CLIENT_GPU" \
  -s "$SIZE" \
  -D "$DURATION" \
  --report_gbits \
  -R \
  127.0.0.1

wait $SERVER_PID
