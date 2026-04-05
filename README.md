# R.O.A.S.T.
### Radeon On ARM, Serving Tokens

Run llama.cpp with Vulkan GPU inference on a Raspberry Pi 5 with an AMD Radeon GPU.

## Quick Install

Flash [Raspberry Pi OS Trixie Lite (64-bit)](https://www.raspberrypi.com/software/) to your SD card, boot, and run:

```bash
wget https://raw.githubusercontent.com/stylesuxx/roast/master/roast-setup.sh
sudo bash roast-setup.sh
```

A reboot is required after kernel installation. Re-run `sudo bash roast-setup.sh` after reboot to complete the setup.

## What to Expect

- **GPU-accelerated LLM inference** on a Raspberry Pi 5 via Vulkan
- **~48 tok/s generation, ~365 tok/s prompt processing** with a 7B Q4_K_M model on an RX 5600 XT
- **Multiple models** can be managed as systemd services on different ports
- **Web UI** via Open WebUI (optional, Docker-based)
- **No Ollama needed** - llama-server provides an OpenAI-compatible API directly
- Setup takes about **1-2 hours** (most of that is kernel and mesa compilation)

## What It Does

1. Fixes locale to `en_US.UTF-8`
2. Runs a full system upgrade
3. Removes armhf multiarch (incompatible with Pi 5's 16K page kernel)
4. Builds and installs the [Coreforge GPU-enabled kernel](https://github.com/Coreforge/linux) (adds `amdgpu` module)
5. Enables PCIe Gen 3
6. Installs AMD firmware and Vulkan drivers (mesa radv)
7. Builds a patched radv driver (`-mno-strict-align`) and memcpy fix for 16K page compatibility
8. Builds [llama.cpp](https://github.com/ggerganov/llama.cpp) with Vulkan backend
9. Installs the `roast` CLI globally
10. Optionally installs Docker and [Open WebUI](https://github.com/open-webui/open-webui)

## Hardware

- Raspberry Pi 5 (aarch64)
- AMD Radeon GPU connected via PCIe (tested with RX 5700 XT / Navi 10)
- External power supply for the GPU

## Requirements

- Fresh Raspberry Pi OS Trixie **Lite** (64-bit / arm64)
- Internet connection
- Time and patience for the kernel build

## Model Manager

The `roast` CLI is installed globally by the setup script. It manages model downloads and llama-server services.

### Add a model

```bash
sudo roast add https://huggingface.co/TheBloke/Mistral-7B-v0.1-GGUF/resolve/main/mistral-7b-v0.1.Q4_K_M.gguf --port 8080 --enable
```

### Run multiple models on different ports

```bash
sudo roast add <url-to-mistral.gguf> --port 8080 --enable
sudo roast add <url-to-codellama.gguf> --port 8081 --enable
```

### Manage models

```bash
sudo roast list              # List all models and their status
sudo roast status            # Full status (GPU, Vulkan, models, disk)
sudo roast enable <name>     # Start a model service
sudo roast disable <name>    # Stop a model service
sudo roast remove <name>     # Remove service and optionally delete the model file
sudo roast bench <name>      # Run llama-bench on a model
sudo roast update            # Update R.O.A.S.T. to the latest version
```

### Manual run

```bash
/opt/llama.cpp/build/bin/llama-server -m /opt/llama.cpp/models/your-model.gguf --port 8080 -ngl 99
```

## Things to Avoid

- Do **not** add `memcpy.so` to `/etc/ld.so.preload` unless you hit alignment errors at runtime
- Do **not** install `linux-image-arm64` (Debian generic kernel) - Pi 5 will not boot
- Do **not** enable armhf multiarch - 16K page kernel breaks 32-bit ARM libs
- AMD Ubuntu repos are x86_64 only - not useful on Pi 5

## GPU Monitoring

```bash
# Included in the setup
nvtop
```

## References

- [Coreforge Linux](https://github.com/Coreforge/linux) - GPU-enabled RPi kernel fork
- [Coreforge memcpy patch](https://gist.githubusercontent.com/Coreforge/91da3d410ec7eb0ef5bc8dee24b91359) - optional, skip unless needed
- [RPi kernel build docs](https://www.raspberrypi.com/documentation/computers/linux_kernel.html#natively-build-a-kernel)
- [llama.cpp](https://github.com/ggerganov/llama.cpp)
- [Open WebUI](https://github.com/open-webui/open-webui)

## License

[MIT](LICENSE)
