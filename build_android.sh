#!/usr/bin/env bash
# Custom script to build Tailscale for Magisk Tailscaled

set -euo pipefail

# Resolve a clang toolchain that targets Android.
# Order of preference:
#   1) $ANDROID_NDK_PATH (caller-provided; e.g. NDK r27c bin dir on x86_64 hosts)
#   2) Termux's /data/data/com.termux/files/usr/bin (works when this script runs
#      inside a PRoot Distro on Termux; provides aarch64-linux-android-clang)
#   3) Auto-download NDK r27c linux-x86_64 (only meaningful on x86_64 hosts)
HOST_ARCH="$(uname -m)"
if [ -z "${ANDROID_NDK_PATH:-}" ]; then
    if [ -x "/data/data/com.termux/files/usr/bin/aarch64-linux-android-clang" ]; then
        ANDROID_NDK_PATH="/data/data/com.termux/files/usr/bin"
    else
        ANDROID_NDK_PATH="/tmp/android-ndk-r27c-linux/toolchains/llvm/prebuilt/linux-x86_64/bin"
    fi
fi
if [ ! -d "$ANDROID_NDK_PATH" ]; then
    echo "Android NDK path not found: $ANDROID_NDK_PATH"
    if [ "$HOST_ARCH" != "x86_64" ]; then
        echo "Host arch is $HOST_ARCH; the official NDK linux-x86_64 zip is unusable here."
        echo "Set \$ANDROID_NDK_PATH to a clang dir that has aarch64-linux-android*-clang, e.g."
        echo "  export ANDROID_NDK_PATH=/data/data/com.termux/files/usr/bin"
        exit 1
    fi
    curl -# -L https://dl.google.com/android/repository/android-ndk-r27c-linux.zip -o /tmp/android-ndk-r27c-linux.zip
    unzip -q /tmp/android-ndk-r27c-linux.zip -d /tmp
    mv /tmp/android-ndk-r27c /tmp/android-ndk-r27c-linux
    rm /tmp/android-ndk-r27c-linux.zip
    export ANDROID_NDK_PATH="/tmp/android-ndk-r27c-linux/toolchains/llvm/prebuilt/linux-x86_64/bin"
    echo "Android NDK path set to: $ANDROID_NDK_PATH"
fi
echo "Using Android toolchain at: $ANDROID_NDK_PATH"


# export TMPDIR=${TMPDIR:-/tmp}
# export GOTMPDIR="$TMPDIR/go-build"
# export GOCACHE="$TMPDIR/.gocache"
# export GOMODCACHE="$TMPDIR/.gomodcache"
# export XDG_CACHE_HOME="$TMPDIR/.cache"
# export XDG_HOME_DIR="$TMPDIR/.xdg"
# export HOME="$TMPDIR"
# export GOCROSS_NO_GO_INSTALL=1

# mkdir -p "$GOTMPDIR" "$GOCACHE" "$GOMODCACHE" "$XDG_CACHE_HOME"
# Use the "go" binary from the "tool" directory (which is github.com/tailscale/go)
# export PATH="$PWD"/tool:"$PATH"

export TS_USE_TOOLCHAIN=1
# export GOROOT=$(./tool/go env GOROOT)
eval "$(./build_dist.sh shellvars)"
export PATH="$ANDROID_NDK_PATH:$PATH"
# $GOROOT/bin/go version
# command -v go
# which go
# go version

# Parse arguments
PRE_RELEASE=""
USE_UPX=""
POSITIONAL_ARGS=()

while [ "$#" -gt 0 ]; do
    case "$1" in
        --pre)
            PRE_RELEASE="1"
            shift
            ;;
        --upx)
            USE_UPX="1"
            shift
            ;;
        *)
            POSITIONAL_ARGS+=("$1")
            shift
            ;;
    esac
done

# Restore positional parameters
set -- "${POSITIONAL_ARGS[@]}"

if [ "$#" -eq 0 ]; then
    echo "Usage: $0 [--pre] [--upx] <arm|arm64>"
    exit 1
fi

