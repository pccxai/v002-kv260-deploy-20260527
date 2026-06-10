#!/bin/bash
# Gemma 3N E4B - Build Script
# Compiles C++ DLL and optionally Vulkan core

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# After reorg (2026-05-29): this script lives in deploy_tools/, C_DLL/ is at
# the workspace root one level up.  gemma_host/C_DLL is a symlink to the same
# directory, so either path resolves to the same .cpp / .so.
DLL_DIR="$SCRIPT_DIR/../C_DLL"

echo "=== Building my_accelerator.so ==="
echo "Target: Ryzen 5 4500U (znver2)"

# Use architecture-aware flags
ARCH=$(uname -m)
EXTRA_FLAGS=""
if [[ "$ARCH" == "aarch64" ]] || [[ "$ARCH" == "armv7"* ]]; then
    EXTRA_FLAGS="-mfp16-format=ieee"
fi

g++ -O3 -march=znver2 -shared -fPIC -fopenmp $EXTRA_FLAGS \
    -o "$DLL_DIR/my_accelerator.so" \
    "$DLL_DIR/my_accelerator.cpp"

echo "✓ my_accelerator.so compiled successfully"

# Build vulkan_core.so - always attempt with explicit -lvulkan
echo ""
echo "=== Building vulkan_core.so ==="
g++ -O3 -march=znver2 -shared -fPIC \
    -o "$DLL_DIR/vulkan_core.so" \
    "$DLL_DIR/vulkan_core.cpp" \
    -lvulkan
echo "✓ vulkan_core.so compiled successfully"

# Install glslangValidator if needed for shader compilation
if ! command -v glslangValidator &>/dev/null; then
    echo ""
    echo "[INFO] glslangValidator not found."
    echo "       Install: sudo apt install glslang-tools"
    echo "       Or:      sudo pacman -S glslang"
fi

echo ""
echo "=== Build Complete ==="
ls -la "$DLL_DIR"/*.so
