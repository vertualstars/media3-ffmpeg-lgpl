#!/usr/bin/env bash
#
# media3-ffmpeg-lgpl: build FFmpeg for Android, per ABI, as LGPL-only shared libraries.
#
#   ffmpeg/build.sh                      fetch the pinned FFmpeg tag and build every ABI
#   ffmpeg/build.sh --print-config ABI   print the configure arguments (one per line) and exit
#
# Everything variable is read from gradle.properties. The NDK is found via ANDROID_NDK_HOME, or
# ANDROID_HOME / ANDROID_SDK_ROOT + ndk/<ndk.version>. Linux and macOS hosts; on Windows use WSL
# or let GitHub Actions run this.
#
# Why these choices, briefly (the spec in docs/superpowers/specs has the long form):
#   --disable-gpl --disable-nonfree   the entire point: the output must be LGPL-2.1+. Checked
#                                     against config.h BEFORE the compile, so a mistake costs
#                                     seconds rather than the whole build.
#   --enable-shared                   separate .so files are what makes LGPL section 6 (the
#                                     recipient can relink) trivially true.
#   --target-os=android               makes FFmpeg emit plain sonames (libavcodec.so), which is
#                                     what Android packaging and the Android linker expect.
#   max-page-size=16384               Play requires 16 KB page support for native code.
#   -Wl,-z,text                       fail the link on text relocations instead of shipping a
#                                     library Android refuses to load.
#   --disable-asm (x86_64 only)       emulator-only ABI; avoids nasm and any TEXTREL question.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROPS="$ROOT/gradle.properties"
SRC="$ROOT/ffmpeg/src"
OUT="$ROOT/ffmpeg/out"
JNILIBS="$ROOT/lib/src/main/jniLibs"

die() { echo "ffmpeg/build.sh: $*" >&2; exit 1; }
prop() {
  local value
  value="$(grep -E "^$1=" "$PROPS" | head -n1 | cut -d= -f2- | tr -d '\r')"
  [[ -n "$value" ]] || die "missing '$1' in gradle.properties"
  printf '%s' "$value"
}

FFMPEG_TAG="$(prop ffmpeg.tag)"
DECODERS="$(prop ffmpeg.decoders)"
ABIS="$(prop ffmpeg.abis)"
PAGE_SIZE="$(prop ffmpeg.pageSize)"
NDK_VERSION="$(prop ndk.version)"
MIN_SDK="$(prop lib.minSdk)"

MODE="build"
if [[ "${1:-}" == "--print-config" ]]; then
  MODE="print"
  PRINT_ABI="${2:-}"
  [[ -n "$PRINT_ABI" ]] || die "usage: build.sh --print-config <abi>"
elif [[ $# -gt 0 ]]; then
  die "unknown argument '$1' (usage: build.sh [--print-config <abi>])"
fi

# --- NDK and host ----------------------------------------------------------------------------

find_ndk() {
  if [[ -n "${ANDROID_NDK_HOME:-}" ]]; then printf '%s' "$ANDROID_NDK_HOME"; return; fi
  local base
  for base in "${ANDROID_HOME:-}" "${ANDROID_SDK_ROOT:-}"; do
    if [[ -n "$base" && -d "$base/ndk/$NDK_VERSION" ]]; then printf '%s' "$base/ndk/$NDK_VERSION"; return; fi
  done
  die "NDK $NDK_VERSION not found. Set ANDROID_NDK_HOME, or install it: sdkmanager \"ndk;$NDK_VERSION\""
}

host_tag() {
  if [[ -n "${FFMPEG_HOST_TAG:-}" ]]; then printf '%s' "$FFMPEG_HOST_TAG"; return; fi
  case "$(uname -s)" in
    Linux)  printf 'linux-x86_64' ;;
    Darwin) printf 'darwin-x86_64' ;;   # the NDK ships x86_64 binaries only; Rosetta runs them
    *) die "unsupported host $(uname -s). Build on Linux/macOS/WSL, or let GitHub Actions do it." ;;
  esac
}

NDK="$(find_ndk)"
HOST="$(host_tag)"
TOOLCHAIN="$NDK/toolchains/llvm/prebuilt/$HOST/bin"

# --- per-ABI settings (mirrors upstream media3 build_ffmpeg.sh) ------------------------------

abi_triple() {
  case "$1" in
    arm64-v8a)   printf 'aarch64-linux-android' ;;
    armeabi-v7a) printf 'armv7a-linux-androideabi' ;;
    x86_64)      printf 'x86_64-linux-android' ;;
    *) die "unknown ABI '$1' (supported: arm64-v8a armeabi-v7a x86_64)" ;;
  esac
}
abi_arch()    { case "$1" in arm64-v8a) printf 'aarch64' ;; armeabi-v7a) printf 'arm' ;; x86_64) printf 'x86_64' ;; esac; }
abi_cpu()     { case "$1" in arm64-v8a) printf 'armv8-a' ;; armeabi-v7a) printf 'armv7-a' ;; x86_64) printf 'x86-64' ;; esac; }
abi_cflags()  { case "$1" in armeabi-v7a) printf -- '-march=armv7-a -mfloat-abi=softfp' ;; *) printf '' ;; esac; }
abi_ldflags() { case "$1" in armeabi-v7a) printf -- '-Wl,--fix-cortex-a8' ;; *) printf '' ;; esac; }
abi_extra()   { case "$1" in x86_64) printf -- '--disable-asm' ;; *) printf '' ;; esac; }

