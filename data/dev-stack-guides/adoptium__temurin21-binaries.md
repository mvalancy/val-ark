# Temurin JDK (OpenJDK)

Java: the runtime and compiler. Needed to run Java programs the Ark carries (Ghidra, jadx,
DBeaver, Neo4j, OpenSearch, Gradle) and to build your own. Temurin is the free OpenJDK
build from the Eclipse Adoptium project. The Ark keeps two long-term versions, 21 and 25.

## Which file

Names look like `OpenJDK21U-jdk_x64_linux_hotspot_<version>.tar.gz`.

- `jdk` is the full kit (run and compile). `jre` only runs programs and is smaller.
- `x64` is Intel/AMD. `aarch64` is ARM64 (Jetson, Apple Silicon).
- `linux` `.tar.gz`, `mac` `.pkg` or `.tar.gz`, `windows` `.msi` or `.zip`.

## Install

Linux (use `OpenJDK25U` and `jdk-25*` for version 25):

```
sudo mkdir -p /opt/java
sudo tar -C /opt/java -xzf OpenJDK21U-jdk_x64_linux_hotspot_*.tar.gz
export JAVA_HOME=$(echo /opt/java/jdk-21*)
export PATH=$JAVA_HOME/bin:$PATH
java -version
```

Add the two `export` lines to `~/.profile` to keep them.

macOS: open the `.pkg`. Windows: run the `.msi`; its options can set `JAVA_HOME` and the PATH for you.

## First steps offline

- Run a program: `java -jar program.jar`
- Compile and run one file: `java Hello.java`
- Several versions can sit side by side in `/opt/java`; `JAVA_HOME` picks the one in use.

Build tools (Gradle, Maven) download libraries from the internet on first use. Offline
they need a project that ships its libraries or a filled local cache: `gradle --offline`
uses only what is already in `~/.gradle`.
