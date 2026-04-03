.PHONY: all clean

# Detect the target and set build parameters
MIX_TARGET ?= host
PROFILE ?= release

# Set the target triple based on MIX_TARGET
ifeq ($(MIX_TARGET),rpi3)
	RUST_TARGET = aarch64-unknown-linux-gnu
else ifeq ($(MIX_TARGET),rpi4)
	RUST_TARGET = aarch64-unknown-linux-gnu
else ifeq ($(MIX_TARGET),rpi5)
	RUST_TARGET = aarch64-unknown-linux-gnu
else ifeq ($(MIX_TARGET),rpi)
	RUST_TARGET = armv7-unknown-linux-gnueabihf
else ifeq ($(MIX_TARGET),rpi0)
	RUST_TARGET = armv7-unknown-linux-gnueabihf
else ifeq ($(MIX_TARGET),rpi2)
	RUST_TARGET = armv7-unknown-linux-gnueabihf
else ifeq ($(MIX_TARGET),bbb)
	RUST_TARGET = armv7-unknown-linux-gnueabihf
else ifeq ($(MIX_TARGET),x86_64)
	RUST_TARGET = x86_64-unknown-linux-musl
else
	# Host build - use native target
	RUST_TARGET =
endif

# Set cargo build flags
ifeq ($(RUST_TARGET),)
	CARGO_BUILD_FLAGS = --$(PROFILE)
else
	CARGO_BUILD_FLAGS = --$(PROFILE) --target $(RUST_TARGET)
endif

# Set binary path based on target
ifeq ($(RUST_TARGET),)
	BINARY_SRC = native/p2p_bridge/target/$(PROFILE)/p2p_bridge
else
	BINARY_SRC = native/p2p_bridge/target/$(RUST_TARGET)/$(PROFILE)/p2p_bridge
endif

BINARY_DEST = priv/p2p_bridge

all: $(BINARY_DEST)

$(BINARY_DEST): native/p2p_bridge/src/*.rs native/p2p_bridge/Cargo.toml
	@echo "Building p2p_bridge for target: $(MIX_TARGET) ($(RUST_TARGET))"
	cd native/p2p_bridge && cargo build $(CARGO_BUILD_FLAGS)
	@mkdir -p priv
	cp $(BINARY_SRC) $(BINARY_DEST)
	@echo "Binary copied to $(BINARY_DEST)"

clean:
	cd native/p2p_bridge && cargo clean
	rm -f $(BINARY_DEST)
