#!/bin/bash
# Build Ollama for Android with Vulkan support and an Adreno OpenCL fallback.
# Requires ANDROID_NDK_HOME to be set. Select the target with ABI=arm64-v8a
# (default) or ABI=x86_64.

set -eu

if [ -z "${ANDROID_NDK_HOME:-}" ]; then
    echo "ERROR: ANDROID_NDK_HOME is not set"
    exit 1
fi

API_LEVEL="${API_LEVEL:-35}"
ABI="${ABI:-arm64-v8a}"

case "$ABI" in
    arm64-v8a)
        TARGET_TRIPLE=aarch64-linux-android
        GOARCH=arm64
        NDK_ARCH=aarch64
        ;;
    x86_64)
        TARGET_TRIPLE=x86_64-linux-android
        GOARCH=amd64
        NDK_ARCH=x86_64
        ;;
    *)
        echo "ERROR: unsupported ABI '$ABI' (expected arm64-v8a or x86_64)"
        exit 1
        ;;
esac

# Vulkan SDK paths
VULKAN_SDK_PATH="C:/VulkanSDK/1.4.357.0"
SPIRV_HEADERS_DIR="$VULKAN_SDK_PATH/Lib/cmake/SPIRV-Headers"

BUILD_DIR="build-android/$ABI"
DIST_DIR="dist-android/$ABI"
if [ "${CLEAN_BUILD:-1}" = "1" ]; then
    rm -rf "$BUILD_DIR" "$DIST_DIR"
fi
mkdir -p "$BUILD_DIR" "$DIST_DIR"

echo ">>> Building native llama-server for Android ($ABI)..."

# Detect if we are on Windows
IS_WINDOWS=false
if [[ "$OSTYPE" == "msys" || "$OSTYPE" == "cygwin" ]]; then
    IS_WINDOWS=true
fi

EXTRA_CMAKE_ARGS=()
if [ "$IS_WINDOWS" = true ]; then
    HOST_CXX_WRAPPER="$(pwd)/scripts/msvc-cxx-wrapper.cmd"
    EXTRA_CMAKE_ARGS+=(
        "-DLLAMA_UI_HOST_CXX_COMPILER=$HOST_CXX_WRAPPER"
    )
fi

# Qualcomm exposes OpenCL as a public vendor library on supported Android
# devices. Build against Khronos' loader for link-time symbol resolution only;
# the loader itself is deliberately not packaged, so Android resolves the
# device's vendor libOpenCL.so at runtime.
if [ "$ABI" = "arm64-v8a" ]; then
    OPENCL_HEADERS_COMMIT=c9c8ccfab584f9f7610057c4633dbd3df7e012cc
    OPENCL_LOADER_COMMIT=18fdcd58286376124f938948aa8ed156079c1c16
    DEPS_DIR="build-android/deps"
    OPENCL_HEADERS_DIR="$DEPS_DIR/OpenCL-Headers"
    OPENCL_LOADER_DIR="$DEPS_DIR/OpenCL-ICD-Loader"
    OPENCL_LOADER_BUILD="$DEPS_DIR/opencl-loader-arm64"

    if [ ! -d "$OPENCL_HEADERS_DIR/.git" ]; then
        git clone https://github.com/KhronosGroup/OpenCL-Headers.git "$OPENCL_HEADERS_DIR"
    fi
    git -C "$OPENCL_HEADERS_DIR" fetch --depth 1 origin "$OPENCL_HEADERS_COMMIT"
    git -C "$OPENCL_HEADERS_DIR" checkout --detach "$OPENCL_HEADERS_COMMIT"

    if [ ! -d "$OPENCL_LOADER_DIR/.git" ]; then
        git clone https://github.com/KhronosGroup/OpenCL-ICD-Loader.git "$OPENCL_LOADER_DIR"
    fi
    git -C "$OPENCL_LOADER_DIR" fetch --depth 1 origin "$OPENCL_LOADER_COMMIT"
    git -C "$OPENCL_LOADER_DIR" checkout --detach "$OPENCL_LOADER_COMMIT"

    # Keep the Khronos loader distinct from Qualcomm's vendor libOpenCL.so.
    # The loader then opens the vendor implementation through
    # OCL_ICD_FILENAMES without an ELF SONAME collision.
    sed -i \
        -e 's/set_target_properties (OpenCL PROPERTIES VERSION 1\\.0\\.0 SOVERSION "1")/set_target_properties (OpenCL PROPERTIES OUTPUT_NAME OpenCL)/' \
        -e 's/OUTPUT_NAME OpenCLLoader/OUTPUT_NAME OpenCL/' \
        -e 's/OUTPUT_NAME OpenCLVendor/OUTPUT_NAME OpenCL/' \
        "$OPENCL_LOADER_DIR/CMakeLists.txt"

    cmake -G Ninja -S "$OPENCL_LOADER_DIR" -B "$OPENCL_LOADER_BUILD" \
        -DCMAKE_TOOLCHAIN_FILE="$ANDROID_NDK_HOME/build/cmake/android.toolchain.cmake" \
        -DANDROID_ABI="$ABI" \
        -DANDROID_PLATFORM="android-$API_LEVEL" \
        -DOPENCL_ICD_LOADER_HEADERS_DIR="$(pwd)/$OPENCL_HEADERS_DIR" \
        -DOPENCL_ICD_LOADER_BUILD_SHARED_LIBS=ON \
        -DCMAKE_BUILD_TYPE=Release
    ninja -C "$OPENCL_LOADER_BUILD"

    if [ -z "${PYTHON_EXECUTABLE:-}" ] || [ ! -x "$PYTHON_EXECUTABLE" ]; then
        echo "ERROR: PYTHON_EXECUTABLE must point to Python 3 for embedded OpenCL kernels"
        exit 1
    fi
    EXTRA_CMAKE_ARGS+=(
        "-DGGML_OPENCL=ON"
        "-DGGML_OPENCL_USE_ADRENO_KERNELS=ON"
        "-DGGML_OPENCL_EMBED_KERNELS=ON"
        "-DOpenCL_INCLUDE_DIR=$(pwd)/$OPENCL_HEADERS_DIR"
        "-DOpenCL_LIBRARY=$(pwd)/$OPENCL_LOADER_BUILD/libOpenCL.so"
        "-DPython3_EXECUTABLE=$PYTHON_EXECUTABLE"
    )
