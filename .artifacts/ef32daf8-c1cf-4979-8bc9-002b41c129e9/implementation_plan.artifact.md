# Implementation Plan - Android Support with Vulkan for Ollama

This plan outlines the steps to adapt the Ollama repository to support building an Android APK that can run an Ollama server using the Vulkan API, specifically targeting Pixel 9 devices and Android 15.

## User Review Required

> [!IMPORTANT]
> Running a full Ollama server on Android is resource-intensive. Pixel 9 devices have sufficient RAM (12GB+), but background execution might be limited by Android's power management. We will implement a Foreground Service to mitigate this.

> [!WARNING]
> Vulkan performance on Android can vary. We will prioritize the `ggml-vulkan` backend from `llama.cpp`.

## Proposed Changes

### Native Build Configuration
We need to enable Android NDK cross-compilation for the native `llama-server` component.

#### [MODIFY] [CMakeLists.txt](file:///C:/Users/livec/StudioProjects/ollama/llama/server/CMakeLists.txt)
Update to better handle Android NDK toolchain and Vulkan detection for Android.

#### [NEW] [build_android.sh](file:///C:/Users/livec/StudioProjects/ollama/scripts/build_android.sh)
A script to orchestrate the build of both the native payload and the Go server for Android.

### Go Server Adaptation
The Go code needs to be cross-compiled for `android/arm64`.

#### [MODIFY] [discover/vulkan.go](file:///C:/Users/livec/StudioProjects/ollama/discover/vulkan.go)
Add Android-specific Vulkan discovery or ensure existing logic doesn't fail on Android.

#### [MODIFY] [llm/llama_server.go](file:///C:/Users/livec/StudioProjects/ollama/llm/llama_server.go)
Ensure process management (starting `llama-server`) works within the Android environment (e.g., correct paths for binaries).

### Android Application Layer
A new Android project to wrap the Ollama server.

#### [NEW] [android/](file:///C:/Users/livec/StudioProjects/ollama/android/)
A new directory containing the Android Studio project (Kotlin/Compose).
- **OllamaServerService**: A foreground service that manages the lifecycle of the Go server.
- **MainActivity**: A simple UI to start/stop the server and display the API URL and logs.
- **build.gradle.kts**: Configured for Android 15 (API 35).

## Verification Plan

### Automated Tests
- Cross-compile the Go binary and native libraries using the NDK.
- Verify the `llama-server` binary can be executed on an `arm64-v8a` emulator or device.

### Manual Verification
1. Build the APK using `./gradlew assembleDebug` in the `android/` directory.
2. Install on a Pixel 9 or Android 15 device.
3. Start the server via the UI.
4. Verify the server is reachable at `http://localhost:11434`.
5. Run a small model (e.g., `llama3.2:1b`) and verify Vulkan acceleration is used (check logs for `ggml_vulkan`).
