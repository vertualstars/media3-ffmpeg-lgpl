#!/usr/bin/env bash
# record.sh against fake inputs: a one-commit "FFmpeg" repo, fake out/ metadata, a fake AAR.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
RECORD="$ROOT/ffmpeg/record.sh"
PROPS="$ROOT/gradle.properties"
prop() { grep -E "^$1=" "$PROPS" | head -n1 | cut -d= -f2- | tr -d '\r'; }
ABIS="$(prop ffmpeg.abis)"
TAG="$(prop ffmpeg.tag)"
ARTIFACT="$(prop publish.artifact)"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
export FFMPEG_SRC_DIR="$WORK/src" FFMPEG_OUT_DIR="$WORK/out" DIST_DIR="$WORK/dist" EXTRACTED_DIR="$WORK/aar"

mkdir -p "$FFMPEG_SRC_DIR" && cd "$FFMPEG_SRC_DIR"
git init -q && echo "fake" > configure && git add configure
git -c user.email=t@t -c user.name=t commit -q -m "fake ffmpeg"
COMMIT="$(git rev-parse HEAD)"
cd "$ROOT"

mkdir -p "$FFMPEG_OUT_DIR"
printf '%s\n' "$COMMIT" > "$FFMPEG_OUT_DIR/ffmpeg-commit.txt"
printf '%s\n' "$TAG" > "$FFMPEG_OUT_DIR/ffmpeg-tag.txt"
for abi in $ABIS; do
  mkdir -p "$FFMPEG_OUT_DIR/$abi" "$EXTRACTED_DIR/jni/$abi"
  echo "./configure --target-os=android --prefix=/x/$abi --disable-gpl" > "$FFMPEG_OUT_DIR/$abi/configure.cmd"
  echo '#define FFMPEG_LICENSE "LGPL version 2.1 or later"' > "$FFMPEG_OUT_DIR/$abi/config.h"
  for lib in avutil swresample avcodec ffmpegJNI; do echo "$abi-$lib" > "$EXTRACTED_DIR/jni/$abi/lib$lib.so"; done
done
echo "not really an aar" > "$WORK/fake.aar"

"$RECORD" "$WORK/fake.aar" 9.9.9-test

fails=0
has() { [[ -f "$DIST_DIR/$1" ]] || { echo "FAIL: missing dist/$1"; fails=$((fails + 1)); }; }
has "$ARTIFACT-9.9.9-test.aar"
has BUILD_RECORD.md
has SHA256SUMS
has ffmpeg-corresponding-source.txt
has "ffmpeg-$TAG-src.tar.gz"
has NOTICE
has LICENSE
rec="$DIST_DIR/BUILD_RECORD.md"
for needle in "$TAG" "$COMMIT" "$(prop ffmpeg.decoders)" "--disable-gpl" "LGPL version 2.1 or later" "9.9.9-test"; do
  grep -qF -- "$needle" "$rec" || { echo "FAIL: BUILD_RECORD.md lacks: $needle"; fails=$((fails + 1)); }
done
# One checksum line per shipped .so, plus the AAR and the tarball.
n_so="$(find "$EXTRACTED_DIR/jni" -name '*.so' | wc -l | tr -d ' ')"
n_sums="$(grep -c . "$DIST_DIR/SHA256SUMS")"
[[ "$n_sums" -eq $((n_so + 2)) ]] || { echo "FAIL: SHA256SUMS has $n_sums lines, expected $((n_so + 2))"; fails=$((fails + 1)); }
grep -qF "$COMMIT" "$DIST_DIR/ffmpeg-corresponding-source.txt" || { echo "FAIL: source note lacks commit"; fails=$((fails + 1)); }

if [[ $fails -eq 0 ]]; then echo "test_record: OK"; else echo "test_record: $fails failure(s)"; exit 1; fi
