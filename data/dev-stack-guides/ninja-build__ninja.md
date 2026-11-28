# Ninja

A small, fast build runner. CMake writes the build plan, Ninja carries it out, usually
quicker than `make`. Many projects expect it.

## Install

One zip per platform, with a single program inside:

- Linux Intel/AMD: `ninja-linux.zip`
- Linux ARM64 (Jetson): `ninja-linux-aarch64.zip`
- macOS: `ninja-mac.zip`
- Windows: `ninja-win.zip` (`ninja-winarm64.zip` for Windows on ARM)

```
unzip ninja-linux.zip
sudo mv ninja /usr/local/bin/
ninja --version
```

On Windows, unpack `ninja.exe` into a folder that is on your PATH (next to `cmake.exe` works).

## First steps offline

You rarely run Ninja by hand. Ask CMake to use it:

```
cmake -B build -G Ninja
cmake --build build
```

Inside the build folder, `ninja` builds, `ninja -j4` limits it to four jobs (useful on a
small board that runs out of memory), and `ninja clean` removes what was built.
