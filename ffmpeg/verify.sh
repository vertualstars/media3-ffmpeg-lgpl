#!/usr/bin/env bash
#
# media3-ffmpeg-lgpl: verify a built AAR before it is released.
#
#   ffmpeg/verify.sh [AAR]              default: lib/build/outputs/aar/media3-ffmpeg-lgpl-release.aar
#   ffmpeg/verify.sh --extracted DIR    check an already-unzipped AAR (used by the tests)
#
# Every claim the README makes is checked here, and all failures are reported before exiting
# non-zero, because a list of everything wrong is more useful than the first thing wrong.
#
# Tool output is captured into variables and grepped there. Piping a producer straight into
# `grep -q` is a trap under pipefail: grep exits at the first match, the producer takes SIGPIPE,
# and the pipeline reports failure for a line that was present.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROPS="$ROOT/gradle.properties"
OUT="${FFMPEG_OUT_DIR:-$ROOT/ffmpeg/out}"

die() { echo "ffmpeg/verify.sh: $*" >&2; exit 1; }
prop() {
  local value
  value="$(grep -E "^$1=" "$PROPS" | head -n1 | cut -d= -f2- | tr -d '\r')"
  [[ -n "$value" ]] || die "missing '$1' in gradle.properties"
  printf '%s' "$value"
}
ABIS="$(prop ffmpeg.abis)"
DECODERS="$(prop ffmpeg.decoders)"
PAGE_SIZE="$(prop ffmpeg.pageSize)"
NDK_VERSION="$(prop ndk.version)"
ALIGN_HEX="$(printf '0x%x' "$PAGE_SIZE")"

# --- input -------------------------------------------------------------------------------------
if [[ "${1:-}" == "--extracted" ]]; then
  EXTRACTED="${2:-}"; [[ -d "$EXTRACTED" ]] || die "--extracted needs a directory"
else
  AAR="${1:-$ROOT/lib/build/outputs/aar/media3-ffmpeg-lgpl-release.aar}"
  [[ -f "$AAR" ]] || die "AAR not found: $AAR (run ./gradlew :lib:assembleRelease)"
  EXTRACTED="$ROOT/build/verify/aar"
  rm -rf "$EXTRACTED"; mkdir -p "$EXTRACTED"
  unzip -q -o "$AAR" -d "$EXTRACTED"
  echo "verify: extracted $AAR"
fi

FAILS=0
fail() { echo "FAIL: $*"; FAILS=$((FAILS + 1)); }

# --- tools (resolved lazily: only needed once a .so actually exists) ---------------------------
READELF=""; NM=""; STRINGS=""
need_tools() {
  [[ -n "$READELF" ]] && return
  local ndk="" base host bin
  if [[ -n "${ANDROID_NDK_HOME:-}" ]]; then ndk="$ANDROID_NDK_HOME"
  else
    for base in "${ANDROID_HOME:-}" "${ANDROID_SDK_ROOT:-}"; do
      [[ -n "$base" && -d "$base/ndk/$NDK_VERSION" ]] && { ndk="$base/ndk/$NDK_VERSION"; break; }
    done
  fi
  case "$(uname -s)" in Darwin) host=darwin-x86_64 ;; *) host=linux-x86_64 ;; esac
  bin="$ndk/toolchains/llvm/prebuilt/$host/bin"
  if [[ -n "$ndk" && -x "$bin/llvm-readelf" ]]; then
    READELF="$bin/llvm-readelf"; NM="$bin/llvm-nm"; STRINGS="$bin/llvm-strings"
  else
    READELF="$(command -v readelf || true)"; NM="$(command -v nm || true)"; STRINGS="$(command -v strings || true)"
  fi
  [[ -n "$READELF" && -n "$NM" && -n "$STRINGS" ]] \
    || die "need readelf, nm and strings (from the NDK at ANDROID_NDK_HOME, or binutils)"
}

JNI_SYMBOLS=(
  Java_androidx_media3_decoder_ffmpeg_FfmpegLibrary_ffmpegGetVersion
  Java_androidx_media3_decoder_ffmpeg_FfmpegLibrary_ffmpegGetInputBufferPaddingSize
  Java_androidx_media3_decoder_ffmpeg_FfmpegLibrary_ffmpegHasDecoder
  Java_androidx_media3_decoder_ffmpeg_FfmpegAudioDecoder_ffmpegInitialize
  Java_androidx_media3_decoder_ffmpeg_FfmpegAudioDecoder_ffmpegDecode
  Java_androidx_media3_decoder_ffmpeg_FfmpegAudioDecoder_ffmpegGetChannelCount
  Java_androidx_media3_decoder_ffmpeg_FfmpegAudioDecoder_ffmpegGetSampleRate
  Java_androidx_media3_decoder_ffmpeg_FfmpegAudioDecoder_ffmpegReset
  Java_androidx_media3_decoder_ffmpeg_FfmpegAudioDecoder_ffmpegRelease
)

