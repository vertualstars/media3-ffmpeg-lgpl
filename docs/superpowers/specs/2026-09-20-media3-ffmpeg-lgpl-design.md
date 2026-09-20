# media3-ffmpeg-lgpl — design

Written for: the implementer of this repository, and anyone later asking "why is it built this
way". Approved design as of 2026-09-20.

## 1. Purpose

Produce a drop-in Android library (`.aar`) that gives Jetpack Media3 / ExoPlayer software audio
decoding for DTS, TrueHD, AC-3/E-AC-3 and friends through FFmpeg — built **LGPL-only**, from
source, reproducibly, in CI — so that an app can ship it on Google Play without a copyleft
problem.

It exists because the only ready-made option, `io.github.anilbeesetti:nextlib-media3ext`, is
GPL-3.0, which is copyleft over any app that links it and is widely held incompatible with the Play
Developer Distribution Agreement. DV Player currently depends on it and its release build refuses
to run until it is replaced. This repository is the replacement, and it is public so that anyone
in the same position can use it.

## 2. Decisions (approved)

| Question | Decision |
|---|---|
| Approach | Wrap media3's own `decoder_ffmpeg` extension (Apache-2.0); do not write a new JNI bridge |
| Linking | FFmpeg as **shared** libraries (`libavutil.so`, `libswresample.so`, `libavcodec.so`) + `libffmpegJNI.so` |
| Distribution | **GitHub Releases** (AAR + build record). `maven-publish` wired so `publishToMavenLocal` works; Maven Central is a later config change |
| Name | `media3-ffmpeg-lgpl` (repo, artifact, directory) |
| Licence of this repository's own code | Apache-2.0 (matches media3; anyone can use it) |
| Build host | GitHub Actions, `ubuntu-24.04`. Local builds supported on Linux/macOS/WSL |
| Toolchain | AGP 9.2.1, Gradle 9.4.1, JDK 21 — identical to DV Player, so the Gradle side is verifiable on the developer machine today |

## 3. Non-goals

- **Software video decoding.** media3 1.11.0's `ExperimentalFfmpegVideoRenderer` is marked "not
  yet functional" in its own source and has no JNI behind it. It is not copied. What nextlib
  offered for unusual video codecs is not recoverable through this design.
- Encoders, muxers, demuxers, filters, swscale, avformat. None are needed by the JNI; all are
  disabled, which is also what keeps the binary small and the patent surface narrow.
