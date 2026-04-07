# R.O.A.S.T.
### Radeon On ARM, Serving Tokens

Run llama.cpp with Vulkan GPU inference on a Raspberry Pi 5 with an AMD Radeon GPU.

[![Arasaka KAI-7](https://media.printables.com/media/prints/1197633/images/9180493_2f9055ba-c9aa-4536-9c04-976aeef8cca7_c1ce62bc-3c14-4782-911c-a05ded12a3ed/thumbs/cover/800x800/jpg/img_20250310_1654428703.jpg)](https://www.printables.com/model/1197633-arasaka-kai-7)

*Hardware: [Arasaka KAI-7](https://www.printables.com/model/1197633-arasaka-kai-7) - cyberpunk inspired, RPi 5 based, small form factor PC with AMD Radeon RX 5600 XT GPU*

## Quick Install

Flash [Raspberry Pi OS Trixie Lite (64-bit)](https://www.raspberrypi.com/software/) to your SD card, boot, and run:

```bash
wget -qO- https://raw.githubusercontent.com/stylesuxx/roast/master/install.sh | sudo bash
```

A reboot is required after kernel installation. Re-run `sudo roast-setup` after reboot to complete the setup.

### Coreforge method (alternative)

If you prefer building a custom kernel from source (e.g. for a specific kernel version), use the `--coreforge` flag. This builds the [Coreforge GPU-enabled kernel](https://github.com/Coreforge/linux) and a patched mesa radv driver. Takes 1-2 hours.

```bash
sudo roast-setup --coreforge
```

## What to Expect

- **GPU-accelerated LLM inference** on a Raspberry Pi 5 via Vulkan
- **~48 tok/s generation, ~365 tok/s prompt processing** with a 7B Q4_K_M model on an RX 5600 XT
- **Multiple models** can be managed as systemd services on different ports
- **Web UI** via Open WebUI (optional, Docker-based)
- **No Ollama needed** - llama-server provides an OpenAI-compatible API directly
- Setup takes about **10 minutes** (default) or **1-2 hours** (with `--coreforge`)

## What It Does

**Default (rpi-update) method:**

1. Fixes locale to `en_US.UTF-8`
2. Runs a full system upgrade
3. Removes armhf multiarch (incompatible with Pi 5's 16K page kernel)
4. Installs kernel with amdgpu support via [rpi-update PR #7113](https://github.com/raspberrypi/linux/pull/7113)
5. Enables PCIe Gen 3
6. Installs AMD firmware and Vulkan drivers
7. Builds [llama.cpp](https://github.com/ggerganov/llama.cpp) with Vulkan backend
8. Installs the `roast` CLI globally
9. Optionally installs Docker and [Open WebUI](https://github.com/open-webui/open-webui)

**Coreforge method (`--coreforge`)** does the same but replaces step 4 with a kernel build from source, and adds a patched mesa radv driver + memcpy fix for 16K page compatibility.

## Hardware

- Raspberry Pi 5 (aarch64)
- AMD Radeon GPU connected via PCIe (tested with RX 5700 XT / Navi 10)
- External power supply for the GPU

## GPU Selection Guide

The Pi 5 has a single PCIe x1 Gen 3 slot (~1 GB/s). This limits model load time but **not inference speed** - once the model is in VRAM, compute happens entirely on the GPU.

**What matters most:**
- **VRAM** - determines max model size and context window
- **Compute speed** - faster GPU = faster tok/s
- **amdgpu driver support** - GCN 5 / Polaris and newer

| GPU | VRAM | Gen | What you can run |
|-----|------|-----|------------------|
| RX 5600 XT | 6 GB | RDNA1 | 7B Q4, ~8K context |
| RX 6600 | 8 GB | RDNA2 | 7B Q4, ~32K context |
| RX 6700 XT | 12 GB | RDNA2 | 13B Q4 or 7B Q8, large context |
| RX 7600 | 8 GB | RDNA3 | 7B Q4, faster compute than RDNA2 |
| RX 7700 XT | 12 GB | RDNA3 | Best balance of speed + VRAM |
| RX 6800 | 16 GB | RDNA2 | 30B Q4 or 13B Q8 |
| RX 9060 XT | 16 GB | RDNA4 | 30B Q4 or 13B Q8, fastest compute (default method only, `--coreforge` not yet supported) |

## Requirements

- Fresh Raspberry Pi OS Trixie **Lite** (64-bit / arm64)
- Internet connection
- Time and patience for the kernel build

## Model Manager

The `roast` CLI is installed globally by the setup script.

### Add a model

```bash
sudo roast add Qwen/Qwen2.5-7B-Instruct-GGUF qwen2.5-7b-instruct-q4_k_m.gguf --port 8080 --enable
```

### Multiple models on different ports

```bash
sudo roast add TheBloke/Mistral-7B-GGUF mistral-7b.Q4_K_M.gguf --port 8080 --enable
sudo roast add TheBloke/Codellama-7B-GGUF codellama-7b.Q4_K_M.gguf --port 8081 --enable
```

### Manage models

```bash
sudo roast list              # List all models and their status
sudo roast status            # Full status (GPU, Vulkan, models, disk)
sudo roast enable <name>     # Start a model service
sudo roast disable <name>    # Stop a model service
sudo roast remove <name>     # Remove service and optionally delete the model file
sudo roast config <name> ... # Change context size, GPU layers, port, etc.
sudo roast bench <name>      # Run llama-bench on a model
```

### Manual run

```bash
/opt/llama.cpp/build/bin/llama-server -m /opt/llama.cpp/models/your-model.gguf --port 8080 -ngl 99
```

## Performance Tuning

After adding a model, run `sudo roast bench <model-name>` to verify performance. The bench command automatically uses the same context size and GPU layer settings as your running service, so the results are representative of real-world performance.

```bash
sudo roast bench qwen2.5-coder-7b-instruct-q4_k_m
```

Expected results for a 7B Q4_K_M model on an RX 5600 XT (16K context, all layers on GPU):

| Metric | Expected | Problem if lower |
|--------|----------|------------------|
| pp (prompt processing) | ~375 tok/s | Layers or KV cache spilling to CPU |
| tg (text generation) | ~46 tok/s | Layers or KV cache spilling to CPU |

### Why performance can be slow

The Pi 5 connects to the GPU via a single PCIe x1 Gen 3 lane (~1 GB/s). Once the model is loaded into VRAM, inference happens entirely on the GPU at full speed. But if any part of the model or its KV cache spills to system RAM, every token requires data to cross the PCIe bus, dropping performance by 10-20x.

For full speed, the model weights + KV cache + compute buffers must all fit in VRAM:

| VRAM | Model | Max context (approximate) |
|------|-------|--------------------------|
| 6 GB | 7B Q4_K_M (4.4 GB) | ~16K |
| 8 GB | 7B Q4_K_M (4.4 GB) | ~48K |
| 12 GB | 7B Q4_K_M (4.4 GB) | ~128K |
| 12 GB | 13B Q4_K_M (7.9 GB) | ~32K |
| 16 GB | 13B Q4_K_M (7.9 GB) | ~64K |

### Parallel slots

By default, each model runs with `--parallel 1` (single user). This gives one user the full context window. If you need multiple concurrent users (e.g. Open WebUI + aider at the same time), increase it:

```bash
sudo roast config <model-name> --parallel 2
```

Each slot gets its own KV cache, so the VRAM cost multiplies: 2 slots = 2x KV cache. On limited VRAM, reduce context size when increasing parallel slots.

### Fixing slow performance

If bench results are significantly below expected (e.g. <20 tok/s), reduce context size, parallel slots, or ensure all layers are on GPU:

```bash
sudo roast config <model-name> --gpu-layers 99 --context-size 16384 --parallel 1
sudo roast bench <model-name>
```

## Things to Avoid

- Do **not** run `apt full-upgrade` without checking - it can overwrite the rpi-update kernel. The setup script pins kernel packages to prevent this, but be cautious.
- Do **not** add `memcpy.so` to `/etc/ld.so.preload` unless you hit alignment errors at runtime
- Do **not** install `linux-image-arm64` (Debian generic kernel) - Pi 5 will not boot
- Do **not** enable armhf multiarch - 16K page kernel breaks 32-bit ARM libs
- AMD Ubuntu repos are x86_64 only - not useful on Pi 5

## GPU Monitoring

```bash
nvtop    # included in the setup
```

## Next Steps

Once R.O.A.S.T. is running, you have an OpenAI-compatible API at `http://<hostname>:8080/v1`. Here are some tools that can use it:

### Coding Assistants

- **[aider](https://github.com/paul-gauthier/aider)** - CLI coding agent that can edit files, run commands, and work with git. Great for pair programming from the terminal.
  ```bash
  pip install aider-chat
  aider --openai-api-base http://ai01:8080/v1 --openai-api-key unused \
        --model openai/qwen2.5-coder-7b-instruct-q4_k_m.gguf --no-auto-commits
  ```

- **[OpenCode](https://github.com/opencode-ai/opencode)** - Terminal-based AI coding agent with file editing, search, and shell command tools. Requires a model with native tool calling support and 32K+ context. Works best with 16GB+ VRAM (e.g. Qwen 2.5 14B Instruct). See the [OpenCode docs](https://opencode.ai/docs/providers/) for OpenAI-compatible provider configuration.

- **[Continue](https://continue.dev)** - VS Code / JetBrains extension for code completion and chat. Point it at your local API for a self-hosted Copilot alternative.

- **[Open Interpreter](https://github.com/OpenInterpreter/open-interpreter)** - CLI agent that can run code, manage files, and control your computer via natural language.
  ```bash
  pip install open-interpreter
  interpreter --api-base http://ai01:8080/v1 --model qwen2.5-coder-7b-instruct-q4_k_m.gguf
  ```

### Chat and Knowledge

- **[Open WebUI](https://github.com/open-webui/open-webui)** - Web-based chat interface (included in the setup script). Supports RAG, document upload, and multi-user access.

- **[LibreChat](https://github.com/danny-avila/LibreChat)** - Another web chat interface with plugin support and conversation branching.

### Automation

- **[n8n](https://github.com/n8n-io/n8n)** - Workflow automation platform. Connect your local LLM to email, Slack, databases, and other services.

- **[LiteLLM](https://github.com/BerriAI/litellm)** - API proxy that lets you expose your local model as if it were any provider (Anthropic, OpenAI, etc). Useful for tools that don't support custom endpoints directly.

## References

- [Coreforge Linux](https://github.com/Coreforge/linux) - GPU-enabled RPi kernel fork
- [Coreforge memcpy patch](https://gist.githubusercontent.com/Coreforge/91da3d410ec7eb0ef5bc8dee24b91359)
- [RPi kernel build docs](https://www.raspberrypi.com/documentation/computers/linux_kernel.html#natively-build-a-kernel)
- [llama.cpp](https://github.com/ggerganov/llama.cpp)
- [Open WebUI](https://github.com/open-webui/open-webui)

[MIT](LICENSE)
