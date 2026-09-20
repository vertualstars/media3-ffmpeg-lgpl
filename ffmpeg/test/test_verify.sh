#!/usr/bin/env bash
# Exercises verify.sh's structure and its config.h decoder check with a fake extracted AAR.
# No .so files exist in the fake, so readelf/nm/strings are never needed: runs anywhere.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
VERIFY="$ROOT/ffmpeg/verify.sh"
PROPS="$ROOT/gradle.properties"
prop() { grep -E "^$1=" "$PROPS" | head -n1 | cut -d= -f2- | tr -d '\r'; }
ABIS="$(prop ffmpeg.abis)"
DECODERS="$(prop ffmpeg.decoders)"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
EXTRACTED="$WORK/aar"
export FFMPEG_OUT_DIR="$WORK/out"
mkdir -p "$EXTRACTED"

# config.h (licence) and config_components.h (decoders, as FFmpeg 5.1+ lays them out) for every
# ABI, with the LAST configured decoder deliberately missing.
last="${DECODERS##* }"
for abi in $ABIS; do
  mkdir -p "$FFMPEG_OUT_DIR/$abi"
  echo '#define FFMPEG_LICENSE "LGPL version 2.1 or later"' > "$FFMPEG_OUT_DIR/$abi/config.h"
  {
    for d in $DECODERS; do
      [[ "$d" == "$last" ]] && continue
      echo "#define CONFIG_$(printf '%s' "$d" | tr '[:lower:]' '[:upper:]')_DECODER 1"
    done
  } > "$FFMPEG_OUT_DIR/$abi/config_components.h"
done

set +e
output="$("$VERIFY" --extracted "$EXTRACTED" 2>&1)"
status=$?
set -e

fails=0
must() {  # must <substring>
  if ! grep -qF -- "$1" <<<"$output"; then echo "FAIL: output lacks: $1"; fails=$((fails + 1)); fi
}
[[ $status -ne 0 ]] || { echo "FAIL: verify.sh exited 0 on a broken AAR"; fails=$((fails + 1)); }
for abi in $ABIS; do
  must "$abi: missing jni/$abi/libavutil.so"
  must "$abi: missing jni/$abi/libffmpegJNI.so"
  must "$abi: decoder '$last' is not enabled in config_components.h"
done
must "missing classes.jar"
must "missing proguard.txt"
must "verify: FAILED"

if [[ $fails -eq 0 ]]; then echo "test_verify: OK"; else echo "test_verify: $fails failure(s)"; echo "--- output ---"; echo "$output"; exit 1; fi
