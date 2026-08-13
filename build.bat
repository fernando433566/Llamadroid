@echo off
setlocal
call "C:\Program Files\Microsoft Visual Studio\18\Community\VC\Auxiliary\Build\vcvarsall.bat" x64
if errorlevel 1 exit /b %errorlevel%

set ANDROID_NDK_HOME=C:\Users\livec\AppData\Local\Android\Sdk\ndk\28.2.13676358
set PATH=C:\Users\livec\AppData\Local\Android\Sdk\cmake\4.1.2\bin;%PATH%
set PYTHON_EXECUTABLE=C:\Users\livec\.cache\codex-runtimes\codex-primary-runtime\dependencies\python\python.exe

set ABI=arm64-v8a
call "C:\Program Files\Git\bin\bash.exe" scripts/build_android.sh
if errorlevel 1 exit /b %errorlevel%

set ABI=x86_64
call "C:\Program Files\Git\bin\bash.exe" scripts/build_android.sh
if errorlevel 1 exit /b %errorlevel%

call scripts\package_android_app.bat
if errorlevel 1 exit /b %errorlevel%

pushd ollama-app-for-Android-
call flutter pub get
if errorlevel 1 exit /b %errorlevel%
call flutter build apk --release --target-platform android-arm64,android-x64 --split-per-abi
set BUILD_RESULT=%errorlevel%
popd
exit /b %BUILD_RESULT%
