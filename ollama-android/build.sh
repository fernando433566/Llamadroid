#!/usr/bin/env bash
# Builds the Ollama server that ships inside Llamadroid and copies it into
# android/app/src/main/jniLibs/<ABI>/.
#
#   ./ollama-android/build.sh                 # arm64-v8a (real phones)
#   ABI=x86_64 ./ollama-android/build.sh      # Android emulator
#
# Steps:
#   1. Clone Ollama at the commit pinned in OLLAMA_COMMIT
#   2. Apply our patches from patches/*.patch
#   3. Build llama.cpp (Vulkan + RPC, and OpenCL for Adreno on arm64)
#   4. Build the Go "ollama" binary
#   5. Copy everything to jniLibs with Android-friendly names
#
# Required tools: git, cmake, ninja, glslc, python3, Go and the Android NDK. Override paths with the variables
# below if yours live elsewhere.
#
# Updating Ollama later: change OLLAMA_COMMIT, run this script, and if a patch
# no longer applies fix it in work/ollama and regenerate it with
# `git -C work/ollama format-patch -1 HEAD -o ../../patches`.

set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(dirname "$HERE")"

ABI="${ABI:-arm64-v8a}"
API_LEVEL="${API_LEVEL:-35}"          # matches minSdkVersion in build.gradle
ANDROID_NDK_HOME="${ANDROID_NDK_HOME:-$HOME/toolchains/android-ndk-r29}"
GO="${GO:-$(command -v go || echo "$HOME/toolchains/go1.26.11/bin/go")}"
JOBS="${JOBS:-$(nproc)}"

WORK="$HERE/work"
SRC="$WORK/ollama"
BUILD="$WORK/build-$ABI"
OUT="$REPO_ROOT/android/app/src/main/jniLibs/$ABI"
OLLAMA_COMMIT="$(tr -d '[:space:]' < "$HERE/OLLAMA_COMMIT")"

case "$ABI" in
    arm64-v8a) TRIPLE=aarch64-linux-android; GOARCH=arm64; CLANG_ARCH=aarch64 ;;
    x86_64)    TRIPLE=x86_64-linux-android;  GOARCH=amd64; CLANG_ARCH=x86_64 ;;
    *) echo "Unsupported ABI '$ABI' (use arm64-v8a or x86_64)" >&2; exit 1 ;;
esac

NDK_BIN="$ANDROID_NDK_HOME/toolchains/llvm/prebuilt/linux-x86_64/bin"
NDK_SYSROOT="$ANDROID_NDK_HOME/toolchains/llvm/prebuilt/linux-x86_64/sysroot"
[ -d "$NDK_BIN" ] || { echo "Android NDK not found at $ANDROID_NDK_HOME" >&2; exit 1; }
[ -x "$GO" ]      || { echo "Go not found (set GO=/path/to/go)" >&2; exit 1; }

step() { printf '\n\033[1m>>> %s\033[0m\n' "$*"; }

# --- 1 + 2. Source code -------------------------------------------------------
step "Preparing Ollama $OLLAMA_COMMIT with Llamadroid patches"
if [ ! -d "$SRC/.git" ]; then
    git clone https://github.com/ollama/ollama.git "$SRC"
