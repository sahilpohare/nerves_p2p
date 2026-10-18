#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
TOOLCHAIN_BIN=""

for candidate in "$HOME"/.nerves/artifacts/nerves_toolchain_aarch64_nerves_linux_gnu-*/bin; do
  if [ -d "$candidate" ]; then
    TOOLCHAIN_BIN="$candidate"
  fi
done

if [ -z "$TOOLCHAIN_BIN" ]; then
  echo "RPi4 Nerves toolchain missing; run MIX_TARGET=rpi4 mix deps.get" >&2
  exit 1
fi

rustup target add aarch64-unknown-linux-gnu

export CARGO_TARGET_AARCH64_UNKNOWN_LINUX_GNU_LINKER="$TOOLCHAIN_BIN/aarch64-nerves-linux-gnu-gcc"
export CC_aarch64_unknown_linux_gnu="$TOOLCHAIN_BIN/aarch64-nerves-linux-gnu-gcc"
export AR_aarch64_unknown_linux_gnu="$TOOLCHAIN_BIN/aarch64-nerves-linux-gnu-ar"

cargo build \
  --manifest-path "$ROOT/native/iroh_discovery/Cargo.toml" \
  --release \
  --target aarch64-unknown-linux-gnu

mkdir -p "$ROOT/rootfs_overlay/usr/bin"
cp "$ROOT/native/iroh_discovery/target/aarch64-unknown-linux-gnu/release/iroh_discovery_port" \
  "$ROOT/rootfs_overlay/usr/bin/iroh_discovery_port"
"$TOOLCHAIN_BIN/aarch64-nerves-linux-gnu-strip" \
  "$ROOT/rootfs_overlay/usr/bin/iroh_discovery_port"
chmod 0755 "$ROOT/rootfs_overlay/usr/bin/iroh_discovery_port"

echo "Built rootfs_overlay/usr/bin/iroh_discovery_port"
