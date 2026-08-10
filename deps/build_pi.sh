#!/bin/bash
set -e

# ============================================================================
# pi_agent_rust Build Script for the iSH/PRoot Linux Sandbox
# ============================================================================
# Builds the `pi` agent binary as a static musl executable that runs inside
# the aarch64 Alpine guests (iSH on iOS, PRoot on Android).
#
# Repository: https://github.com/Dicklesworthstone/pi_agent_rust (submodule)
#
# Prerequisites:
#   - rustup with a stable toolchain >= 1.95 (the crate's rust-version)
#   - zig + cargo-zigbuild  (brew install zig; cargo install cargo-zigbuild)
#     cargo-zigbuild links against a bundled musl sysroot, so no musl-cross
#     toolchain is needed on macOS.
#
# Usage:
#   ./build_pi.sh [clean|release] [arch...]
#
# Examples:
#   ./build_pi.sh                # release, both aarch64 + x86_64
#   ./build_pi.sh release aarch64
#   ./build_pi.sh clean
#
# Output:
#   deps/resources/pi            - aarch64-unknown-linux-musl (device)
#   deps/resources/pi-x86_64     - x86_64-unknown-linux-musl  (simulator)
# ============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PI_DIR="$SCRIPT_DIR/pi_agent_rust"
OUTPUT_RESOURCES="$SCRIPT_DIR/resources"

# The repo pins rust-toolchain.toml to a nightly (CI only). Force the stable
# toolchain so rustup doesn't try to download nightly on every cargo call.
export RUSTUP_TOOLCHAIN="${RUSTUP_TOOLCHAIN:-stable}"

# Build configuration
TARGET_ARCHES=("aarch64-unknown-linux-musl" "x86_64-unknown-linux-musl")
# The `pi` BINARY is gated behind the `tui` feature (required-features in
# Cargo.toml), so it must be enabled to produce the executable. `tui` is only
# crossterm/bubbletea/glamour — the heavy stacks (wasmtime/image-resize/
# jemalloc/clipboard/syntax-highlighting) live in the non-default `full`
# feature and stay excluded. sqlite-sessions keeps pi's own session file
# persistence/resume.
FEATURES="--no-default-features --features sqlite-sessions,tui"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

log_info() { echo -e "${BLUE}ℹ️  $1${NC}"; }
log_success() { echo -e "${GREEN}✅ $1${NC}"; }
log_warning() { echo -e "${YELLOW}⚠️  $1${NC}"; }
log_error() { echo -e "${RED}❌ $1${NC}"; exit 1; }

check_prerequisites() {
    log_info "Checking prerequisites..."
    command -v rustup >/dev/null 2>&1 || log_error "rustup is required. Install from https://rustup.rs"
    command -v cargo-zigbuild >/dev/null 2>&1 || \
        log_error "cargo-zigbuild is required. Install with: cargo install cargo-zigbuild"
    command -v zig >/dev/null 2>&1 || \
        log_error "zig is required. Install with: brew install zig"
    log_success "Prerequisites OK"
}

target_std_installed() {
    local target="$1"
    local tc
    tc="$(rustc --print sysroot 2>/dev/null)/lib/rustlib/$target"
    [ -d "$tc" ] && [ -n "$(ls "$tc/lib/"libstd-*.rlib 2>/dev/null | head -1)" ]
}

build_for_target() {
    local target="$1"
    log_info "Building pi for target: $target"
    if target_std_installed "$target"; then
        log_info "rust-std for $target already installed — skipping 'rustup target add'"
    else
        rustup target add "$target"
    fi
    cargo zigbuild --release $FEATURES --target "$target"
    log_success "Built pi for $target"
}

install_artifact() {
    local target="$1"
    local suffix=""
    case "$target" in
        aarch64-unknown-linux-musl) suffix="" ;;
        x86_64-unknown-linux-musl)  suffix="-x86_64" ;;
    esac
    mkdir -p "$OUTPUT_RESOURCES"
    cp "$PI_DIR/target/$target/release/pi" "$OUTPUT_RESOURCES/pi$suffix"
    chmod 755 "$OUTPUT_RESOURCES/pi$suffix"
    log_success "Installed $OUTPUT_RESOURCES/pi$suffix ($(du -h "$OUTPUT_RESOURCES/pi$suffix" | cut -f1))"
}

if [ ! -d "$PI_DIR" ]; then
    log_error "Submodule not checked out. Run: git submodule update --init deps/pi_agent_rust"
fi

ACTION="${1:-release}"
if [ "$ACTION" = "clean" ]; then
    log_info "Cleaning pi build artifacts..."
    rm -rf "$PI_DIR/target"
    log_success "Clean done"
    exit 0
fi

if [ "$ACTION" != "release" ] && [ "$ACTION" != "debug" ]; then
    log_error "Unknown action '$ACTION'. Use: clean | release | debug"
fi

check_prerequisites
cd "$PI_DIR"

if [ $# -gt 1 ]; then
    # Explicit arch list after the action
    shift
    for target in "$@"; do
        build_for_target "$target"
        install_artifact "$target"
    done
else
    for target in "${TARGET_ARCHES[@]}"; do
        build_for_target "$target"
        install_artifact "$target"
    done
fi

log_success "pi build complete. Artifacts in $OUTPUT_RESOURCES/"
