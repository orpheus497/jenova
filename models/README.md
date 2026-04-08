# Jenova Models Directory

This directory contains the LLM models used by Jenova. Models are organized into three categories:

## Directory Structure

```
models/
├── agent/    # Main inference models (7B-32B parameters)
├── embed/    # Embedding models for RAG and semantic search
└── draft/    # Small draft models for speculative decoding
```

## Model Organization

### `agent/` - Main Inference Models
Place your primary language models here. These are the models that power the main inference engine.

**Recommended models:**
- **Qwen2.5-Coder-7B-Instruct-Q5_K_M.gguf** (default, ~4.8GB)
- DeepSeek-Coder-6.7B-Instruct-Q5_K_M.gguf (~4.4GB)
- CodeLlama-13B-Instruct-Q4_K_M.gguf (~7.4GB)

**Requirements:**
- GGUF format
- Recommended: 7B-13B parameters for dual-GPU setup
- Recommended: Q4_K_M or Q5_K_M quantization

### `embed/` - Embedding Models
Place your embedding models here for RAG (Retrieval-Augmented Generation) and semantic search.

**Recommended models:**
- **nomic-embed-text-v1.5.Q8_0.gguf** (default, ~274MB)
- bge-large-en-v1.5-Q8_0.gguf (~1.2GB)
- all-MiniLM-L6-v2-Q8_0.gguf (~80MB)

**Requirements:**
- GGUF format
- Recommended: Q8_0 quantization for embedding quality

### `draft/` - Draft Models for Speculative Decoding
Place small, fast models here for speculative decoding, which accelerates main model inference.

**Recommended models:**
- **Qwen2.5-Coder-0.5B-Instruct-Q8_0.gguf** (default, ~559MB)
- DeepSeek-Coder-1.3B-Q8_0.gguf (~1.4GB)
- TinyLlama-1.1B-Q8_0.gguf (~1.1GB)

**Requirements:**
- GGUF format
- Recommended: 0.5B-1.5B parameters
- Recommended: Q8_0 quantization for accuracy

## Model Detection

Jenova automatically detects models in these directories via `lib/jenova-model.sh`.
The system will:

1. **Scan each type-specific directory** (`agent/`, `embed/`, `draft/`) for `.gguf` files
2. **Select the first model found** in each directory (sorted alphabetically)
3. **Fall back to a legacy filename** in the flat `models/` root if the subdirectory is empty

## Model Selection Priority

For each model type, Jenova uses the following priority (evaluated by `lib/jenova-model.sh`
and the `jenova.conf` sourcing chain at startup — before model inference begins):

1. **First `.gguf` file** in the corresponding typed subdirectory (alphabetically):
   - Agent: `models/agent/*.gguf`
   - Draft: `models/draft/*.gguf`
   - Embed: `models/embed/*.gguf`
2. **Legacy named file** in the flat `models/` root (specific filenames only, not a glob):
   - Agent: `models/Qwen2.5-Coder-7B-Instruct-Q5_K_M.gguf`
   - Draft: `models/Qwen2.5-Coder-0.5B-Instruct-Q8_0.gguf`
   - Embed: `models/nomic-embed-text-v1.5.Q8_0.gguf`
3. **Environment variable override** — applied in `jenova.conf` after the helper runs,
   so it wins regardless of what the directory scan found:
   - `JENOVA_MODEL` overrides the agent model path
   - `JENOVA_DRAFT_MODEL` overrides the draft model path
   - `JENOVA_EMBED_MODEL` overrides the embed model path
4. **Empty string / error** if no model is found and no override is set

> **Note:** There is no generic `models/*.gguf` glob fallback. Only the specific legacy
> filenames listed above are checked when the typed subdirectories are empty. Place new
> models in the appropriate subdirectory (`agent/`, `embed/`, or `draft/`) to ensure
> auto-discovery works correctly.

## Environment Variable Overrides

You can override auto-detected models using environment variables (set in your shell or
via `etc/jenova.local.conf`):

```sh
export JENOVA_MODEL=/path/to/custom/agent.gguf
export JENOVA_EMBED_MODEL=/path/to/custom/embed.gguf
export JENOVA_DRAFT_MODEL=/path/to/custom/draft.gguf
```

## Downloading Models

Download models using the installer or manually:

```sh
# Automatic download (downloads defaults)
./install.sh

# Manual download
cd models/agent
wget https://huggingface.co/Qwen/Qwen2.5-Coder-7B-Instruct-GGUF/resolve/main/qwen2.5-coder-7b-instruct-q5_k_m.gguf
```

## Model Compatibility

- **Format:** GGUF only (llama.cpp native format)
- **Quantization:** Q4_K_M, Q5_K_M, Q8_0 recommended
- **Context:** Models should support at least 8K context
- **Architecture:** Llama, Qwen, DeepSeek, CodeLlama, Mistral, etc.

## GPU Memory Requirements

### Dual-GPU Setup (GTX 1650 Ti 4GB + Intel Iris Xe ~7GB)
- **Agent model:** 7B at Q5_K_M (~4.8GB) - full offload
- **Embed model:** Small embedding model (~274MB) - CPU
- **Draft model:** 0.5B-1.5B (~559MB-1.4GB) - optional

### Single-GPU Setup (4GB VRAM)
- **Agent model:** 7B at Q4_K_M (~3.8GB) or partial offload
- **Embed model:** Small embedding model - CPU
- **Draft model:** 0.5B (~559MB) - optional

### Single-GPU Setup (8GB+ VRAM)
- **Agent model:** 7B-13B at Q5_K_M - full offload
- **Embed model:** Any size - can run on GPU
- **Draft model:** 1.5B-3B - can run on GPU

## Adding Custom Models

1. Download your `.gguf` model file
2. Place it in the appropriate directory (`agent/`, `embed/`, or `draft/`)
3. Restart Jenova: `bin/jenova-ca restart`
4. Verify detection: `bin/jenova-ca status`

Jenova will automatically detect and use your new model!
