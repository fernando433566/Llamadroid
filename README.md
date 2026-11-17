<p align="center">
  <a href="https://ollama.com">
    <img src="https://github.com/ollama/ollama/assets/3325447/0d0b44e2-8f4a-4e99-9b52-a5c1c741c8f7" alt="ollama" width="200"/>
  </a>
</p>

# THIS APP WAS (sadly because i dont know to code <img src="https://static.wikia.nocookie.net/deltarune/images/d/dc/Spr_tenna_sad.png/revision/latest?cb=20250930083633" alt="ollama" width="56" style="vertical-align: -8px;" />) MADE WITH AI ❗❗

# SHOTOUT TO PROYECTS I USED
- [Ollama](https://github.com/ollama/ollama)
- [ollama-app-for-Android-](https://github.com/SMuflhi/ollama-app-for-Android-)
- [llama.cpp](https://github.com/ggml-org/llama.cpp)
- [llama.cpp-npu](https://github.com/haozixu/llama.cpp-npu)
- [rag-llama-cpp-starter](https://github.com/josedavidmi/rag-llama-cpp-starter) and [LARS](https://github.com/abgulati/LARS)
- [Google AI edge Gallery](https://github.com/google-ai-edge/gallery)
- [Whisper](https://github.com/openai/whisper) and [Nvidia-parkeet](https://huggingface.co/nvidia/parakeet-tdt-0.6b-v2)
- [Supertonic](https://github.com/supertone-inc/supertonic)

  (i hope i havent forgotten anyone)
# Minimun requirements
- Android 15
- a phone
- [a dream](https://www.youtube.com/watch?v=YFOhH_3Zfs8) (everithing is a JOJO reference)

# What does this app do?
 This app can:
- Run Ollama or GGUF models on your device via GPU (Vulkan), CPU, NPU (only whith HTP v73 or up) or if you are feeling brave using two or tree of the processing units at the same time
- Run models from local servers or ollama cloud
- Connect various devices via internet to form a RAG, wich, not only can unify devices into an unique device, but can also split the multimodal layers to other devices
- Use the app as an assistant with functions like using the cams, capturing the screen, calling, writing emails, searching the web, giving you toilet paper when you run out of it... you name it, you got it because you can even make your own functions
- Device actions can be trigered without the AI been used, and you can slap any customization of words to trigger the automatization
- in the menu of advanced options, you can expose the phone as a Ollama web server (GGUF models imported included), Activate the embedded audio feature for some models (To add this feature navigate to the top-rigth corner of the chat interface to see the selected model configuration, were you can use this option if your model supports it), and more features

# Building

The app bundles its own Ollama server, built from upstream Ollama plus a small
patch set in [`ollama-android/`](ollama-android/).

```sh
# 1. Native Ollama + llama.cpp for arm64 phones (puts the .so files in android/app/src/main/jniLibs)
./ollama-android/build.sh

# 2. The app
flutter build apk --release --target-platform android-arm64
```

Requirements: git, cmake, ninja, glslc, python3, Go, Android NDK (r29), Flutter and
a JDK (Android Studio's `jbr` works). Paths can be overridden with `ANDROID_NDK_HOME`
and `GO` (see the top of `build.sh`).

**Updating Ollama:** put the new upstream commit in `ollama-android/OLLAMA_COMMIT` and
run `build.sh`. If the patch no longer applies, fix it in `ollama-android/work/ollama`
and regenerate it with `git format-patch -1 HEAD -o ../../patches`.

**GPU:** Qualcomm Adreno GPUs use llama.cpp's OpenCL backend (their drivers fail to
build llama.cpp's Vulkan pipelines); other GPUs use Vulkan. On the CPU, only the
fast cores are used and llama.cpp picks the best instruction set for each phone
(dotprod / i8mm / SVE2).