fi

cmake -G Ninja -S llama/server -B "$BUILD_DIR/llama" \
    -DCMAKE_TOOLCHAIN_FILE="$ANDROID_NDK_HOME/build/cmake/android.toolchain.cmake" \
    -DANDROID_ABI="$ABI" \
    -DANDROID_PLATFORM="android-$API_LEVEL" \
    -DGGML_VULKAN=ON \
    -DGGML_RPC=ON \
    -DGGML_VULKAN_CHECK_RESULTS=OFF \
    -DVulkan_LIBRARY="$ANDROID_NDK_HOME/toolchains/llvm/prebuilt/windows-x86_64/sysroot/usr/lib/$TARGET_TRIPLE/$API_LEVEL/libvulkan.so" \
    -DVulkan_INCLUDE_DIR="$VULKAN_SDK_PATH/Include" \
    -DVulkan_GLSLC_EXECUTABLE="$VULKAN_SDK_PATH/Bin/glslc.exe" \
    -DSPIRV-Headers_DIR="$SPIRV_HEADERS_DIR" \
    -DLLAMA_BUILD_SERVER=ON \
    -DLLAMA_BUILD_EXAMPLES=OFF \
    -DLLAMA_BUILD_TESTS=OFF \
    -DBUILD_SHARED_LIBS=ON \
    -DCMAKE_BUILD_TYPE=Release \
    "${EXTRA_CMAKE_ARGS[@]}"

# Build. We use 'ninja' directly as it was verified to be in path or accessible.
ninja -C "$BUILD_DIR/llama"

# Copy native libraries to dist
mkdir -p "$DIST_DIR/lib"
mkdir -p "$DIST_DIR/bin"
find "$BUILD_DIR/llama" -name "*.so" -exec cp {} "$DIST_DIR/lib/" \;
find "$BUILD_DIR/llama" -name "llama-server" -exec cp {} "$DIST_DIR/bin/" \; 2>/dev/null || true
find "$BUILD_DIR/llama/bin" -name "llama-server" -exec cp {} "$DIST_DIR/bin/" \; 2>/dev/null || true
find "$BUILD_DIR/llama" -name "llama-quantize" -exec cp {} "$DIST_DIR/bin/" \; 2>/dev/null || true
find "$BUILD_DIR/llama/bin" -name "llama-quantize" -exec cp {} "$DIST_DIR/bin/" \; 2>/dev/null || true
find "$BUILD_DIR/llama" -name "ggml-rpc-server" -exec cp {} "$DIST_DIR/bin/" \; 2>/dev/null || true
find "$BUILD_DIR/llama/bin" -name "ggml-rpc-server" -exec cp {} "$DIST_DIR/bin/" \; 2>/dev/null || true
if [ "$ABI" = "arm64-v8a" ]; then
    cp "$OPENCL_LOADER_BUILD/libOpenCL.so" "$DIST_DIR/lib/"
fi

# Runtime libraries supplied by the NDK rather than by llama.cpp.
cp "$ANDROID_NDK_HOME/toolchains/llvm/prebuilt/windows-x86_64/sysroot/usr/lib/$TARGET_TRIPLE/libc++_shared.so" \
    "$DIST_DIR/lib/"
LIBOMP_PATH="$(find "$ANDROID_NDK_HOME/toolchains/llvm/prebuilt/windows-x86_64/lib/clang" \
    -path "*/lib/linux/$NDK_ARCH/libomp.so" -print -quit)"
if [ -z "$LIBOMP_PATH" ]; then
    echo "ERROR: libomp.so for $NDK_ARCH was not found in the NDK"
    exit 1
fi
cp "$LIBOMP_PATH" "$DIST_DIR/lib/"

echo ">>> Building Go ollama binary for Android ($GOARCH)..."
HOST_TAG=windows-x86_64
TOOLCHAIN_BIN="$ANDROID_NDK_HOME/toolchains/llvm/prebuilt/$HOST_TAG/bin"
export PATH="$TOOLCHAIN_BIN:$PATH"
export CC="$TOOLCHAIN_BIN/${TARGET_TRIPLE}${API_LEVEL}-clang.cmd"
export CXX="$TOOLCHAIN_BIN/${TARGET_TRIPLE}${API_LEVEL}-clang++.cmd"
export GOOS=android
export GOARCH=$GOARCH
export CGO_ENABLED=1

GO_BIN="$(command -v go 2>/dev/null || true)"
if [ -z "$GO_BIN" ] && [ -x "/c/Program Files/Go/bin/go.exe" ]; then
    GO_BIN="/c/Program Files/Go/bin/go.exe"
fi
if [ -z "$GO_BIN" ]; then
    echo "ERROR: Go compiler not found"
    exit 1
fi

"$GO_BIN" build -o "$DIST_DIR/bin/ollama" .

echo ">>> Build complete!"
