#!/usr/bin/env bash
#
# media3-ffmpeg-lgpl: assemble dist/ for a release, including the build record LGPL-2.1 section 6
# requires us to be able to produce: what was built, from which sources, with which options.
#
#   ffmpeg/record.sh AAR VERSION
#
# Expects ffmpeg/verify.sh to have run (it extracts the AAR to build/verify/aar).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROPS="$ROOT/gradle.properties"
SRC="${FFMPEG_SRC_DIR:-$ROOT/ffmpeg/src}"
OUT="${FFMPEG_OUT_DIR:-$ROOT/ffmpeg/out}"
DIST="${DIST_DIR:-$ROOT/dist}"
EXTRACTED="${EXTRACTED_DIR:-$ROOT/build/verify/aar}"

die() { echo "ffmpeg/record.sh: $*" >&2; exit 1; }
prop() {
  local value
  value="$(grep -E "^$1=" "$PROPS" | head -n1 | cut -d= -f2- | tr -d '\r')"
  [[ -n "$value" ]] || die "missing '$1' in gradle.properties"
  printf '%s' "$value"
}
sha() { if command -v sha256sum >/dev/null; then sha256sum "$@"; else shasum -a 256 "$@"; fi; }

AAR="${1:-}"; VERSION="${2:-}"
[[ -f "$AAR" ]] || die "usage: record.sh <aar> <version> (AAR not found: '$AAR')"
[[ -n "$VERSION" ]] || die "usage: record.sh <aar> <version>"
[[ -d "$EXTRACTED/jni" ]] || die "no extracted AAR at $EXTRACTED - run ffmpeg/verify.sh first"
[[ -d "$SRC/.git" ]] || die "FFmpeg checkout not found at $SRC - run ffmpeg/build.sh first"
[[ -f "$OUT/ffmpeg-commit.txt" ]] || die "missing $OUT/ffmpeg-commit.txt - run ffmpeg/build.sh first"

MEDIA3="$(prop media3.version)"; TAG="$(prop ffmpeg.tag)"; DECODERS="$(prop ffmpeg.decoders)"
ABIS="$(prop ffmpeg.abis)"; PAGE_SIZE="$(prop ffmpeg.pageSize)"; NDK_VERSION="$(prop ndk.version)"
CMAKE_VERSION="$(prop cmake.version)"; ARTIFACT="$(prop publish.artifact)"
COMMIT="$(tr -d '\r\n' < "$OUT/ffmpeg-commit.txt")"

# The NDK's own revision string when it is around; the pinned version otherwise.
NDK_REV="$NDK_VERSION"
for ndk in "${ANDROID_NDK_HOME:-}" "${ANDROID_HOME:-}/ndk/$NDK_VERSION" "${ANDROID_SDK_ROOT:-}/ndk/$NDK_VERSION"; do
  if [[ -n "$ndk" && -f "$ndk/source.properties" ]]; then
    NDK_REV="$(grep -E '^Pkg.Revision' "$ndk/source.properties" | cut -d= -f2- | tr -d ' \r')"; break
  fi
done

mkdir -p "$DIST"
AAR_NAME="$ARTIFACT-$VERSION.aar"
cp "$AAR" "$DIST/$AAR_NAME"
cp "$ROOT/NOTICE" "$ROOT/LICENSE" "$DIST/"

TARBALL="ffmpeg-$TAG-src.tar.gz"
git -C "$SRC" archive --format=tar.gz --prefix="ffmpeg-$TAG/" -o "$DIST/$TARBALL" HEAD

{
  echo "# Build record - $ARTIFACT $VERSION"
  echo
  echo "Generated $(date -u +%Y-%m-%dT%H:%M:%SZ). This is the record LGPL-2.1 section 6 requires: what"
  echo "was built, from which unmodified sources, with which options. Keep it with the release."
  echo
  echo "| Field | Value |"
  echo "|---|---|"
  echo "| Artifact | \`$AAR_NAME\` |"
  echo "| Jetpack Media3 | $MEDIA3 (the AAR must be used with exactly this version) |"
  echo "| FFmpeg tag | \`$TAG\` |"
  echo "| FFmpeg commit | \`$COMMIT\` |"
  echo "| FFmpeg source | https://github.com/FFmpeg/FFmpeg/tree/$TAG (mirror of https://git.ffmpeg.org/ffmpeg.git), unmodified; \`$TARBALL\` in this release is \`git archive\` of that commit |"
  echo "| Licence | LGPL-2.1-or-later (\`--disable-gpl --disable-nonfree --disable-version3\`) |"
  echo "| Android NDK | $NDK_REV |"
  echo "| CMake | $CMAKE_VERSION |"
  echo "| Page size | $PAGE_SIZE bytes (\`-Wl,-z,max-page-size=$PAGE_SIZE\` on every library) |"
  echo "| ABIs | $ABIS |"
  echo "| Decoders | $DECODERS |"
  if [[ -n "${GITHUB_REPOSITORY:-}" ]]; then
    echo "| Built by | GitHub Actions run ${GITHUB_RUN_ID:-?} of $GITHUB_REPOSITORY at commit ${GITHUB_SHA:-?} (ref ${GITHUB_REF_NAME:-?}) |"
  else
    echo "| Built by | local build on $(uname -s) |"
  fi
  echo
  for abi in $ABIS; do
    echo "## $abi"
    echo
    echo "Licence line from \`config.h\`: \`$(grep -F 'FFMPEG_LICENSE' "$OUT/$abi/config.h" | tr -d '\r')\`"
    echo
    echo '```'
    tr -d '\r' < "$OUT/$abi/configure.cmd"
    echo '```'
    echo
  done
  echo "## SHA-256"
  echo
  echo '```'
  ( cd "$DIST" && sha "$AAR_NAME" "$TARBALL" )
  ( cd "$EXTRACTED" && find jni -name '*.so' | sort | while read -r f; do sha "$f"; done )
  echo '```'
} > "$DIST/BUILD_RECORD.md"

{
  ( cd "$DIST" && sha "$AAR_NAME" "$TARBALL" )
  ( cd "$EXTRACTED" && find jni -name '*.so' | sort | while read -r f; do sha "$f"; done )
} > "$DIST/SHA256SUMS"

cat > "$DIST/ffmpeg-corresponding-source.txt" <<EOF
Corresponding source for the FFmpeg libraries in $AAR_NAME
(libavutil.so, libswresample.so, libavcodec.so), per LGPL-2.1 section 6:

  Project:   FFmpeg - https://ffmpeg.org
  Tag:       $TAG
  Commit:    $COMMIT
  Obtained:  https://github.com/FFmpeg/FFmpeg (mirror of https://git.ffmpeg.org/ffmpeg.git)
  Modified:  no. Built from the unmodified tree with the configure options in BUILD_RECORD.md.
  Archive:   $TARBALL in this release (git archive of the commit above).

libffmpegJNI.so is media3's JNI bridge (Apache-2.0); its source is lib/src/main/jni/ffmpeg_jni.cc
in the repository this release was built from. FFmpeg is linked dynamically, so it can be replaced
by any compatible build without relinking the bridge.
EOF

echo "record: wrote $DIST ($AAR_NAME, BUILD_RECORD.md, SHA256SUMS, $TARBALL)"
