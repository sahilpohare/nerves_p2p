#!/usr/bin/env bash
# Build script for p2p_bridge with cross-compilation support

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# Detect target from MIX_TARGET environment variable or default to host
TARGET="${MIX_TARGET:-host}"
PROFILE="${BUILD_PROFILE:-release}"

echo "Building p2p_bridge for target: $TARGET (profile: $PROFILE)"

case "$TARGET" in
  host)
    # Build for current platform
    cargo build --$PROFILE
    ;;

  rpi|rpi0|rpi2)
    # ARMv7 for Raspberry Pi 1/2/Zero
    cargo build --$PROFILE --target armv7-unknown-linux-gnueabihf
    ;;

  rpi3|rpi4|rpi5)
    # AArch64 for Raspberry Pi 3/4/5
    cargo build --$PROFILE --target aarch64-unknown-linux-gnu
    ;;

  bbb)
    # BeagleBone Black - ARMv7
    cargo build --$PROFILE --target armv7-unknown-linux-gnueabihf
    ;;

  x86_64)
    # x86_64 with musl for static linking
    cargo build --$PROFILE --target x86_64-unknown-linux-musl
    ;;

  *)
    echo "Unknown target: $TARGET"
    echo "Supported targets: host, rpi, rpi0, rpi2, rpi3, rpi4, rpi5, bbb, x86_64"
    exit 1
    ;;
esac

echo "Build complete!"
