#!/usr/bin/env bash
# Checks the configure arguments build.sh would use, without an NDK, network or compiler.
# Runs on any machine (including Windows Git Bash): --print-config never touches the toolchain.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
BUILD="$ROOT/ffmpeg/build.sh"
PROPS="$ROOT/gradle.properties"

prop() { grep -E "^$1=" "$PROPS" | head -n1 | cut -d= -f2- | tr -d '\r'; }
DECODERS="$(prop ffmpeg.decoders)"
PAGE_SIZE="$(prop ffmpeg.pageSize)"
MIN_SDK="$(prop lib.minSdk)"

export ANDROID_NDK_HOME="${TMPDIR:-/tmp}/fake-ndk-$$"
export FFMPEG_HOST_TAG="linux-x86_64"
TOOLCHAIN="$ANDROID_NDK_HOME/toolchains/llvm/prebuilt/linux-x86_64/bin"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# The printed configuration for one ABI, generated once and grepped as a file. Never pipe the
# live process into `grep -q`: under pipefail, grep exiting at the first match sends the
# producer SIGPIPE and the pipeline reports failure even though the line was there.
config_of() {
  local file="$WORK/$1.txt"
  [[ -f "$file" ]] || "$BUILD" --print-config "$1" > "$file"
  printf '%s' "$file"
}

fails=0
expect() {  # expect <abi> <exact line>
  if ! grep -qxF -- "$2" "$(config_of "$1")"; then
    echo "FAIL [$1] expected line: $2"; fails=$((fails + 1))
  fi
}
reject() {  # reject <abi> <exact line>
  if grep -qxF -- "$2" "$(config_of "$1")"; then
    echo "FAIL [$1] must not contain: $2"; fails=$((fails + 1))
  fi
}

for abi in arm64-v8a armeabi-v7a x86_64; do
  expect "$abi" "--target-os=android"
  expect "$abi" "--enable-cross-compile"
  expect "$abi" "--prefix=$ROOT/ffmpeg/out/$abi"
  expect "$abi" "--enable-shared"
  expect "$abi" "--disable-static"
  expect "$abi" "--enable-pic"
  expect "$abi" "--disable-gpl"
  expect "$abi" "--disable-nonfree"
  expect "$abi" "--disable-version3"
  expect "$abi" "--disable-programs"
  expect "$abi" "--disable-doc"
  expect "$abi" "--disable-everything"
  expect "$abi" "--disable-avformat"
  expect "$abi" "--disable-swscale"
  expect "$abi" "--disable-avfilter"
  expect "$abi" "--disable-avdevice"
  expect "$abi" "--disable-postproc"
  expect "$abi" "--enable-swresample"
  expect "$abi" "--disable-symver"
  expect "$abi" "--extra-ldsoflags=-Wl,-z,max-page-size=$PAGE_SIZE -Wl,-z,text"
  expect "$abi" "--extra-ldexeflags=-pie"
  expect "$abi" "--nm=$TOOLCHAIN/llvm-nm"
  expect "$abi" "--strip=$TOOLCHAIN/llvm-strip"
  reject "$abi" "--enable-gpl"
  reject "$abi" "--enable-nonfree"
  reject "$abi" "--enable-static"
  for d in $DECODERS; do expect "$abi" "--enable-decoder=$d"; done
  # Exactly the configured decoders, no more.
  n_expected="$(echo "$DECODERS" | wc -w | tr -d ' ')"
  n_actual="$(grep -c -- '^--enable-decoder=' "$(config_of "$abi")")"
  if [[ "$n_expected" != "$n_actual" ]]; then
    echo "FAIL [$abi] $n_actual --enable-decoder lines, expected $n_expected"; fails=$((fails + 1))
  fi
done

expect arm64-v8a   "--cross-prefix=$TOOLCHAIN/aarch64-linux-android${MIN_SDK}-"
expect arm64-v8a   "--arch=aarch64"
expect arm64-v8a   "--cpu=armv8-a"
expect arm64-v8a   "--extra-ldflags=-Wl,-z,max-page-size=$PAGE_SIZE -Wl,-z,text"
reject arm64-v8a   "--disable-asm"

expect armeabi-v7a "--cross-prefix=$TOOLCHAIN/armv7a-linux-androideabi${MIN_SDK}-"
expect armeabi-v7a "--arch=arm"
expect armeabi-v7a "--cpu=armv7-a"
expect armeabi-v7a "--extra-cflags=-march=armv7-a -mfloat-abi=softfp"
expect armeabi-v7a "--extra-ldflags=-Wl,--fix-cortex-a8 -Wl,-z,max-page-size=$PAGE_SIZE -Wl,-z,text"
reject armeabi-v7a "--disable-asm"

expect x86_64      "--cross-prefix=$TOOLCHAIN/x86_64-linux-android${MIN_SDK}-"
expect x86_64      "--arch=x86_64"
expect x86_64      "--cpu=x86-64"
expect x86_64      "--disable-asm"

# An unknown ABI must be refused, not silently built with empty flags.
if "$BUILD" --print-config mips >/dev/null 2>&1; then
  echo "FAIL unknown ABI was accepted"; fails=$((fails + 1))
fi

if [[ $fails -eq 0 ]]; then echo "test_build_config: OK"; else echo "test_build_config: $fails failure(s)"; exit 1; fi
