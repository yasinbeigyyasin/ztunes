#!/usr/bin/env bash
# Run from any directory. Requires Android SDK/NDK, Rust, cargo-ndk and a trusted libmpv build.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"
: "${ANDROID_HOME:?Set ANDROID_HOME to your Android SDK directory}"
: "${MPV_ANDROID_DIR:?Set MPV_ANDROID_DIR to a directory containing arm64-v8a/libmpv.so and all its dependencies}"
LIBS="$MPV_ANDROID_DIR/arm64-v8a"
[[ -f "$LIBS/libmpv.so" ]] || { echo "Missing $LIBS/libmpv.so" >&2; exit 1; }
command -v cargo-ndk >/dev/null || { echo 'Install cargo-ndk: cargo install cargo-ndk --locked' >&2; exit 1; }
rustup target add aarch64-linux-android
# Supply mpv to the Android linker. The remaining .so dependencies must be present in LIBS.
export RUSTFLAGS="${RUSTFLAGS:-} -L native=$LIBS"
export CARGO_TARGET_DIR="$ROOT/target/android-port"
cargo ndk -t arm64-v8a -P 26 build -p encore-ffi --lib
SO="$CARGO_TARGET_DIR/aarch64-linux-android/debug/libencore_ffi.so"
[[ -f "$SO" ]] || { echo "Core library not found: $SO" >&2; exit 1; }
# UniFFI extracts metadata directly from the cross-compiled library; no macOS host build needed.
# Do not pass the Android linker flags to the host bindgen build.
unset RUSTFLAGS
cargo build -p uniffi-bindgen
GEN="$ROOT/android/app/src/main/generated"
JNI="$ROOT/android/app/src/main/jniLibs/arm64-v8a"
rm -rf "$GEN" && mkdir -p "$GEN" "$JNI"
"$CARGO_TARGET_DIR/debug/uniffi-bindgen" generate --library "$SO" --language kotlin --out-dir "$GEN"
cp "$LIBS"/*.so "$JNI/"
cp "$SO" "$JNI/"
# Keep the debug APK small while preserving its exported JNI/UniFFI symbols.
if [[ "$(uname -s)" == Linux && -n "${ANDROID_NDK_HOME:-}" ]]; then
  STRIP="$ANDROID_NDK_HOME/toolchains/llvm/prebuilt/linux-x86_64/bin/llvm-strip"
  [[ -x "$STRIP" ]] && "$STRIP" --strip-unneeded "$JNI/libencore_ffi.so"
fi
echo "Native libraries and Kotlin bindings prepared. Run Gradle in android/."
