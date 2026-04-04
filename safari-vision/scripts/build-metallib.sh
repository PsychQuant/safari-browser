#!/bin/bash
# Build MLX Metal shaders into mlx.metallib for SwiftPM CLI
# Required: Metal Toolchain (xcodebuild -downloadComponent MetalToolchain)

set -euo pipefail

METAL_DIR=".build/checkouts/mlx-swift/Source/Cmlx/mlx-generated/metal"
OUTPUT_DIR="${1:-.build/release}"
TEMP_DIR=$(mktemp -d)

trap "rm -rf $TEMP_DIR" EXIT

if ! xcrun metal --version &>/dev/null; then
    echo "❌ Metal compiler not found. Install with:" >&2
    echo "   xcodebuild -downloadComponent MetalToolchain" >&2
    exit 1
fi

if [ ! -d "$METAL_DIR" ]; then
    echo "❌ Metal shaders not found at $METAL_DIR" >&2
    echo "   Run 'swift build' first to checkout dependencies" >&2
    exit 1
fi

shopt -s nullglob
METAL_FILES=("$METAL_DIR"/*.metal)
shopt -u nullglob
if [ ${#METAL_FILES[@]} -eq 0 ]; then
    echo "❌ No .metal files found in $METAL_DIR" >&2
    exit 1
fi

echo "Compiling ${#METAL_FILES[@]} Metal shaders..."

for f in "${METAL_FILES[@]}"; do
    name=$(basename "$f" .metal)
    xcrun metal -c "$f" -I "$METAL_DIR" -o "$TEMP_DIR/$name.air" 2>&1
done

echo "Linking mlx.metallib..."
xcrun metallib "$TEMP_DIR"/*.air -o "$OUTPUT_DIR/mlx.metallib"

echo "✓ $OUTPUT_DIR/mlx.metallib ($(du -h "$OUTPUT_DIR/mlx.metallib" | cut -f1))"
