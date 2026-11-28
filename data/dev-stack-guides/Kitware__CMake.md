# CMake

The build system most C and C++ projects use. It is the first thing a source build asks
for: llama.cpp, whisper.cpp and stable-diffusion.cpp all need it, and on a Jetson they
must be built from source to use the GPU.

## Install

- Linux: `cmake-<version>-linux-x86_64.tar.gz` or `-linux-aarch64.tar.gz` (Jetson, ARM64).
- macOS: `cmake-<version>-macos-universal.dmg` (drag to Applications) or the `.tar.gz`.
- Windows: `cmake-<version>-windows-x86_64.msi` (installer) or the `.zip` (unpack anywhere).

Linux, no root needed:

```
tar xzf cmake-*-linux-x86_64.tar.gz -C ~/
export PATH=$(echo ~/cmake-*-linux-x86_64/bin):$PATH
cmake --version
```

Add the `export` line to `~/.bashrc` to keep it. The `.sh` file is a self-unpacking
installer for the same thing: `sudo sh cmake-*-linux-x86_64.sh --prefix=/usr/local --skip-license`.

You also need a compiler (`build-essential` from the Ark's offline APT sets) and, for
faster builds, Ninja (see its guide).

## First steps offline

In a project that has a `CMakeLists.txt`:

```
cmake -B build -G Ninja -DCMAKE_BUILD_TYPE=Release
cmake --build build -j
```

Leave out `-G Ninja` to use plain `make`. For llama.cpp with an NVIDIA GPU add `-DGGML_CUDA=ON`.

Some projects download their dependencies while configuring (`FetchContent`). Offline that
step fails: unpack the dependency yourself and pass `-DFETCHCONTENT_SOURCE_DIR_<NAME>=<folder>`,
or pass `-DFETCHCONTENT_FULLY_DISCONNECTED=ON` once the sources are in place.