# --- per-.so checks -----------------------------------------------------------------------------
check_alignment() {  # every LOAD segment aligned to the page size
  local so="$1" label="$2" bad
  bad="$("$READELF" -l "$so" | awk '/^ *LOAD/ {print $NF}' | grep -vx "$ALIGN_HEX" || true)"
  [[ -z "$bad" ]] || fail "$label: LOAD segment alignment $bad, expected $ALIGN_HEX (16 KB pages)"
}
check_no_textrel() {
  local so="$1" label="$2" dyn
  dyn="$("$READELF" -d "$so")"
  if grep -q 'TEXTREL' <<<"$dyn"; then fail "$label: has text relocations (Android refuses to load it)"; fi
}
check_ffmpeg_lib() {  # licence string and plain soname
  local so="$1" label="$2" name="$3" strs dyn soname
  strs="$("$STRINGS" "$so")"
  grep -q 'license: LGPL version 2.1 or later' <<<"$strs" || fail "$label: LGPL-2.1 licence string not found"
  if grep -qE 'license: (GPL|nonfree)' <<<"$strs"; then fail "$label: GPL or nonfree licence string present"; fi
  dyn="$("$READELF" -d "$so")"
  soname="$(grep 'SONAME' <<<"$dyn" | grep -oE '\[[^]]+\]' | tr -d '[]' || true)"
  [[ "$soname" == "$name" ]] || fail "$label: SONAME is '$soname', expected '$name'"
}
check_jni_lib() {  # plain NEEDED entries and exported JNI symbols
  local so="$1" label="$2" need sym dyn needed syms
  dyn="$("$READELF" -d "$so")"
  needed="$(grep 'NEEDED' <<<"$dyn" || true)"
  for need in libavcodec.so libavutil.so libswresample.so; do
    grep -q "\[$need\]" <<<"$needed" || fail "$label: missing NEEDED $need"
  done
  if grep -qE '\[lib(avcodec|avutil|swresample)\.so\.[0-9]' <<<"$needed"; then fail "$label: versioned NEEDED entry (soname handling failed)"; fi
  syms="$("$NM" -D "$so")"
  for sym in "${JNI_SYMBOLS[@]}"; do
    grep -qE " T $sym\$" <<<"$syms" || fail "$label: does not export $sym"
  done
}

# --- run ------------------------------------------------------------------------------------------
for abi in $ABIS; do
  for lib in avutil swresample avcodec ffmpegJNI; do
    rel="jni/$abi/lib$lib.so"; so="$EXTRACTED/$rel"
    if [[ ! -f "$so" ]]; then fail "$abi: missing $rel"; continue; fi
    need_tools
    check_alignment "$so" "$rel"
    check_no_textrel "$so" "$rel"
    if [[ "$lib" == ffmpegJNI ]]; then check_jni_lib "$so" "$rel"; else check_ffmpeg_lib "$so" "$rel" "lib$lib.so"; fi
  done
  cfg="$OUT/$abi/config.h"; comp="$OUT/$abi/config_components.h"
  if [[ ! -f "$cfg" ]]; then fail "$abi: missing $cfg"; continue; fi
  # Per-component flags moved from config.h to config_components.h in FFmpeg 5.1.
  [[ -f "$comp" ]] || comp="$cfg"
  grep -qxF '#define FFMPEG_LICENSE "LGPL version 2.1 or later"' "$cfg" || fail "$abi: config.h licence is not LGPL-2.1+"
  for d in $DECODERS; do
    grep -qxF "#define CONFIG_$(printf '%s' "$d" | tr '[:lower:]' '[:upper:]')_DECODER 1" "$comp" \
      || fail "$abi: decoder '$d' is not enabled in $(basename "$comp")"
  done
done

if [[ -f "$EXTRACTED/classes.jar" ]]; then
  listing="$(unzip -l "$EXTRACTED/classes.jar")"
  for cls in FfmpegAudioRenderer FfmpegLibrary FfmpegAudioDecoder; do
    grep -q "androidx/media3/decoder/ffmpeg/$cls.class" <<<"$listing" || fail "classes.jar lacks $cls.class"
  done
else
  fail "missing classes.jar"
fi
if [[ -f "$EXTRACTED/proguard.txt" ]]; then
  grep -q 'growOutputBuffer' "$EXTRACTED/proguard.txt" || fail "proguard.txt lacks the growOutputBuffer keep rule"
else
  fail "missing proguard.txt"
fi

if [[ $FAILS -eq 0 ]]; then
  echo "verify: all checks passed ($(echo $ABIS | wc -w | tr -d ' ') ABIs, $(echo $DECODERS | wc -w | tr -d ' ') decoders, $ALIGN_HEX alignment, LGPL-2.1+)"
else
  echo "verify: FAILED ($FAILS problem(s))"
  exit 1
fi
