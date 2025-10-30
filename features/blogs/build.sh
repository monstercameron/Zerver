#!/bin/bash
# Build script for blog DLL

set -e

# Change to features/blogs directory
cd "$(dirname "$0")"

# Create output directory
mkdir -p ../../zig-out/lib

# Build the DLL - main.zig will import other files
zig build-lib \
  -dynamic \
  -lsqlite3 \
  -lc \
  -fallow-shlib-undefined \
  main.zig \
  -femit-bin=../../zig-out/lib/blogs.dylib

echo "Blog DLL built successfully: ../../zig-out/lib/blogs.dylib"