- Maven Central publishing in v1 (scaffolded, not finished — needs the owner's Sonatype account).
- Windows-native FFmpeg builds. Use WSL or CI.

## 4. Facts the design rests on (all verified against the real files)

- media3 tag `1.11.0`, module `libraries/decoder_ffmpeg`: 6 Java files (one of them the
  non-functional experimental video renderer, see §3) + `ffmpeg_jni.cc` (432 lines) +
  `CMakeLists.txt` + `build_ffmpeg.sh` + `proguard-rules.txt`.
- `ffmpeg_jni.cc` uses the modern channel-layout API (`ch_layout`, `av_channel_layout_default`,
  `swr_alloc_set_opts2`) → compatible with FFmpeg 7.x. It includes only `libavcodec`,
  `libavutil` and `libswresample`.
- FFmpeg `configure` at `n7.1.5`, `--target-os=android` case: sets `SLIB_INSTALL_NAME='$(SLIBNAME)'`,
  `SLIB_INSTALL_LINKS=` and `SHFLAGS='-shared -Wl,-soname,$(SLIBNAME)'` → shared libraries are
  named and soname'd plainly (`libavcodec.so`, no version suffix). **No `configure` patching.**
- With `--target-os=android`, `cc_default="clang"` and it is prefixed by `--cross-prefix`, so
  `--cross-prefix=<ndk>/bin/aarch64-linux-android24-` resolves to the NDK's clang wrapper.
- Every flag listed in §7.1 exists in `n7.1.5`'s `configure`; unknown flags make it die.
  `--disable-gpl`, `--disable-nonfree`, `--disable-version3` are valid (LICENSE_LIST ⊂ CONFIG_LIST).
  `--disable-postproc` is valid in 7.x (libpostproc was removed in 8.0 — do not blindly bump).
- `FFMPEG_LICENSE` is written into `config.h`; every library exposes it via `strings` as
  `libavcodec license: LGPL version 2.1 or later`.
- `media3-common` 1.11.0 exposes `guava:33.3.1-android` as `compile` (api) scope and
  **excludes `checker-qual`** — so guava's `Preconditions` is on the compile classpath
  transitively but `@MonotonicNonNull` is not; `checker-qual` must be declared.
- `androidx.media3.common.util.LibraryLoader(String... libraries)` loads its arguments in order
  inside `isAvailable()`.
- media3's `DefaultRenderersFactory` locates the renderer by reflection on the exact class name
  `androidx.media3.decoder.ffmpeg.FfmpegAudioRenderer`; its consumer ProGuard rules keep that
  constructor. Keeping the package name is what makes integration a one-line change.
- sdkmanager package strings verified present: `ndk;27.3.13750724`, `cmake;3.22.1`,
  `system-images;android-35;google_apis_ps16k;x86_64`.
- `ReactiveCircus/android-emulator-runner@v2` passes `target` through unvalidated (it has a
  `ps16k` shorthand), so a 16 KB-page image can be used for the smoke test.

## 5. Repository layout

```
media3-ffmpeg-lgpl/
├── .github/workflows/build.yml
├── .gitignore
├── LICENSE                         Apache-2.0 — this repository's own code
├── NOTICE                          attribution: media3 (Apache-2.0, 1 file modified), FFmpeg (LGPL-2.1+)
├── README.md
├── gradle.properties               single source of truth for every version and list (§6)
├── settings.gradle.kts             mirrors DV Player (google() content filter, foojay toolchain plugin)
├── build.gradle.kts                plugins { com.android.library 9.2.1 apply false }
├── gradlew, gradlew.bat, gradle/wrapper/*, gradle/gradle-daemon-jvm.properties   copied verbatim from DV Player
├── ffmpeg/
│   ├── build.sh                    fetch + configure + build FFmpeg per ABI (§7.1)
│   ├── verify.sh                   post-build checks on the AAR, fails on any miss (§7.6)
│   ├── record.sh                   BUILD_RECORD.md + SHA256SUMS (§7.7)
│   ├── src/                        FFmpeg checkout   (gitignored)
│   └── out/<abi>/{lib,include,config.h,configure.cmd}   (gitignored)
├── lib/
│   ├── build.gradle.kts            com.android.library + maven-publish (§7.2)
│   ├── consumer-rules.pro          (§7.5)
│   ├── src/main/AndroidManifest.xml            `<manifest />`
│   ├── src/main/java/androidx/media3/decoder/ffmpeg/
│   │   ├── FfmpegAudioDecoder.java             upstream, unmodified
│   │   ├── FfmpegAudioRenderer.java            upstream, unmodified
│   │   ├── FfmpegDecoderException.java         upstream, unmodified
│   │   ├── FfmpegLibrary.java                  upstream, MODIFIED (load order) — notice in header
│   │   └── package-info.java                   upstream, unmodified
│   ├── src/main/jni/CMakeLists.txt             ours (§7.3)
│   ├── src/main/jni/ffmpeg_jni.cc              upstream, unmodified
│   ├── src/main/jniLibs/<abi>/*.so             (gitignored; written by ffmpeg/build.sh)
│   └── src/androidTest/java/androidx/media3/decoder/ffmpeg/FfmpegLibrarySmokeTest.java  (§7.8)
└── docs/superpowers/specs/         this document
```

## 6. Single source of truth — `gradle.properties`

Read by Gradle natively and by the shell scripts with `grep '^key=' gradle.properties`.

```
media3.version=1.11.0
ffmpeg.tag=n7.1.5
ffmpeg.decoders=ac3 eac3 truehd dca vorbis opus flac alac pcm_mulaw pcm_alaw
ffmpeg.abis=arm64-v8a armeabi-v7a x86_64
ffmpeg.pageSize=16384
ndk.version=27.3.13750724
cmake.version=3.22.1
lib.minSdk=24
lib.compileSdk=36
publish.group=io.github.CHANGEME
publish.artifact=media3-ffmpeg-lgpl
publish.version=1.11.0-SNAPSHOT
android.useAndroidX=true
org.gradle.jvmargs=-Xmx2g -Dfile.encoding=UTF-8
```

Keys are deliberately not prefixed `android.` (AGP owns that prefix). The decoder list is the
set media3's `FfmpegLibrary.getCodecName()` can route to, minus AAC/MP3 (hardware everywhere) and
AMR (rare). `x86` is omitted; `x86_64` is emulator-only and built with `--disable-asm`, which
also removes the need for nasm.

## 7. Component contracts

### 7.1 `ffmpeg/build.sh`

Inputs: `gradle.properties`; NDK located from `$ANDROID_NDK_HOME`, else
`$ANDROID_HOME/ndk/<ndk.version>`, else `$ANDROID_SDK_ROOT/ndk/<ndk.version>`. Host tag from
`uname -s` (Linux → `linux-x86_64`, Darwin → `darwin-x86_64`; anything else exits with "use WSL
or CI").

Steps:
1. `git clone --depth 1 --branch <ffmpeg.tag> https://github.com/FFmpeg/FFmpeg.git ffmpeg/src`
   (reused if already at that tag). Record `git rev-parse HEAD` to `ffmpeg/out/ffmpeg-commit.txt`.
2. For each ABI in `ffmpeg.abis`, in `ffmpeg/src`: `make distclean` (ignore failure), then
   `./configure` with:

   ```
   --target-os=android --enable-cross-compile
   --prefix=<repo>/ffmpeg/out/<abi>
   --cross-prefix=<ndk>/toolchains/llvm/prebuilt/<host>/bin/<triple><minSdk>-
   --nm=…/llvm-nm --ar=…/llvm-ar --ranlib=…/llvm-ranlib --strip=…/llvm-strip
   --arch=<a> --cpu=<c>                       arm64-v8a: aarch64/armv8-a · armeabi-v7a: arm/armv7-a · x86_64: x86_64/x86-64
   --enable-shared --disable-static --enable-pic
   --disable-gpl --disable-nonfree --disable-version3
   --disable-doc --disable-programs --disable-everything
   --disable-avdevice --disable-avformat --disable-swscale --disable-postproc --disable-avfilter
   --enable-swresample
   --disable-symver --disable-v4l2-m2m --disable-vulkan
   --enable-decoder=<d> …                     one per entry in ffmpeg.decoders
   --extra-ldflags="<abi extras> -Wl,-z,max-page-size=<pageSize> -Wl,-z,text"
   --extra-ldsoflags="-Wl,-z,max-page-size=<pageSize> -Wl,-z,text"
   --extra-ldexeflags=-pie
   ```
   ABI extras, taken from upstream `build_ffmpeg.sh`: armeabi-v7a adds
   `--extra-cflags="-march=armv7-a -mfloat-abi=softfp"` and `-Wl,--fix-cortex-a8` in ldflags;
   x86_64 adds `--disable-asm`. Triples: `aarch64-linux-android`, `armv7a-linux-androideabi`,
   `x86_64-linux-android`. The exact command line is saved to `ffmpeg/out/<abi>/configure.cmd`.
3. **Fail fast before compiling:** `config.h` must contain
   `#define FFMPEG_LICENSE "LGPL version 2.1 or later"`, `#define CONFIG_GPL 0`,
   `#define CONFIG_NONFREE 0`, and `#define CONFIG_<DECODER>_DECODER 1` for every requested
   decoder. Copy `config.h` to `ffmpeg/out/<abi>/config.h`.
4. `make -j$(nproc)` then `make install` (libs + headers into the prefix; programs and docs are
   disabled so nothing else is installed).
5. Copy `ffmpeg/out/<abi>/lib/{libavutil,libswresample,libavcodec}.so` to
   `lib/src/main/jniLibs/<abi>/`. Fail if any is missing.

`-Wl,-z,text` makes the link fail on text relocations instead of producing a library Android
refuses to load; `--disable-asm` on x86_64 is what keeps that flag satisfiable there.

### 7.2 `lib/build.gradle.kts`

- `com.android.library` + `maven-publish`. `namespace = "androidx.media3.decoder.ffmpeg"`.
- `compileSdk`, `minSdk`, `ndkVersion` from properties. `defaultConfig.ndk.abiFilters` = the ABI
  list, so CMake never configures an ABI that has no FFmpeg build.
- `externalNativeBuild.cmake` is configured **only if** `lib/src/main/jniLibs/<abi>/libavcodec.so`
  exists for every ABI, so `./gradlew help` and IDE sync work on a machine without FFmpeg. A
  `preBuild.doFirst` check turns any real build attempt without FFmpeg into a clear
  "run ffmpeg/build.sh first" failure rather than an empty AAR.
- CMake arguments: `-DANDROID_STL=c++_static`, `-DANDROID_SUPPORT_FLEXIBLE_PAGE_SIZES=ON`,
  `-DFFMPEG_OUT_DIR=<abs>`, `-DFFMPEG_JNILIBS_DIR=<abs>`, `-DFFMPEG_PAGE_SIZE=<ffmpeg.pageSize>`
  — so the page size has one definition, in `gradle.properties`, for both FFmpeg and the JNI lib.
- `buildFeatures.buildConfig = true` with `FFMPEG_DECODERS` and `FFMPEG_TAG` string fields, so
  the smoke test reads the configured list instead of duplicating it.
- Java 11 source/target. `base.archivesName = media3-ffmpeg-lgpl` →
  `lib/build/outputs/aar/media3-ffmpeg-lgpl-release.aar`.
- Dependencies: `api media3-exoplayer`, `api media3-decoder`, `api media3-common` (all
  `media3.version`); `implementation androidx.annotation:annotation:1.9.1`;
  `compileOnly org.checkerframework:checker-qual:4.2.3`; `androidTestImplementation
  androidx.test.ext:junit:1.3.0`, `androidx.test:runner:1.7.0` (ext:junit does not pull the
  runner in; without it the test APK cannot even start) and `junit:junit:4.13.2`.
- Publishing: `singleVariant("release") { withSourcesJar() }`; one `MavenPublication` from
  `components["release"]` with group/artifact/version from properties and a POM carrying name,
  description, Apache-2.0 licence, and an explicit note that the binary contains LGPL FFmpeg.
  `publishToMavenLocal` works out of the box; nothing else is published in v1.

### 7.3 `lib/src/main/jni/CMakeLists.txt`

```cmake
cmake_minimum_required(VERSION 3.21.0 FATAL_ERROR)
project(libffmpegJNI C CXX)
set(CMAKE_CXX_STANDARD 11)
# FFMPEG_OUT_DIR / FFMPEG_JNILIBS_DIR arrive from Gradle; fail loudly if absent.
set(ffmpeg_include "${FFMPEG_OUT_DIR}/${ANDROID_ABI}/include")     # per-ABI: avconfig.h differs
set(ffmpeg_libs    "${FFMPEG_JNILIBS_DIR}/${ANDROID_ABI}")
foreach(lib avutil swresample avcodec)                               # FATAL_ERROR if lib${lib}.so missing
add_library(ffmpegJNI SHARED ffmpeg_jni.cc)
target_include_directories(ffmpegJNI PRIVATE "${ffmpeg_include}")
target_link_directories(ffmpegJNI PRIVATE "${ffmpeg_libs}")
target_link_libraries(ffmpegJNI PRIVATE android avcodec swresample avutil log)   # by name → -lavcodec → DT_NEEDED libavcodec.so
target_link_options(ffmpegJNI PRIVATE "-Wl,-z,max-page-size=${FFMPEG_PAGE_SIZE}" "-Wl,-z,text")
if(ANDROID_ABI STREQUAL "arm64-v8a") target_link_options(ffmpegJNI PRIVATE "-Wl,-Bsymbolic")   # upstream, ExoPlayer #9933
```

Linking **by name against the jniLibs directory** rather than through `IMPORTED` targets is
deliberate: AGP auto-packages imported shared targets, and combining that with `jniLibs` would
produce duplicate-file failures. With this shape `jniLibs` is the only packaging path and CMake
merely links.

### 7.4 Java sources

Copied byte-for-byte from androidx/media at tag 1.11.0, Apache-2.0 headers intact, except:

**`FfmpegLibrary.java`** — `new LibraryLoader("ffmpegJNI")` becomes
`new LibraryLoader("avutil", "swresample", "avcodec", "ffmpegJNI")`. Android's linker resolves
`DT_NEEDED` from the app's own library directory on API 23+, but loading the dependencies
explicitly, in dependency order, removes the one runtime path that could differ across OEM
linkers. A comment block at the top of the file states that and what changed (Apache-2.0 §4(b)).

`ExperimentalFfmpegVideoRenderer.java` is not copied (§3).

### 7.5 `lib/consumer-rules.pro`

Upstream's `proguard-rules.txt` verbatim — native method names, and the keep for
`FfmpegAudioDecoder.growOutputBuffer(SimpleDecoderOutputBuffer, int)`, which is **called from
native code** and would otherwise be stripped — plus explicit keeps for the three public classes.
Shipped as consumer rules so every app that uses the AAR gets them without knowing they exist.

### 7.6 `ffmpeg/verify.sh`

Runs after `assembleRelease`. Unzips the AAR to `dist/aar/` and fails on the first miss:

| Check | Tool | Pass condition |
|---|---|---|
| Files present | `ls` | `jni/<abi>/lib{avutil,swresample,avcodec,ffmpegJNI}.so` for every ABI; `classes.jar`; `proguard.txt` |
| Licence | `strings` | each FFmpeg `.so` contains `license: LGPL version 2.1 or later` and **no** `GPL version 2` / `GPL version 3` / `nonfree` |
| SONAME | `llvm-readelf -d` | FFmpeg libs: `Library soname: [libavcodec.so]` etc. — no version suffix |
| NEEDED | `llvm-readelf -d` | `libffmpegJNI.so` needs `libavcodec.so`, `libavutil.so`, `libswresample.so` — plain names only |
| No text relocations | `llvm-readelf -d` | no `TEXTREL` in any `.so` |
| 16 KB pages | `llvm-readelf -l` | every `LOAD` segment `Align` is `0x4000` in every `.so` |
| JNI exports | `llvm-nm -D` | `libffmpegJNI.so` exports all 9 `Java_androidx_media3_decoder_ffmpeg_*` symbols |
| Decoders | `config.h` | `CONFIG_<D>_DECODER 1` for every requested decoder, per ABI |
| Classes | `unzip -l classes.jar` | `androidx/media3/decoder/ffmpeg/FfmpegAudioRenderer.class`, `FfmpegLibrary.class`, `FfmpegAudioDecoder.class` |
| Consumer rules | `grep` | `proguard.txt` contains `growOutputBuffer` |

Tools come from the NDK's `toolchains/llvm/prebuilt/<host>/bin`, falling back to system
`readelf`/`nm`/`strings`.

### 7.7 `ffmpeg/record.sh`

Writes `dist/BUILD_RECORD.md` — the LGPL-2.1 §6 record — and `dist/SHA256SUMS`:

FFmpeg tag and commit; media3 version; NDK version (`Pkg.Revision` from `source.properties`);
CMake version; decoders; ABIs; page size; per ABI the full `configure` command and the
`FFMPEG_LICENSE` line from `config.h`; SHA-256 of every `.so` inside the AAR and of the AAR;
build date; `GITHUB_REPOSITORY`/`GITHUB_SHA`/`GITHUB_RUN_ID` when present. Also writes
`dist/ffmpeg-corresponding-source.txt` naming the exact upstream tag, commit and URL, and states
that the sources are unmodified.

### 7.8 Smoke test — `FfmpegLibrarySmokeTest.java`

Instrumented, same package as the library so it can call package-private
`FfmpegLibrary.getCodecName()`:

- `isAvailable()` is true; `getVersion()` is non-null and non-empty.
- For every MIME type in media3's routing table (AC3, E_AC3, E_AC3_JOC, TRUEHD, DTS, DTS_EXPRESS,
  DTS_HD, VORBIS, OPUS, FLAC, ALAC, MLAW, ALAW, AAC, MPEG, AMR_NB, AMR_WB):
  `supportsFormat(mime) == BuildConfig.FFMPEG_DECODERS.contains(getCodecName(mime))`.
  That asserts the enabled set is **exactly** what was configured — a decoder that was silently
  dropped fails, and one that crept in fails too.

Runs on `system-images;android-35;google_apis_ps16k;x86_64` — a **16 KB-page** kernel — so
"loads and works on 16 KB devices" is demonstrated, not inferred from `readelf`.

## 8. CI — `.github/workflows/build.yml`

Triggers: push to `main`, tags `v*`, pull requests, `workflow_dispatch`. No secrets required.

**Job `build`** (`ubuntu-24.04`): checkout → `actions/setup-java@v4` (temurin 21) →
`android-actions/setup-android@v3` → `sdkmanager --install "ndk;…" "cmake;…" "platforms;android-36"`
→ `gradle/actions/setup-gradle@v4` → `ffmpeg/build.sh` → `./gradlew :lib:assembleRelease` →
`ffmpeg/verify.sh` → `ffmpeg/record.sh` → copy AAR to `dist/media3-ffmpeg-lgpl-<version>.aar` →
`git -C ffmpeg/src archive` the FFmpeg source to `dist/ffmpeg-<tag>-src.tar.gz` → upload
artifacts `aar` (dist/) and `ffmpeg-native` (`lib/src/main/jniLibs` + `ffmpeg/out/*/include` +
`ffmpeg/out/*/config.h`).

`<version>` is `${GITHUB_REF_NAME#v}` on a tag, else `publish.version` from properties; passed to
Gradle as `-Ppublish.version=`.

**Job `smoke`** (`needs: build`): checkout → setup-java/android/gradle → download `ffmpeg-native`
into place → enable KVM (udev rule) → `reactivecircus/android-emulator-runner@v2` with
`api-level: 35`, `target: google_apis_ps16k`, `arch: x86_64`, headless options →
`./gradlew :lib:connectedDebugAndroidTest` → upload test reports on failure.

**Job `release`** (`needs: [build, smoke]`, `if: startsWith(github.ref, 'refs/tags/v')`,
`permissions: contents: write`): download `aar` → `softprops/action-gh-release@v2` attaching the
AAR, `BUILD_RECORD.md`, `SHA256SUMS`, `ffmpeg-corresponding-source.txt`, the FFmpeg source
tarball, and `NOTICE`.

## 9. Versioning and release

Tag scheme `v<media3 version>-<n>`, e.g. `v1.11.0-1`. The media3 version is the compatibility
contract — the AAR links against `@UnstableApi` internals and must be used with **exactly** that
media3 version — so it leads. `<n>` increments for rebuilds (FFmpeg bump, decoder change, fix).
The FFmpeg version is inside `BUILD_RECORD.md` and `BuildConfig.FFMPEG_TAG`.

Bumping media3: change `media3.version`, re-copy the six upstream files from the new tag (the
JNI surface can change between versions), tag `v<new>-1`.

## 10. Licensing and attribution

- `LICENSE` — Apache-2.0. Covers everything in this repository that is ours: scripts, CMake,
  Gradle, CI, docs, the smoke test.
- `NOTICE` — states that `lib/src/main/java/**` and `ffmpeg_jni.cc` are from Jetpack Media3
  (Apache-2.0, copyright The Android Open Source Project) at tag 1.11.0, that `FfmpegLibrary.java`
  is modified and how; and that the build output contains FFmpeg (LGPL-2.1-or-later), fetched
  unmodified from upstream at the recorded tag, configured `--disable-gpl --disable-nonfree`.
- README "What you owe when you ship this" — for consumers: show FFmpeg's LGPL notice and text
  in-app, keep it dynamically linked (it is), be able to hand over `BUILD_RECORD.md` and the
  source tarball on request, and note that **codec patents are a separate matter** (Dolby for
  AC-3/E-AC-3/TrueHD, Xperi for DTS) that no open-source licence settles.

## 11. Consumer integration

Generic:
```kotlin
implementation(files("libs/media3-ffmpeg-lgpl-1.11.0-1.aar"))
implementation("androidx.media3:media3-exoplayer:1.11.0")   // must match the AAR's media3 version exactly
```
and build the player with
`DefaultRenderersFactory(context).setExtensionRendererMode(EXTENSION_RENDERER_MODE_ON)` —
`FfmpegAudioRenderer` is found by reflection. `EXTENSION_RENDERER_MODE_PREFER` would route
hardware-supported audio through software too; do not.

DV Player specifically (follow-up after the first release exists, not part of this repo):
remove `nextlib-media3ext` from `gradle/libs.versions.toml` and `app/build.gradle.kts`; add the
AAR; in `PlayerViewModel.buildPlayer()` replace `NextRenderersFactory(...)` with
`DefaultRenderersFactory(...)`, keeping `EXTENSION_RENDERER_MODE_ON`; update the FFmpeg version
string in `OpenSourceLicenses.kt` and fill in `licensing/README.md`'s build record from
`BUILD_RECORD.md`. Removing nextlib is also what switches off the app's release guard.

## 12. Verification matrix

| Claim | Proven by |
|---|---|
| No GPL code in the binary | `config.h` gate before compile; `strings` on every `.so` after |
| FFmpeg unmodified | Source is a fresh clone at a recorded commit; tarball attached to the release |
| Relinkable (LGPL §6) | Separate shared libraries with plain sonames; `NEEDED` check |
| 16 KB page size | `readelf` `LOAD` alignment on every `.so`, **and** the smoke test boots a 16 KB-page image |
| Loads on Android | smoke test `isAvailable()` |
| Decoder set is exactly as configured | smoke test asserts positive **and** negative cases from `BuildConfig` |
| Nothing stripped by R8 | consumer rules shipped in the AAR, checked present |
| Gradle side is sane | verifiable locally today with the copied wrapper (`./gradlew help`, and `assembleRelease` fails with the intended "build FFmpeg first" message) |
| Native side is sane | first CI run — there is no NDK on the developer machine; this is stated, not hidden |

## 13. Risks and fallbacks

| Risk | Mitigation / fallback |
|---|---|
| FFmpeg `configure` rejects a flag on first CI run | Every flag was grepped in the real `n7.1.5` configure; `configure.cmd` and `ffbuild/config.log` are uploaded as artifacts on failure |
| Text relocations on armv7 asm | `-Wl,-z,text` fails the link; fallback is `--disable-asm` for armv7 (slower, still correct) |
| AGP does not package `jniLibs` as expected | `verify.sh` "files present" check catches it; fallback is `sourceSets.main.jniLibs.srcDirs` |
| Emulator job flaky / ps16k image unavailable | `smoke` is a separate job so the AAR artifact still exists; fallback image `android-35;google_apis` |
| AGP 9 CMake/NDK integration quirk | Toolchain is the one DV Player already builds with; CMake pinned to 3.22.1 which AGP has supported for years |
| Upstream JNI surface changes on a media3 bump | Versioning rule in §9: re-copy the six files per bump; smoke test catches a broken load |

## 14. Open items for the owner

- Replace `io.github.CHANGEME` (`gradle.properties`) and the repository URL placeholders in
  `README.md`/POM with the real GitHub owner once the repo is created.
- Decide whether to add Maven Central publishing later (Sonatype account, GPG key, two secrets).
- Codec patent licences remain a business matter outside this repository.
