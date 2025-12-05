# Vast.ai Vanity Address Mining Setup

Mining for CREATE3 vanity addresses using [createXcrunch](https://github.com/HrikB/createXcrunch).

## Deployer Address
```
0xbadfaceB351045374d7fd1d3915e62501BA9916C
```

## Full Setup (paste entire block)

```bash
# Update and install dependencies
sudo apt update && sudo apt install -y build-essential nvidia-cuda-toolkit ocl-icd-opencl-dev

# Disable PoCL so NVIDIA becomes platform 0
sudo mv /etc/OpenCL/vendors/pocl.icd /etc/OpenCL/vendors/pocl.icd.disabled

# Install Rust
curl https://sh.rustup.rs -sSf | sh -s -- -y
source ~/.cargo/env

# Clone and build
git clone https://github.com/HrikB/createXcrunch.git
cd createXcrunch
cargo build --release

# Verify GPU is detected
echo "=== GPU Check ==="
nvidia-smi
echo "=== OpenCL Platforms ==="
clinfo -l
```

## Important: Crosschain Flag

**`--crosschain 0`** = Same contract address on ALL chains (recommended)
**`--crosschain 1`** = Different address per chain (includes chainid in salt guard)

For protocols deploying across multiple chains, use `--crosschain 0` to get identical addresses everywhere.

## Run Mining (single GPU)

```bash
./target/release/createxcrunch create3 \
  --caller 0xbadfaceB351045374d7fd1d3915e62501BA9916C \
  --crosschain 0 \
  --leading 5 \
  --gpu-device-id 0
```

## Run Mining (dual GPU with nohup)

```bash
cd /workspace/createXcrunch

nohup ./target/release/createxcrunch create3 \
  --caller 0xbadfaceB351045374d7fd1d3915e62501BA9916C \
  --crosschain 0 \
  --leading 6 \
  --gpu-device-id 0 \
  --output output0.txt > log0.txt 2>&1 &

nohup ./target/release/createxcrunch create3 \
  --caller 0xbadfaceB351045374d7fd1d3915e62501BA9916C \
  --crosschain 0 \
  --leading 6 \
  --gpu-device-id 1 \
  --output output1.txt > log1.txt 2>&1 &

# Watch progress
tail -f log0.txt log1.txt
```

## Monitor

```bash
# Watch GPU utilization
watch -n 1 nvidia-smi

# Check logs
tail -f log0.txt log1.txt

# Check results
cat output0.txt output1.txt
```

## Quick Restart (after instance reboot)

```bash
sudo mv /etc/OpenCL/vendors/pocl.icd /etc/OpenCL/vendors/pocl.icd.disabled 2>/dev/null
cd /workspace/createXcrunch
./target/release/createxcrunch create3 \
  --caller 0xbadfaceB351045374d7fd1d3915e62501BA9916C \
  --crosschain 0 \
  --leading 6 \
  --gpu-device-id 0
```

## Expected Performance

- RTX 4090: ~600M attempts/sec per GPU
- RTX 3090: ~300M attempts/sec per GPU

## Difficulty Estimates

- 4 leading zeros: minutes
- 5 leading zeros: hours
- 6 leading zeros: hours to days
