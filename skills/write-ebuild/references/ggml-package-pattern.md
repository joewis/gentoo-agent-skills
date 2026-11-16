# Packaging ggml-derived CMake Projects

Both llama.cpp and CrispASR (and other whisper.cpp/ggml forks) follow the same CMake patterns. This reference documents the commonalities for writing ebuilds for this family of packages.

## Common Characteristics

- **CMake-based** (minimum 3.14)
- **Vendored ggml** — the ggml library is bundled as a subdirectory (`ggml/`), not a system dependency. Define `LLAMA_USE_SYSTEM_GGML=OFF` / `CRISPASR_USE_SYSTEM_GGML=OFF` (this is the default — no flag needed).
- **C++17** required
- **`BUILD_SHARED_LIBS=ON`** by default (except WASM/MinGW)
- **Version from file** — `VERSION` file in source root, or from Git tags. May not work in archive tarball (has no `.git/`), so pass `-DBUILD_NUMBER="${PV}"` manually.
- **Wants to detect CPU features at build time** — always pass `-DGGML_NATIVE=OFF` for portability between build and runtime machines.
- **Wants to set RPATH** — always pass `-DCMAKE_SKIP_BUILD_RPATH=ON` for Gentoo.

## USE Flag Mapping

| CMake option | USE flag | Notes |
|---|---|---|
| `GGML_CUDA` | `cuda` | Requires `dev-util/nvidia-cuda-toolkit` |
| `GGML_VULKAN` | `vulkan` | Requires `media-libs/vulkan-loader` (runtime) + `dev-util/vulkan-headers` (build) |
| `GGML_METAL` | `metal` | Apple Silicon only — not useful on Gentoo amd64 |
| `GGML_OPENMP` | `openmp` | Requires OpenMP-capable compiler |
| `GGML_BLAS` / `GGML_BLAS_VENDOR` | `openblas`, etc. | For BLAS-accelerated CPU paths |
| `LLAMA_CURL` / `CRISPASR_CURL` | `curl` | Model auto-download support |
| `LLAMA_BUILD_SERVER` / `CRISPASR_BUILD_SERVER` | `server` | HTTP API server |
| `LLAMA_BUILD_TESTS` / `CRISPASR_BUILD_TESTS` | `tests` | Test suite |
| `LLAMA_BUILD_TOOLS` | `tools` | Extra CLI tools (llama-bench, quantize, etc.) |

## Deprecated Option Migration

llama.cpp and its forks have migrated from `LLAMA_*`/`CRISPASR_*` prefixed flags to `GGML_*` prefixed flags. The CMakeLists.txt includes deprecation helpers that emit warnings for old names but still honour them. Use the new `GGML_*` names in ebuilds:

| Old | New |
|---|---|
| `LLAMA_CUBLAS` | `GGML_CUDA` |
| `LLAMA_CUDA` | `GGML_CUDA` |
| `LLAMA_METAL` | `GGML_METAL` |
| `LLAMA_NATIVE` | `GGML_NATIVE` |
| `LLAMA_OPENMP` | `GGML_OPENMP` |
| `LLAMA_RPC` | `GGML_RPC` |
| `LLAMA_SYCL` | `GGML_SYCL` |
| `LLAMA_CURL` | (removed — no replacement, warning level only) |

## Archive Tarball Source Dir

GitHub archive tarballs produce different top-level directories:

- **Default**: `${WORKDIR}/${PN}-${PV}` (e.g. `llama-cpp-9784`)
- **With v-prefix tag**: `${WORKDIR}/${PN^}-${PV}` or `${WORKDIR}/CrispASR-${PV}`
- **For pre-release tags (b numbers)**: `llama.cpp-archive/refs/tags/b9784.tar.gz` extracts to `llama.cpp-b9784/`

Always verify with `tar tzf ... | head -1` before setting `S`.

## CUDA Sandbox Exceptions

When `cuda` USE flag is enabled, addpredict the NVIDIA device files to prevent sandbox violations during configure:

```bash
if use cuda; then
    addpredict /dev/nvidiactl
    addpredict /dev/nvidia-uvm
    addpredict /dev/nvidia-modeset
    addpredict /proc/driver/nvidia/params
fi
```