fi
git -C "$SRC" fetch --quiet origin "$OLLAMA_COMMIT"
git -C "$SRC" checkout --quiet --force --detach "$OLLAMA_COMMIT"
git -C "$SRC" -c user.name=llamadroid -c user.email=build@localhost \
    am --quiet --3way "$HERE"/patches/*.patch

# --- 3. llama.cpp (llama-server and friends) ---------------------------------
DEPS="$WORK/deps"
clone_at() { # <url> <dir> <commit or tag>
    [ -d "$2/.git" ] || git clone --quiet "$1" "$2"
    git -C "$2" fetch --quiet --depth 1 origin "$3"
    git -C "$2" checkout --quiet --force --detach FETCH_HEAD
}

# The NDK ships an old vulkan.h and neither vulkan.hpp nor the SPIR-V headers,
# and it cannot use the host's copies. Install both into one folder, like the
# official Vulkan SDK does (llama.cpp expects them side by side). Only headers
# are needed: the phone provides libvulkan.so at runtime.
step "Fetching Vulkan and SPIR-V headers"
VULKAN_SDK_DIR="$DEPS/vulkan-sdk"
clone_at https://github.com/KhronosGroup/Vulkan-Headers.git "$DEPS/Vulkan-Headers" v1.4.363
clone_at https://github.com/KhronosGroup/SPIRV-Headers.git "$DEPS/SPIRV-Headers" vulkan-sdk-1.4.363.0
for headers in Vulkan-Headers SPIRV-Headers; do
    cmake -S "$DEPS/$headers" -B "$DEPS/$headers-build" -DBUILD_TESTING=OFF > /dev/null
    cmake --install "$DEPS/$headers-build" --prefix "$VULKAN_SDK_DIR" > /dev/null
done

CMAKE_EXTRA=()
if [ "$ABI" = arm64-v8a ]; then
    # Qualcomm Adreno GPUs run through llama.cpp's OpenCL backend (Vulkan
    # pipelines fail on Adreno drivers). The Khronos loader is only used to
    # link: it is NOT shipped, so at runtime libggml-opencl.so loads the
    # phone's own /vendor/lib64/libOpenCL.so (shipping a file with the same
    # name would shadow the real driver and hide the GPU).
    step "Building the OpenCL ICD loader (link time only)"
    clone_at https://github.com/KhronosGroup/OpenCL-Headers.git "$DEPS/OpenCL-Headers" \
        c9c8ccfab584f9f7610057c4633dbd3df7e012cc
    clone_at https://github.com/KhronosGroup/OpenCL-ICD-Loader.git "$DEPS/OpenCL-ICD-Loader" \
        18fdcd58286376124f938948aa8ed156079c1c16
    cmake -G Ninja -S "$DEPS/OpenCL-ICD-Loader" -B "$DEPS/opencl-loader-$ABI" \
        -DCMAKE_TOOLCHAIN_FILE="$ANDROID_NDK_HOME/build/cmake/android.toolchain.cmake" \
        -DANDROID_ABI="$ABI" -DANDROID_PLATFORM="android-$API_LEVEL" \
        -DOPENCL_ICD_LOADER_HEADERS_DIR="$DEPS/OpenCL-Headers" \
        -DCMAKE_BUILD_TYPE=Release > /dev/null
    ninja -C "$DEPS/opencl-loader-$ABI" > /dev/null
    CMAKE_EXTRA+=(
        -DGGML_OPENCL=ON
        -DGGML_OPENCL_USE_ADRENO_KERNELS=ON
        -DGGML_OPENCL_EMBED_KERNELS=ON
        -DOpenCL_INCLUDE_DIR="$DEPS/OpenCL-Headers"
        -DOpenCL_LIBRARY="$DEPS/opencl-loader-$ABI/libOpenCL.so"
    )
fi

step "Building llama.cpp for $ABI (this takes a while: Vulkan shaders)"
cmake -G Ninja -S "$SRC/llama/server" -B "$BUILD/llama" \
    -DCMAKE_TOOLCHAIN_FILE="$ANDROID_NDK_HOME/build/cmake/android.toolchain.cmake" \
    -DANDROID_ABI="$ABI" \
    -DANDROID_PLATFORM="android-$API_LEVEL" \
    -DCMAKE_BUILD_TYPE=Release \
    -DBUILD_SHARED_LIBS=ON \
    -DGGML_VULKAN=ON \
    -DGGML_RPC=ON \
    `# Build one CPU backend per ARM generation (v8.0, v8.2+dotprod, v8.6+i8mm,` \
    `# v9+SVE2...) and let llama.cpp pick the fastest one the phone supports.` \
    `# A single baseline build would leave dotprod/i8mm unused: much slower.` \
    -DGGML_NATIVE=OFF \
    -DGGML_BACKEND_DL=ON \
    -DGGML_CPU_ALL_VARIANTS=ON \
    -DVulkan_LIBRARY="$NDK_SYSROOT/usr/lib/$TRIPLE/$API_LEVEL/libvulkan.so" \
    -DVulkan_INCLUDE_DIR="$VULKAN_SDK_DIR/include" \
    -DVulkan_GLSLC_EXECUTABLE="$(command -v glslc)" \
    -DSPIRV-Headers_DIR="$VULKAN_SDK_DIR/share/cmake/SPIRV-Headers" \
    -DPython3_EXECUTABLE="$(command -v python3)" \
    "${CMAKE_EXTRA[@]}"
ninja -C "$BUILD/llama" -j "$JOBS"

# --- 4. Go server -------------------------------------------------------------
step "Building the ollama Go binary ($GOARCH)"
(
    cd "$SRC"
    export GOOS=android GOARCH="$GOARCH" CGO_ENABLED=1 GOTOOLCHAIN=local
    export CC="$NDK_BIN/${TRIPLE}${API_LEVEL}-clang" CXX="$NDK_BIN/${TRIPLE}${API_LEVEL}-clang++"
    # -s -w strips debug info: the APK gets much smaller and nothing is lost
    # for end users. The -X flag makes /api/version report the real version.
    VERSION="$(git describe --tags --always "$OLLAMA_COMMIT" 2>/dev/null || echo "$OLLAMA_COMMIT")"
    "$GO" build -trimpath \
        -ldflags="-s -w -X github.com/ollama/ollama/version.Version=${VERSION#v}-llamadroid" \
        -o "$BUILD/ollama" .
)

# --- 5. Copy into the app -----------------------------------------------------
# Android only lets apps execute files from their native library directory,
# and only installs files named lib*.so there. So executables are renamed
# "lib<name>_exec.so" (Ollama's Android patch looks for that name).
step "Copying binaries to $OUT"
find_one() { find "$BUILD" -type f -name "$1" -print -quit; }

rm -rf "$OUT" && mkdir -p "$OUT"
cp "$BUILD/ollama" "$OUT/libollama_exec.so"
for exe in llama-server llama-quantize ggml-rpc-server; do
    path="$(find_one "$exe")"
    if [ -n "$path" ]; then
        cp "$path" "$OUT/lib${exe//-/_}_exec.so"
    else
        echo "warning: $exe was not built" >&2
    fi
done
# Shared libraries, minus the llama.cpp command line tools Ollama never runs.
find "$BUILD/llama" -type f -name '*.so' \
    ! -name 'libllama-*bench-impl.so' ! -name 'libllama-cli-impl.so' \
    ! -name 'libllama-completion-impl.so' ! -name 'libllama-perplexity-impl.so' \
    ! -name 'libllama-fit-params-impl.so' \
    -exec cp {} "$OUT/" \;

# Runtime libraries that come with the NDK instead of llama.cpp.
cp "$NDK_SYSROOT/usr/lib/$TRIPLE/libc++_shared.so" "$OUT/"
LIBOMP="$(find "$NDK_BIN/../lib/clang" -path "*/lib/linux/$CLANG_ARCH/libomp.so" -print -quit)"
[ -n "$LIBOMP" ] && cp "$LIBOMP" "$OUT/"

"$NDK_BIN/llvm-strip" --strip-unneeded "$OUT"/*.so 2>/dev/null || true

step "Done"
ls -lh "$OUT"