# Add -pre suffix to version if --pre flag is set
if [ -n "$PRE_RELEASE" ]; then
    VERSION_SHORT="${VERSION_SHORT}-pre"
fi

# Set the target architecture and platform
case "$1" in
    arm)
        if command -v armv7a-linux-androideabi21-clang >/dev/null 2>&1; then
            export CC=armv7a-linux-androideabi21-clang
            export CXX=armv7a-linux-androideabi21-clang++
        else
            export CC=armv7a-linux-androideabi-clang
            export CXX=armv7a-linux-androideabi-clang++
        fi
        export GOARCH="arm"
        ;;
    arm64)
        # NDK ships clang as aarch64-linux-android21-clang; Termux ships the
        # generic aarch64-linux-android-clang. Pick whichever exists.
        if command -v aarch64-linux-android21-clang >/dev/null 2>&1; then
            export CC=aarch64-linux-android21-clang
            export CXX=aarch64-linux-android21-clang++
        else
            export CC=aarch64-linux-android-clang
            export CXX=aarch64-linux-android-clang++
        fi
        export GOARCH="arm64"
        ;;
    amd64)
        export CC=x86_64-linux-android21-clang
        export CXX=x86_64-linux-android21-clang++
        export GOARCH="amd64"
        ;;
    *)
        echo "Unknown option: $1"
        exit 1
        ;;
esac

# Set common environment variables
export GOOS=android
export CGO_ENABLED=1
ldflags="-X tailscale.com/version.longStamp=${VERSION_LONG} -X tailscale.com/version.shortStamp=${VERSION_SHORT} -X tailscale.com/version.gitCommitStamp=${VERSION_GIT_HASH}"
ldflags="$ldflags -w -s"

# Feature tags configuration.
# Removed: features that don't apply to Magisk Android use-case.
# Notably we KEEP taildrop so `tailscale file get/cp` are available — the
# magisk-tailscaled GUI's Drop daemon and file-share flow depend on these.
REMOVE=(
    aws
    bird
    tap
    kube
    completion
    completion_scripts
    wakeonlan
    capture
    systray
    drive
    syspolicy
    appconnectors
    identityfederation
    captiveportal
)

ADD=(
    cli
)

# Generate build tags
REMOVE_STR=$(IFS=,; echo "${REMOVE[*]}")
ADD_STR=$(IFS=,; echo "${ADD[*]}")
BUILD_TAGS=$(GOOS= GOARCH= ./tool/go run ./cmd/featuretags --remove "$REMOVE_STR" --add "$ADD_STR")

if [ -z "$BUILD_TAGS" ]; then
    echo "Error: Failed to generate build tags"
    exit 1
fi

# Build the binary
./tool/go build -tags="$BUILD_TAGS" \
    --ldflags="$ldflags" \
    -o ./dist/tailscaled.$GOARCH \
    -trimpath ./cmd/tailscaled

chmod +x ./dist/tailscaled.$GOARCH
echo "Build completed: $(file ./dist/tailscaled.$GOARCH)"

# Compress with UPX if --upx flag is set
if [ -n "$USE_UPX" ]; then
    if ! command -v upx &> /dev/null; then
        echo "UPX not found, downloading..."
        curl -# -L https://github.com/upx/upx/releases/download/v5.0.2/upx-5.0.2-amd64_linux.tar.xz -o /tmp/upx.tar.xz
        tar -xf /tmp/upx.tar.xz -C /tmp
        sudo mv /tmp/upx-5.0.2-amd64_linux/upx /usr/local/bin/
        rm -rf /tmp/upx.tar.xz /tmp/upx-5.0.2-amd64_linux
        echo "UPX installed"
    fi
    if ! command -v file &> /dev/null; then
        sudo apt install file -y
    fi
    echo "File size before compression: $(du -h ./dist/tailscaled.$GOARCH | cut -f1)"
    echo "Compressing with UPX..."
    if upx --lzma --best ./dist/tailscaled.$GOARCH 2>&1 | grep -q "AlreadyPackedException"; then
        echo "Binary already compressed, skipping"
    fi
    echo "File size after compression: $(du -h ./dist/tailscaled.$GOARCH | cut -f1)"
fi