# Prints the configure arguments for one ABI, one per line. Lines are argv elements: a value
# containing spaces (the ld flags) stays one argument when read back with mapfile.
configure_args() {
  local abi="$1"
  local triple; triple="$(abi_triple "$abi")"
  local page="-Wl,-z,max-page-size=$PAGE_SIZE -Wl,-z,text"
  local abi_ld; abi_ld="$(abi_ldflags "$abi")"
  local ldflags="${abi_ld:+$abi_ld }$page"
  local cflags; cflags="$(abi_cflags "$abi")"
  local extra; extra="$(abi_extra "$abi")"

  printf '%s\n' \
    "--target-os=android" \
    "--enable-cross-compile" \
    "--prefix=$OUT/$abi" \
    "--cross-prefix=$TOOLCHAIN/${triple}${MIN_SDK}-" \
    "--nm=$TOOLCHAIN/llvm-nm" \
    "--ar=$TOOLCHAIN/llvm-ar" \
    "--ranlib=$TOOLCHAIN/llvm-ranlib" \
    "--strip=$TOOLCHAIN/llvm-strip" \
    "--arch=$(abi_arch "$abi")" \
    "--cpu=$(abi_cpu "$abi")" \
    "--enable-shared" \
    "--disable-static" \
    "--enable-pic" \
    "--disable-gpl" \
    "--disable-nonfree" \
    "--disable-version3" \
    "--disable-doc" \
    "--disable-programs" \
    "--disable-everything" \
    "--disable-avdevice" \
    "--disable-avformat" \
    "--disable-swscale" \
    "--disable-postproc" \
    "--disable-avfilter" \
    "--enable-swresample" \
    "--disable-symver" \
    "--disable-v4l2-m2m" \
    "--disable-vulkan" \
    "--extra-ldflags=$ldflags" \
    "--extra-ldsoflags=$page" \
    "--extra-ldexeflags=-pie"
  [[ -n "$cflags" ]] && printf '%s\n' "--extra-cflags=$cflags"
  [[ -n "$extra" ]] && printf '%s\n' "$extra"
  local d
  for d in $DECODERS; do printf -- '--enable-decoder=%s\n' "$d"; done
}

if [[ "$MODE" == "print" ]]; then
  configure_args "$PRINT_ABI"
  exit 0
fi

# --- build -----------------------------------------------------------------------------------

[[ -d "$TOOLCHAIN" ]] || die "toolchain not found at $TOOLCHAIN (wrong NDK path or host tag?)"
command -v make >/dev/null || die "make is not installed"
JOBS="$(nproc 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo 4)"

fetch_source() {
  if [[ -d "$SRC/.git" ]]; then
    local have
    have="$(git -C "$SRC" describe --tags --exact-match 2>/dev/null || true)"
    if [[ "$have" == "$FFMPEG_TAG" ]]; then
      echo "==> FFmpeg $FFMPEG_TAG already checked out at $SRC"
      return
    fi
    echo "==> Replacing checkout ($have) with $FFMPEG_TAG"
    rm -rf "$SRC"
  fi
  echo "==> Cloning FFmpeg $FFMPEG_TAG"
  git clone --quiet --depth 1 --branch "$FFMPEG_TAG" https://github.com/FFmpeg/FFmpeg.git "$SRC"
}

# Refuse to compile anything that is not LGPL-2.1+ or that is missing a requested decoder.
check_config_h() {
  local abi="$1" cfg="$SRC/config.h" d name
  grep -qxF '#define FFMPEG_LICENSE "LGPL version 2.1 or later"' "$cfg" \
    || die "$abi: config.h is not LGPL-2.1+: $(grep FFMPEG_LICENSE "$cfg")"
  grep -qxF '#define CONFIG_GPL 0' "$cfg"     || die "$abi: CONFIG_GPL is not 0"
  grep -qxF '#define CONFIG_NONFREE 0' "$cfg" || die "$abi: CONFIG_NONFREE is not 0"
  for d in $DECODERS; do
    name="$(printf '%s' "$d" | tr '[:lower:]' '[:upper:]')"
    grep -qxF "#define CONFIG_${name}_DECODER 1" "$cfg" \
      || die "$abi: decoder '$d' is not enabled in config.h - is it a valid FFmpeg decoder name?"
  done
}

build_abi() {
  local abi="$1" lib
  echo "==> FFmpeg $FFMPEG_TAG for $abi"
  mkdir -p "$OUT/$abi" "$JNILIBS/$abi"
  local -a args
  mapfile -t args < <(configure_args "$abi")

  (
    cd "$SRC"
    make distclean >/dev/null 2>&1 || true
    { printf '%q ' ./configure "${args[@]}"; echo; } > "$OUT/$abi/configure.cmd"
    if ! ./configure "${args[@]}"; then
      echo "--- tail of ffbuild/config.log ---" >&2
      tail -n 80 ffbuild/config.log >&2 || true
      die "$abi: configure failed (full command in $OUT/$abi/configure.cmd)"
    fi
    cp config.h "$OUT/$abi/config.h"
  )
  check_config_h "$abi"

  ( cd "$SRC" && make -j"$JOBS" && make install )

  for lib in avutil swresample avcodec; do
    [[ -f "$OUT/$abi/lib/lib$lib.so" ]] || die "$abi: expected $OUT/$abi/lib/lib$lib.so after make install"
    cp "$OUT/$abi/lib/lib$lib.so" "$JNILIBS/$abi/lib$lib.so"
  done
  echo "==> $abi done: $(ls -m "$JNILIBS/$abi")"
}

mkdir -p "$OUT"
fetch_source
git -C "$SRC" rev-parse HEAD > "$OUT/ffmpeg-commit.txt"
printf '%s\n' "$FFMPEG_TAG" > "$OUT/ffmpeg-tag.txt"
for abi in $ABIS; do
  build_abi "$abi"
done
echo "==> All ABIs built. Next: ./gradlew :lib:assembleRelease && ffmpeg/verify.sh"
