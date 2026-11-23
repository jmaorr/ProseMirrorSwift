#!/bin/sh
# Builds Yrs.xcframework (libyrs.a: yffi, the C FFI of yrs, the Rust Yjs port) for the CYrs target.
# Only needed after changing the yffi version. Releases attach the zipped XCFramework.
# - It is static: an app that links the package can't load a dylib signed by another team.
# - It is relinked into one object that exports only the C API in libyrs.h. Every Rust static
#   library carries its own copy of Rust's std, so linking it next to another one (an app's
#   own Rust library) would otherwise fail on duplicate symbols such as rust_eh_personality.
# The header in Sources/CYrs/include/libyrs.h was generated from the same crate with
#   cbindgen --config cbindgen.toml --crate yffi --output libyrs.h
# run in the yffi source directory.
set -e
cd "$(dirname "$0")"
YFFI_VERSION=0.28.0
SRC=$(ls -d "$HOME"/.cargo/registry/src/*/yffi-$YFFI_VERSION 2>/dev/null | head -1)
if [ -z "$SRC" ]; then
  # Pull the crate into the cargo registry cache.
  TMP=$(mktemp -d)
  printf '[package]\nname="fetch"\nversion="0.0.0"\n[dependencies]\nyffi="=%s"\n' "$YFFI_VERSION" > "$TMP/Cargo.toml"
  mkdir "$TMP/src" && touch "$TMP/src/lib.rs"
  cargo fetch --manifest-path "$TMP/Cargo.toml"
  SRC=$(ls -d "$HOME"/.cargo/registry/src/*/yffi-$YFFI_VERSION | head -1)
fi
TOOLCHAIN=$(sed -n 's/^channel = "\(.*\)"/\1/p' rust-toolchain.toml)
TMP=$(mktemp -d)
grep -oE '[A-Za-z_][A-Za-z0-9_]*' ../Sources/CYrs/include/libyrs.h | sort -u > "$TMP/header"
# One relinked static library per platform: macOS (Apple silicon and Intel, so app archives
# can be universal), iOS devices, and the iOS Simulator (Apple silicon and Intel). Needs the rustup
# targets for the pinned toolchain: aarch64-apple-darwin x86_64-apple-darwin aarch64-apple-ios
# aarch64-apple-ios-sim x86_64-apple-ios.
# Each entry: platform (ld's -platform_version), minimum OS, then triple:arch pairs.
build_platform() {
  PLATFORM=$1; MIN=$2; shift 2
  for pair in "$@"; do
    TRIPLE=${pair%%:*}; ARCH=${pair##*:}
    # Keep local paths (home folder, cargo registry) out of the binary's panic and debug strings.
    RUSTFLAGS="--remap-path-prefix=$HOME/.cargo/registry/src=/cargo --remap-path-prefix=$HOME=/build" \
    RUSTUP_TOOLCHAIN=$TOOLCHAIN MACOSX_DEPLOYMENT_TARGET=11.0 IPHONEOS_DEPLOYMENT_TARGET=$MIN \
      cargo build --manifest-path "$SRC/Cargo.toml" --release --locked --target "$TRIPLE" --target-dir "$PWD/target"
    LIB=target/$TRIPLE/release/libyrs.a
    nm -gU "$LIB" 2>/dev/null | awk 'NF == 3 { print $3 }' | sed 's/^_//' | sort -u \
      | comm -12 - "$TMP/header" | sed 's/^/_/' > "$TMP/exports-$TRIPLE"
    ld -r -arch "$ARCH" -platform_version "$PLATFORM" "$MIN" "$MIN" -exported_symbols_list "$TMP/exports-$TRIPLE" \
      -all_load "$LIB" -o "$TMP/yrs-$TRIPLE.o" 2>/dev/null
    libtool -static -o "$TMP/libyrs-$TRIPLE.a" "$TMP/yrs-$TRIPLE.o"
  done
  mkdir -p "lib/$PLATFORM" && rm -f "lib/$PLATFORM/libyrs.a"
  lipo -create $(for pair in "$@"; do echo "$TMP/libyrs-${pair%%:*}.a"; done) -output "lib/$PLATFORM/libyrs.a"
}
build_platform macos 11.0 aarch64-apple-darwin:arm64 x86_64-apple-darwin:x86_64
build_platform ios 16.0 aarch64-apple-ios:arm64
build_platform ios-simulator 16.0 aarch64-apple-ios-sim:arm64 x86_64-apple-ios:x86_64
rm -rf "$TMP"
# What the package links (committed).
rm -rf Yrs.xcframework
xcodebuild -create-xcframework -library lib/macos/libyrs.a -library lib/ios/libyrs.a \
  -library lib/ios-simulator/libyrs.a -output Yrs.xcframework >/dev/null
echo "built $PWD/Yrs.xcframework"
