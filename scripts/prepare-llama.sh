#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
source tools/llama-cpp-pin.txt
if [ -d Vendor/llama.xcframework/ios-arm64-simulator ]; then
    echo "llama.xcframework is already prepared."
    exit 0
fi
mkdir -p Vendor third_party build/downloads
if [ ! -d Vendor/build-apple/llama.xcframework ]; then
    curl --fail --location --retry 3 \
        https://github.com/ggml-org/llama.cpp/releases/download/b10726/llama-b10726-xcframework.zip \
        -o build/downloads/llama.zip
    echo 'b9063e452e47118f059a6a53e659b8e522d274fcf261fd333a9288aad3261183  build/downloads/llama.zip' | shasum -a 256 -c -
    unzip -q build/downloads/llama.zip -d Vendor
fi
if [ ! -d third_party/llama.cpp ]; then
    curl --fail --location --retry 3 "https://github.com/ggml-org/llama.cpp/archive/${PIN}.tar.gz" \
        -o build/downloads/llama-source.tar.gz
    echo '98be62ffb489f0f9f410abf387323ad89ffd168d39c0df0a20ee4bb946c8582a  build/downloads/llama-source.tar.gz' | shasum -a 256 -c -
    tar -xzf build/downloads/llama-source.tar.gz -C third_party
    mv "third_party/llama.cpp-${PIN}" third_party/llama.cpp
fi
# Upstream b10726 has an iPhone device slice, but no simulator slice.
# Build CPU inference for Apple Silicon Simulator from exactly the same revision.
cmake -S third_party/llama.cpp -B build/llama-simulator \
    -DCMAKE_SYSTEM_NAME=iOS -DCMAKE_OSX_SYSROOT=iphonesimulator \
    -DCMAKE_OSX_ARCHITECTURES=arm64 -DCMAKE_OSX_DEPLOYMENT_TARGET=17.0 \
    -DCMAKE_BUILD_TYPE=Release -DBUILD_SHARED_LIBS=OFF \
    -DLLAMA_BUILD_COMMON=OFF -DLLAMA_BUILD_TESTS=OFF -DLLAMA_BUILD_TOOLS=OFF \
    -DLLAMA_BUILD_EXAMPLES=OFF -DLLAMA_BUILD_SERVER=OFF -DLLAMA_BUILD_APP=OFF \
    -DLLAMA_BUILD_MTMD=OFF -DGGML_METAL=OFF -DGGML_OPENMP=OFF \
    -DGGML_NATIVE=OFF -DGGML_ACCELERATE=ON -DGGML_BLAS=OFF
cmake --build build/llama-simulator --config Release -j 6
bash scripts/package-llama.sh
