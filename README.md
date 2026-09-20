# media3-ffmpeg-lgpl

FFmpeg audio decoders for [Jetpack Media3](https://developer.android.com/media/media3) (ExoPlayer),
built from source **LGPL-only** and shipped as a single `.aar`. Plays DTS, DTS-HD, Dolby TrueHD,
AC-3, E-AC-3, Vorbis, Opus, FLAC, ALAC, µ-law and A-law where the device's hardware decoders cannot.

[![build](https://github.com/CHANGEME/media3-ffmpeg-lgpl/actions/workflows/build.yml/badge.svg)](https://github.com/CHANGEME/media3-ffmpeg-lgpl/actions/workflows/build.yml)

## Why this exists

media3 has an FFmpeg extension but does not publish it: you must build FFmpeg yourself. The one
ready-made alternative, `nextlib-media3ext`, is **GPL-3.0** - copyleft over any app that links it,
and widely held incompatible with the Google Play Developer Distribution Agreement.

This repository builds media3's own extension against an FFmpeg configured with
`--disable-gpl --disable-nonfree`. The result is **LGPL-2.1-or-later**, a licence an app can
comply with by showing a notice and shipping FFmpeg as the separate `.so` files it already is.
Every build checks that claim mechanically - see *What CI verifies* below.

## Use it

**1.** Download `media3-ffmpeg-lgpl-<version>.aar` from
[Releases](https://github.com/CHANGEME/media3-ffmpeg-lgpl/releases) into your app's `libs/`.

**2.** Depend on it, with the **exact** media3 version the AAR was built for (it is in the file
name and in `BUILD_RECORD.md`; the classes link against `@UnstableApi` internals, so a different
media3 version can fail at runtime):

```kotlin
dependencies {
    implementation(files("libs/media3-ffmpeg-lgpl-1.11.0-1.aar"))
    implementation("androidx.media3:media3-exoplayer:1.11.0")
}
```

**3.** Let `DefaultRenderersFactory` use it:

```kotlin
val player = ExoPlayer.Builder(context)
    .setRenderersFactory(
        DefaultRenderersFactory(context)
            .setExtensionRendererMode(DefaultRenderersFactory.EXTENSION_RENDERER_MODE_ON)
    )
    .build()
```

`EXTENSION_RENDERER_MODE_ON` uses FFmpeg only for formats the device cannot decode itself. Do
not use `EXTENSION_RENDERER_MODE_PREFER`: it routes hardware-decodable audio through software too,
costing battery for nothing.

That is the whole integration. `DefaultRenderersFactory` finds
`androidx.media3.decoder.ffmpeg.FfmpegAudioRenderer` by reflection, which is why this library keeps
media3's package name, and the ProGuard/R8 rules it needs travel inside the AAR.

## What is inside

| File | What | Licence |
|---|---|---|
| `classes.jar` | media3's `FfmpegAudioRenderer`, `FfmpegAudioDecoder`, `FfmpegLibrary` | Apache-2.0 |
| `jni/<abi>/libffmpegJNI.so` | media3's JNI bridge (`ffmpeg_jni.cc`) | Apache-2.0 |
| `jni/<abi>/libavcodec.so`, `libavutil.so`, `libswresample.so` | FFmpeg, decoders only | LGPL-2.1-or-later |
| `proguard.txt` | consumer keep rules | Apache-2.0 |

ABIs: `arm64-v8a`, `armeabi-v7a`, `x86_64`. Decoders, and the MIME types media3 routes to them:

| Decoder | MIME types |
|---|---|
| `ac3` | `audio/ac3` |
| `eac3` | `audio/eac3`, `audio/eac3-joc` |
| `truehd` | `audio/true-hd` |
| `dca` | `audio/vnd.dts`, `audio/vnd.dts.hd`, `audio/vnd.dts.hd;profile=lbr` |
| `vorbis` | `audio/vorbis` |
| `opus` | `audio/opus` |
| `flac` | `audio/flac` |
| `alac` | `audio/alac` |
| `pcm_mulaw`, `pcm_alaw` | `audio/g711-mlaw`, `audio/g711-alaw` |

AAC and MP3 are deliberately absent (every Android device decodes them in hardware), as is AMR.
The list is one line in `gradle.properties`; the smoke test asserts the built set matches it
exactly, positive and negative.

**Audio only.** media3's experimental FFmpeg *video* renderer is marked non-functional in its own
source and has no JNI behind it, so it is not included. Software video decoding is out of scope.

## What CI verifies on every build

Before anything is released, `ffmpeg/verify.sh` unpacks the AAR and fails unless:

- every FFmpeg library reports `license: LGPL version 2.1 or later` and none says GPL or nonfree
  (also checked in `config.h` **before** the compile starts);
- sonames are plain (`libavcodec.so`) and `libffmpegJNI.so` needs exactly those names;
- no library has text relocations;
- every `LOAD` segment of every library is **16 KB aligned** (Play requirement for native code);
- all nine JNI entry points are exported;
- every configured decoder is present in `config.h` for every ABI;
- the classes and the consumer ProGuard rules are in the AAR.

Then an instrumented test runs on an emulator with a **16 KB page-size** Android 15 image and
asserts the libraries load, report a version, and support exactly the configured formats.

`BUILD_RECORD.md` on each release records the FFmpeg tag and commit, NDK, the full `configure`
command per ABI, and SHA-256 of every file.

## Build it yourself

Linux or macOS (on Windows use WSL - FFmpeg's build does not run natively there). Needs `git`,
`make`, a JDK 21, and the Android NDK:

```bash
sdkmanager "ndk;27.2.12479018" "cmake;3.22.1" "platforms;android-36"
./ffmpeg/build.sh              # clones FFmpeg at the pinned tag, builds every ABI (~10-15 min)
./gradlew :lib:assembleRelease # links libffmpegJNI.so and packages the AAR
./ffmpeg/verify.sh             # the checks above
./ffmpeg/record.sh lib/build/outputs/aar/media3-ffmpeg-lgpl-release.aar 1.11.0-local
```

The AAR and its build record are then in `dist/`. `./gradlew :lib:publishToMavenLocal` publishes
it to `~/.m2` under the coordinates in `gradle.properties`.

Without an NDK you can still run the Java side and the script tests:
`./gradlew :lib:compileReleaseJavaWithJavac` and `bash ffmpeg/test/test_*.sh`.

## Versioning

Tags are `v<media3 version>-<n>`: `v1.11.0-1` is the first build for media3 1.11.0. The media3
version leads because it is the compatibility contract; `<n>` increments for an FFmpeg bump, a
decoder change or a fix. Pushing a tag builds, verifies, smoke-tests and publishes the release.

To bump media3: change `media3.version`, re-download the six upstream files from the new tag
(the JNI surface can change), re-apply the `FfmpegLibrary.java` load-order change, tag.

## What you owe when you ship it

The Apache-2.0 parts need attribution. The FFmpeg parts are LGPL-2.1-or-later, which means:

1. **Tell users** FFmpeg is included and under which licence, and make the licence text
   available in the app (a settings screen is the usual place). This repository's `NOTICE` and
   the LGPL text cover what to say.
2. **Keep it dynamically linked.** It already is: replacing the `.so` files with your own build is
   possible, which is what the licence requires.
3. **Be able to provide the corresponding source.** Point at the matching GitHub Release - it
   carries the FFmpeg source archive, the exact commit, and the configure options.
4. **State modifications.** There are none to FFmpeg. Say so.

**Codec patents are a separate question that no open-source licence answers.** AC-3, E-AC-3 and
TrueHD are Dolby's; DTS is Xperi's. Bundling your own software decoder is what creates the
exposure - hardware `MediaCodec` paths are licensed by the device maker. Trim `ffmpeg.decoders`
to what you need.

## Licence

Apache-2.0 for this repository's own code and for the media3 sources it packages (see `NOTICE`
for the exact files and the one modification). The FFmpeg binaries in the build output are
LGPL-2.1-or-later.
