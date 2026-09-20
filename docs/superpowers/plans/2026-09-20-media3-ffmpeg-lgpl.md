# media3-ffmpeg-lgpl Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A public repository whose CI builds FFmpeg from source, LGPL-only, and publishes a drop-in `.aar` giving Jetpack Media3 1.11.0 software audio decoding (DTS, TrueHD, AC-3/E-AC-3, Vorbis, Opus, FLAC, ALAC, µ-law/A-law) — the replacement for the GPL-3.0 `nextlib-media3ext`.

**Architecture:** media3's own Apache-2.0 `decoder_ffmpeg` extension (4 Java classes + one JNI file, copied at tag 1.11.0, one file modified) is wrapped in an Android library module. A shell script builds FFmpeg `n7.1.5` per ABI as **shared** libraries with `--disable-gpl --disable-nonfree` and 16 KB page alignment; CMake links a thin `libffmpegJNI.so` against them; Gradle packages everything into an AAR. A verification script and an instrumented smoke test on a 16 KB-page emulator gate every build; tags produce GitHub Releases with an LGPL §6 build record.

**Tech Stack:** Bash, FFmpeg n7.1.5, Android NDK r27c (`27.2.12479018`), CMake 3.22.1, AGP 9.2.1, Gradle 9.4.1, JDK 21, Java 11 sources, GitHub Actions (`ubuntu-24.04`), `reactivecircus/android-emulator-runner@v2`.

**Spec:** `docs/superpowers/specs/2026-09-20-media3-ffmpeg-lgpl-design.md`

## Global Constraints

- Repository root: `D:\android_app\media3-ffmpeg-lgpl` (git already initialised; one commit containing the spec).
- Every version and list lives in `gradle.properties` and nowhere else: `media3.version=1.11.0`, `ffmpeg.tag=n7.1.5`, `ffmpeg.decoders=ac3 eac3 truehd dca vorbis opus flac alac pcm_mulaw pcm_alaw`, `ffmpeg.abis=arm64-v8a armeabi-v7a x86_64`, `ffmpeg.pageSize=16384`, `ndk.version=27.2.12479018`, `cmake.version=3.22.1`, `lib.minSdk=24`, `lib.compileSdk=36`, `publish.group=io.github.CHANGEME`, `publish.artifact=media3-ffmpeg-lgpl`, `publish.version=1.11.0-SNAPSHOT`. Never prefix a custom key with `android.`.
- Upstream files come from `https://raw.githubusercontent.com/androidx/media/1.11.0/libraries/decoder_ffmpeg/...` and are copied byte-for-byte except `FfmpegLibrary.java` (load order). `ExperimentalFfmpegVideoRenderer.java` is **not** copied.
- FFmpeg ships as `libavutil.so`, `libswresample.so`, `libavcodec.so` (shared) + `libffmpegJNI.so`. Never static.
- Java package stays `androidx.media3.decoder.ffmpeg` (media3 finds the renderer by reflection on that name).
- `x86_64` is built with `--disable-asm`; no `x86`.
- Shell scripts: `#!/usr/bin/env bash`, `set -euo pipefail`, run from any cwd (resolve paths from `${BASH_SOURCE[0]}`), fail with a message naming the fix.
- Commit messages end with `Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>`; author `Karti <indiananimeserver@gmail.com>` (pass `-c user.email=... -c user.name=...`).
- The developer machine has **no NDK, CMake, WSL or nasm**. Local tests cover the Gradle/Java side and the scripts' logic; the native build is verified by the first CI run. Say so wherever a step cannot be verified locally.
- Windows note: the Bash tool breaks on apostrophes inside heredocs. Write prose-bearing files with the Write tool; use Bash for `cp`, `curl`, `git`, `./gradlew`.

---

### Task 1: Repository skeleton and Gradle configuration

**Files:**
- Create: `.gitignore`, `gradle.properties`, `settings.gradle.kts`, `build.gradle.kts`, `LICENSE`
- Copy from `D:\android_app\apk`: `gradlew`, `gradlew.bat`, `gradle/wrapper/gradle-wrapper.jar`, `gradle/wrapper/gradle-wrapper.properties`, `gradle/gradle-daemon-jvm.properties`

**Interfaces:**
- Produces: the property keys listed in Global Constraints, read later by `lib/build.gradle.kts` (via `providers.gradleProperty`) and by the shell scripts (via `grep '^key=' gradle.properties`).

- [ ] **Step 1: Write `.gitignore`**

```gitignore
# Gradle / IDE
.gradle/
build/
.idea/
*.iml
local.properties
.kotlin/
.cxx/

# FFmpeg source checkout and build products - fetched and built by ffmpeg/build.sh, never committed
ffmpeg/src/
ffmpeg/out/
lib/src/main/jniLibs/

# Release staging assembled by ffmpeg/record.sh
dist/
```

- [ ] **Step 2: Write `gradle.properties`**

```properties
# Single source of truth. Gradle reads this natively; ffmpeg/*.sh read it with grep '^key='.
# Custom keys are deliberately not prefixed "android." - AGP owns that prefix.

media3.version=1.11.0
ffmpeg.tag=n7.1.5
# Decoders media3's FfmpegLibrary can route to, minus AAC/MP3 (hardware everywhere) and AMR (rare).
# Any name here must be a valid FFmpeg decoder name: ffmpeg/build.sh fails if config.h disagrees.
ffmpeg.decoders=ac3 eac3 truehd dca vorbis opus flac alac pcm_mulaw pcm_alaw
ffmpeg.abis=arm64-v8a armeabi-v7a x86_64
ffmpeg.pageSize=16384
ndk.version=27.2.12479018
cmake.version=3.22.1
lib.minSdk=24
lib.compileSdk=36

publish.group=io.github.CHANGEME
publish.artifact=media3-ffmpeg-lgpl
publish.version=1.11.0-SNAPSHOT

android.useAndroidX=true
org.gradle.jvmargs=-Xmx2g -Dfile.encoding=UTF-8
```

- [ ] **Step 3: Write `settings.gradle.kts`** (mirrors DV Player so the same Gradle/AGP resolve from the local cache)

```kotlin
pluginManagement {
    repositories {
        google {
            content {
                includeGroupByRegex("com\\.android.*")
                includeGroupByRegex("com\\.google.*")
                includeGroupByRegex("androidx.*")
            }
        }
        mavenCentral()
        gradlePluginPortal()
    }
}
plugins {
    id("org.gradle.toolchains.foojay-resolver-convention") version "1.0.0"
}
dependencyResolutionManagement {
    repositoriesMode.set(RepositoriesMode.FAIL_ON_PROJECT_REPOS)
    repositories {
        google()
        mavenCentral()
    }
}

rootProject.name = "media3-ffmpeg-lgpl"
include(":lib")
```

- [ ] **Step 4: Write root `build.gradle.kts`**

```kotlin
plugins {
    id("com.android.library") version "9.2.1" apply false
}
```

- [ ] **Step 5: Copy the wrapper and toolchain files, and the Apache-2.0 text**

```bash
cd /d/android_app/media3-ffmpeg-lgpl
mkdir -p gradle/wrapper lib
cp /d/android_app/apk/gradlew /d/android_app/apk/gradlew.bat .
cp /d/android_app/apk/gradle/wrapper/gradle-wrapper.jar /d/android_app/apk/gradle/wrapper/gradle-wrapper.properties gradle/wrapper/
cp /d/android_app/apk/gradle/gradle-daemon-jvm.properties gradle/
cp /d/android_app/apk/app/src/main/res/raw/license_apache_2_0.txt LICENSE
```

- [ ] **Step 6: Create a placeholder `lib/build.gradle.kts`** so `include(":lib")` resolves (Task 2 replaces it)

```kotlin
plugins { id("com.android.library") }
android { namespace = "androidx.media3.decoder.ffmpeg"; compileSdk = 36 }
```

- [ ] **Step 7: Verify Gradle configures**

Run: `cd /d/android_app/media3-ffmpeg-lgpl && ./gradlew.bat help --console=plain 2>&1 | grep -E "BUILD|error|FAIL"`
Expected: `BUILD SUCCESSFUL`

- [ ] **Step 8: Commit**

```bash
git add -A && git -c user.email="indiananimeserver@gmail.com" -c user.name="Karti" commit -q -F - <<'EOF'
Repository skeleton: Gradle 9.4.1 / AGP 9.2.1, single-source-of-truth properties

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
EOF
```

### Task 2: The library module — upstream sources, JNI, CMake, Gradle, guard

**Files:**
- Create (download): `lib/src/main/java/androidx/media3/decoder/ffmpeg/{FfmpegAudioDecoder,FfmpegAudioRenderer,FfmpegDecoderException,FfmpegLibrary,package-info}.java`, `lib/src/main/jni/ffmpeg_jni.cc`
- Modify: `lib/src/main/java/androidx/media3/decoder/ffmpeg/FfmpegLibrary.java` (loader lines 37-38)
- Create: `lib/src/main/AndroidManifest.xml`, `lib/consumer-rules.pro`, `lib/src/main/jni/CMakeLists.txt`
- Replace: `lib/build.gradle.kts`

**Interfaces:**
- Consumes: property keys from Task 1.
- Produces: Gradle tasks `:lib:assembleRelease` → `lib/build/outputs/aar/media3-ffmpeg-lgpl-release.aar`; `BuildConfig.FFMPEG_DECODERS` / `BuildConfig.FFMPEG_TAG` (strings) in package `androidx.media3.decoder.ffmpeg`; CMake variables `FFMPEG_OUT_DIR`, `FFMPEG_JNILIBS_DIR`, `FFMPEG_PAGE_SIZE` passed by Gradle; native libs expected at `lib/src/main/jniLibs/<abi>/lib{avutil,swresample,avcodec}.so` and headers at `ffmpeg/out/<abi>/include` (both produced by Task 4).

- [ ] **Step 1: Download the upstream files (Apache-2.0, tag 1.11.0)**

```bash
cd /d/android_app/media3-ffmpeg-lgpl
B="https://raw.githubusercontent.com/androidx/media/1.11.0/libraries/decoder_ffmpeg/src/main"
D="lib/src/main/java/androidx/media3/decoder/ffmpeg"
mkdir -p "$D" lib/src/main/jni
for f in FfmpegAudioDecoder FfmpegAudioRenderer FfmpegDecoderException FfmpegLibrary package-info; do
  curl -fsSL --max-time 60 -o "$D/$f.java" "$B/java/androidx/media3/decoder/ffmpeg/$f.java"
done
curl -fsSL --max-time 60 -o lib/src/main/jni/ffmpeg_jni.cc "$B/jni/ffmpeg_jni.cc"
wc -l "$D"/*.java lib/src/main/jni/ffmpeg_jni.cc
```
Expected line counts: 322, 209, 32, 167, 19, 432. Every file starts with the Apache-2.0 header.

- [ ] **Step 2: Modify `FfmpegLibrary.java` — load the shared FFmpeg libraries first**

Read the file, then make two edits.

Insert immediately before `package androidx.media3.decoder.ffmpeg;`:

```java
/*
 * MODIFIED from the original in androidx/media (tag 1.11.0) for media3-ffmpeg-lgpl:
 * LibraryLoader now names libavutil, libswresample and libavcodec before libffmpegJNI. In this
 * distribution FFmpeg is packaged as separate shared libraries rather than statically linked
 * into libffmpegJNI.so, and loading them explicitly, in dependency order, removes the one step
 * that would otherwise depend on the platform linker resolving DT_NEEDED entries from the app's
 * library directory. Nothing else in this file is changed. (Apache License 2.0, section 4(b).)
 */
```

Replace
```java
      new LibraryLoader("ffmpegJNI") {
```
with
```java
      // Dependency order: avcodec needs avutil and swresample; ffmpegJNI needs all three.
      new LibraryLoader("avutil", "swresample", "avcodec", "ffmpegJNI") {
```

- [ ] **Step 3: Write `lib/src/main/AndroidManifest.xml`**

```xml
<?xml version="1.0" encoding="utf-8"?>
<manifest />
```

- [ ] **Step 4: Write `lib/consumer-rules.pro`** (packaged into the AAR as `proguard.txt`; applied automatically in every consuming app)

```proguard
# media3-ffmpeg-lgpl consumer rules. Shipped inside the AAR, so every app that depends on it
# gets them without knowing they exist. The first two are upstream media3's rules verbatim.

# Native method names are looked up by the JNI runtime; obfuscating them breaks the binding.
-keepclasseswithmembernames class * {
    native <methods>;
}

# Called FROM native code: ffmpeg_jni.cc looks this method up by name and descriptor.
-keep, includedescriptorclasses class androidx.media3.decoder.ffmpeg.FfmpegAudioDecoder {
  private java.nio.ByteBuffer growOutputBuffer(androidx.media3.decoder.SimpleDecoderOutputBuffer, int);
}

# DefaultRenderersFactory instantiates the renderer by reflection. media3-exoplayer's own consumer
# rules keep the constructor and R8 keeps a class named in Class.forName("literal"), but an
# explicit keep costs nothing and depends on neither.
-keep class androidx.media3.decoder.ffmpeg.FfmpegAudioRenderer { *; }
-keep class androidx.media3.decoder.ffmpeg.FfmpegLibrary { *; }
```

- [ ] **Step 5: Write `lib/src/main/jni/CMakeLists.txt`**

```cmake
# media3-ffmpeg-lgpl: builds libffmpegJNI.so (media3's JNI bridge) against FFmpeg shared libraries
# produced by ffmpeg/build.sh. Gradle passes FFMPEG_OUT_DIR, FFMPEG_JNILIBS_DIR and
# FFMPEG_PAGE_SIZE (see lib/build.gradle.kts); nothing here is hard-coded.
cmake_minimum_required(VERSION 3.21.0 FATAL_ERROR)
project(libffmpegJNI C CXX)
set(CMAKE_CXX_STANDARD 11)

foreach(var FFMPEG_OUT_DIR FFMPEG_JNILIBS_DIR FFMPEG_PAGE_SIZE)
    if(NOT DEFINED ${var})
        message(FATAL_ERROR "${var} must be passed by Gradle - see lib/build.gradle.kts")
    endif()
endforeach()

# Headers are per ABI on purpose: libavutil/avconfig.h differs between architectures.
set(ffmpeg_include "${FFMPEG_OUT_DIR}/${ANDROID_ABI}/include")
set(ffmpeg_libs "${FFMPEG_JNILIBS_DIR}/${ANDROID_ABI}")

if(NOT EXISTS "${ffmpeg_include}/libavcodec/avcodec.h")
    message(FATAL_ERROR "FFmpeg headers missing at ${ffmpeg_include} - run ffmpeg/build.sh first")
endif()
foreach(lib avutil swresample avcodec)
    if(NOT EXISTS "${ffmpeg_libs}/lib${lib}.so")
        message(FATAL_ERROR "Missing ${ffmpeg_libs}/lib${lib}.so - run ffmpeg/build.sh first")
    endif()
endforeach()

add_library(ffmpegJNI SHARED ffmpeg_jni.cc)
target_include_directories(ffmpegJNI PRIVATE "${ffmpeg_include}")

# Linked BY NAME against the jniLibs directory, not through IMPORTED targets. AGP packages
# imported shared targets automatically, and combining that with jniLibs produces duplicate-file
# failures; this way jniLibs is the only packaging path and CMake merely links. The result is a
# DT_NEEDED on each library's plain soname (libavcodec.so), which ffmpeg/verify.sh checks.
target_link_directories(ffmpegJNI PRIVATE "${ffmpeg_libs}")
find_library(android_log_lib log)
target_link_libraries(ffmpegJNI
        PRIVATE android
        PRIVATE avcodec
        PRIVATE swresample
        PRIVATE avutil
        PRIVATE ${android_log_lib})

# 16 KB page-size alignment (Play requirement for native code on Android 15+), and refuse text
# relocations at link time rather than discovering them as a load failure on the device.
target_link_options(ffmpegJNI PRIVATE "-Wl,-z,max-page-size=${FFMPEG_PAGE_SIZE}" "-Wl,-z,text")

# Upstream: needed for arm64-v8a from NDK 23.1 (https://github.com/google/ExoPlayer/issues/9933).
if(ANDROID_ABI STREQUAL "arm64-v8a")
    target_link_options(ffmpegJNI PRIVATE "-Wl,-Bsymbolic")
endif()
```

- [ ] **Step 6: Replace `lib/build.gradle.kts`**

```kotlin
plugins {
    id("com.android.library")
    id("maven-publish")
}

fun prop(name: String): String =
    providers.gradleProperty(name).orNull ?: error("Missing '$name' in gradle.properties")

val media3Version = prop("media3.version")
val ffmpegTag = prop("ffmpeg.tag")
val ffmpegDecoders = prop("ffmpeg.decoders")
val ffmpegAbis = prop("ffmpeg.abis").split(' ').filter { it.isNotBlank() }
val ffmpegPageSize = prop("ffmpeg.pageSize")
val publishGroup = prop("publish.group")
val publishArtifact = prop("publish.artifact")
val publishVersion = prop("publish.version")

// FFmpeg is built out of band by ffmpeg/build.sh, which needs the NDK. Its outputs are the
// shared libraries under src/main/jniLibs/<abi>/ and the per-ABI headers under ffmpeg/out.
val ffmpegOutDir = rootProject.layout.projectDirectory.dir("ffmpeg/out")
val jniLibsDir = layout.projectDirectory.dir("src/main/jniLibs")
val ffmpegBuilt = ffmpegAbis.all { abi -> jniLibsDir.file("$abi/libavcodec.so").asFile.exists() }

android {
    namespace = "androidx.media3.decoder.ffmpeg"
    compileSdk = prop("lib.compileSdk").toInt()
    ndkVersion = prop("ndk.version")

    defaultConfig {
        minSdk = prop("lib.minSdk").toInt()
        testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"
        consumerProguardFiles("consumer-rules.pro")

        // Read by the smoke test, so the asserted decoder set is the configured one rather than
        // a second copy of the list that could drift.
        buildConfigField("String", "FFMPEG_DECODERS", "\"$ffmpegDecoders\"")
        buildConfigField("String", "FFMPEG_TAG", "\"$ffmpegTag\"")

        // Only ABIs FFmpeg was built for; otherwise CMake would configure x86 and fail.
        ndk { abiFilters += ffmpegAbis }

        externalNativeBuild {
            cmake {
                arguments += listOf(
                    "-DANDROID_STL=c++_static",
                    "-DANDROID_SUPPORT_FLEXIBLE_PAGE_SIZES=ON",
                    "-DFFMPEG_OUT_DIR=${ffmpegOutDir.asFile.absolutePath}",
                    "-DFFMPEG_JNILIBS_DIR=${jniLibsDir.asFile.absolutePath}",
                    "-DFFMPEG_PAGE_SIZE=$ffmpegPageSize"
                )
            }
        }
    }

    // Configured only when FFmpeg is present, so `gradlew help` and IDE sync work on a machine
    // without the NDK. Any attempt to package without it is refused below.
    if (ffmpegBuilt) {
        externalNativeBuild {
            cmake {
                path = file("src/main/jni/CMakeLists.txt")
                version = prop("cmake.version")
            }
        }
    }

    buildFeatures {
        buildConfig = true
    }
    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_11
        targetCompatibility = JavaVersion.VERSION_11
    }
    publishing {
        singleVariant("release") {
            withSourcesJar()
        }
    }
}

base {
    archivesName.set(publishArtifact)
}

// An AAR packaged without the native libraries installs fine and then throws
// UnsatisfiedLinkError at first playback. Refuse to produce one. Compilation tasks are left
// alone so the Java side can be built and its tests compiled on a machine without the NDK.
tasks.matching { it.name.matches(Regex("bundle.*Aar|merge.*JniLibFolders|publish.*")) }
    .configureEach {
        doFirst {
            check(ffmpegBuilt) {
                "FFmpeg has not been built for every ABI in ffmpeg.abis (missing " +
                    "src/main/jniLibs/<abi>/libavcodec.so). Run ffmpeg/build.sh first - it " +
                    "needs the Android NDK; see README.md."
            }
        }
    }

dependencies {
    // api: the renderer extends and returns media3 types, so consumers need them on their
    // classpath, and a POM consumer gets them transitively. Versions must match exactly - these
    // classes link against @UnstableApi internals.
    api("androidx.media3:media3-exoplayer:$media3Version")
    api("androidx.media3:media3-decoder:$media3Version")
    api("androidx.media3:media3-common:$media3Version")
    implementation("androidx.annotation:annotation:1.9.1")
    // media3-common exposes guava (Preconditions) transitively but explicitly excludes
    // checker-qual, which the upstream sources use for @MonotonicNonNull.
    compileOnly("org.checkerframework:checker-qual:4.2.3")

    androidTestImplementation("androidx.test.ext:junit:1.3.0")
    androidTestImplementation("junit:junit:4.13.2")
}

publishing {
    publications {
        register<MavenPublication>("release") {
            groupId = publishGroup
            artifactId = publishArtifact
            version = publishVersion
            afterEvaluate { from(components["release"]) }
            pom {
                name.set("media3-ffmpeg-lgpl")
                description.set(
                    "FFmpeg audio decoders for Jetpack Media3 $media3Version, built from source " +
                        "LGPL-only (--disable-gpl --disable-nonfree) as shared libraries."
                )
                url.set("https://github.com/CHANGEME/media3-ffmpeg-lgpl")
                licenses {
                    license {
                        name.set("Apache-2.0")
                        url.set("https://www.apache.org/licenses/LICENSE-2.0")
                        comments.set("This library's own code and the media3 extension sources it packages.")
                    }
                    license {
                        name.set("LGPL-2.1-or-later")
                        url.set("https://www.gnu.org/licenses/old-licenses/lgpl-2.1.html")
                        comments.set("The FFmpeg shared libraries bundled in the AAR. See NOTICE.")
                    }
                }
                scm {
                    url.set("https://github.com/CHANGEME/media3-ffmpeg-lgpl")
                }
            }
        }
    }
}
```

- [ ] **Step 7: Verify the Java side compiles against media3 1.11.0** (no NDK needed)

Run: `./gradlew.bat :lib:compileReleaseJavaWithJavac --console=plain 2>&1 | grep -E "^e:|error:|BUILD"`
Expected: `BUILD SUCCESSFUL` — proves the copied sources, `checker-qual`, `annotation` and the media3 `api` deps resolve.

- [ ] **Step 8: Verify the packaging guard fires without FFmpeg**

Run: `./gradlew.bat :lib:assembleRelease --console=plain 2>&1 | grep -E "FFmpeg has not been built|BUILD"`
Expected: the guard message, then `BUILD FAILED`.

- [ ] **Step 9: Commit**

```bash
git add -A && git -c user.email="indiananimeserver@gmail.com" -c user.name="Karti" commit -q -F - <<'EOF'
Library module: media3 1.11.0 ffmpeg extension sources, JNI, CMake, packaging guard

Sources are byte-for-byte from androidx/media at tag 1.11.0 (Apache-2.0)
except FfmpegLibrary.java, which loads the three FFmpeg shared libraries
before libffmpegJNI and carries a notice saying so. The experimental video
renderer is not copied: upstream marks it non-functional.

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
EOF
```

### Task 3: Instrumented smoke test

**Files:**
- Create: `lib/src/androidTest/java/androidx/media3/decoder/ffmpeg/FfmpegLibrarySmokeTest.java`

**Interfaces:**
- Consumes: `BuildConfig.FFMPEG_DECODERS` (Task 2); package-private `FfmpegLibrary.getCodecName(String)` from upstream; public `FfmpegLibrary.isAvailable()`, `getVersion()`, `supportsFormat(String)`.
- Produces: Gradle task `:lib:connectedDebugAndroidTest`, run by the CI `smoke` job (Task 7).

- [ ] **Step 1: Write the test**

```java
package androidx.media3.decoder.ffmpeg;

import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertFalse;
import static org.junit.Assert.assertNotNull;
import static org.junit.Assert.assertTrue;

import androidx.media3.common.MimeTypes;
import androidx.test.ext.junit.runners.AndroidJUnit4;
import java.util.Arrays;
import java.util.HashSet;
import java.util.Set;
import org.junit.Test;
import org.junit.runner.RunWith;

/**
 * Proves the packaged native libraries load and expose exactly the configured decoders.
 *
 * Same package as the library so it can call the package-private {@link
 * FfmpegLibrary#getCodecName}. Run by CI on a 16 KB-page emulator image, which is what turns
 * "the ELF headers say 16 KB" into "it loads on a 16 KB kernel".
 */
@RunWith(AndroidJUnit4.class)
public final class FfmpegLibrarySmokeTest {

  /** Every MIME type media3 1.11.0 routes to an FFmpeg decoder name. */
  private static final String[] ROUTED_MIME_TYPES = {
    MimeTypes.AUDIO_AC3,
    MimeTypes.AUDIO_E_AC3,
    MimeTypes.AUDIO_E_AC3_JOC,
    MimeTypes.AUDIO_TRUEHD,
    MimeTypes.AUDIO_DTS,
    MimeTypes.AUDIO_DTS_EXPRESS,
    MimeTypes.AUDIO_DTS_HD,
    MimeTypes.AUDIO_VORBIS,
    MimeTypes.AUDIO_OPUS,
    MimeTypes.AUDIO_FLAC,
    MimeTypes.AUDIO_ALAC,
    MimeTypes.AUDIO_MLAW,
    MimeTypes.AUDIO_ALAW,
    MimeTypes.AUDIO_AAC,
    MimeTypes.AUDIO_MPEG,
    MimeTypes.AUDIO_MPEG_L1,
    MimeTypes.AUDIO_MPEG_L2,
    MimeTypes.AUDIO_AMR_NB,
    MimeTypes.AUDIO_AMR_WB,
  };

  @Test
  public void nativeLibrariesLoad() {
    assertTrue(
        "FfmpegLibrary.isAvailable() is false: libavutil/libswresample/libavcodec/libffmpegJNI "
            + "did not load - check logcat for UnsatisfiedLinkError",
        FfmpegLibrary.isAvailable());
  }

  @Test
  public void reportsFfmpegVersion() {
    String version = FfmpegLibrary.getVersion();
    assertNotNull("getVersion() returned null", version);
    assertFalse("getVersion() returned an empty string", version.isEmpty());
  }

  /**
   * Positive AND negative: a decoder that was configured but silently dropped fails, and one
   * that crept in fails too. The expected set comes from BuildConfig, i.e. gradle.properties.
   */
  @Test
  public void decoderSetIsExactlyTheConfiguredOne() {
    assertTrue(FfmpegLibrary.isAvailable());
    Set<String> enabled =
        new HashSet<>(Arrays.asList(BuildConfig.FFMPEG_DECODERS.trim().split("\\s+")));
    assertFalse("BuildConfig.FFMPEG_DECODERS is empty", enabled.isEmpty());

    for (String mimeType : ROUTED_MIME_TYPES) {
      String codec = FfmpegLibrary.getCodecName(mimeType);
      assertNotNull("media3 no longer routes " + mimeType + "; update ROUTED_MIME_TYPES", codec);
      boolean expected = enabled.contains(codec);
      assertEquals(
          mimeType + " -> " + codec + " should be " + (expected ? "supported" : "absent"),
          expected,
          FfmpegLibrary.supportsFormat(mimeType));
    }
  }
}
```

- [ ] **Step 2: Verify it compiles** (the only local check possible — running it needs a device)

Run: `./gradlew.bat :lib:compileDebugAndroidTestJavaWithJavac --console=plain 2>&1 | grep -E "^e:|error:|BUILD"`
Expected: `BUILD SUCCESSFUL`

- [ ] **Step 3: Commit**

```bash
git add -A && git -c user.email="indiananimeserver@gmail.com" -c user.name="Karti" commit -q -F - <<'EOF'
Smoke test: libraries load, version reported, decoder set exactly as configured

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
EOF
```

### Task 4: `ffmpeg/build.sh` — FFmpeg from source, LGPL-only, shared, 16 KB (test first)

**Files:**
- Create: `ffmpeg/test/test_build_config.sh` (the test), `ffmpeg/build.sh`

**Interfaces:**
- Consumes: `gradle.properties` keys `ffmpeg.tag`, `ffmpeg.decoders`, `ffmpeg.abis`, `ffmpeg.pageSize`, `ndk.version`, `lib.minSdk`; env `ANDROID_NDK_HOME` (or `ANDROID_HOME`/`ANDROID_SDK_ROOT` + `ndk/<version>`); optional env `FFMPEG_HOST_TAG` (overrides host detection, used by the test).
- Produces: `ffmpeg/src/` (checkout), `ffmpeg/out/<abi>/{lib,include}`, `ffmpeg/out/<abi>/config.h`, `ffmpeg/out/<abi>/configure.cmd`, `ffmpeg/out/ffmpeg-commit.txt`, `ffmpeg/out/ffmpeg-tag.txt`, and `lib/src/main/jniLibs/<abi>/lib{avutil,swresample,avcodec}.so`. CLI: `build.sh` (build everything) or `build.sh --print-config <abi>` (print the configure arguments, one per line, without touching the network or the NDK).

- [ ] **Step 1: Write the failing test** — `ffmpeg/test/test_build_config.sh`

```bash
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
```

- [ ] **Step 2: Run it to verify it fails**

Run: `bash ffmpeg/test/test_build_config.sh`
Expected: fails immediately — `ffmpeg/build.sh: No such file or directory`.

- [ ] **Step 3: Write `ffmpeg/build.sh`**

```bash
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
#                                     what Android's packaging and linker expect.
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
```

- [ ] **Step 4: Make executable, run the test to verify it passes**

Run: `chmod +x ffmpeg/build.sh ffmpeg/test/test_build_config.sh && bash -n ffmpeg/build.sh && bash ffmpeg/test/test_build_config.sh`
Expected: `test_build_config: OK`

- [ ] **Step 5: Commit**

```bash
git add -A && git -c user.email="indiananimeserver@gmail.com" -c user.name="Karti" commit -q -F - <<'EOF'
ffmpeg/build.sh: FFmpeg n7.1.5 per ABI, LGPL-only, shared, 16 KB pages

The configure argument list is testable without an NDK (--print-config),
and config.h is checked for the LGPL licence and every requested decoder
before the compile starts.

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
EOF
```

### Task 5: `ffmpeg/verify.sh` — the AAR gate (test first)

**Files:**
- Create: `ffmpeg/test/test_verify.sh` (the test), `ffmpeg/verify.sh`

**Interfaces:**
- Consumes: the AAR from Task 2 (`lib/build/outputs/aar/media3-ffmpeg-lgpl-release.aar`), `ffmpeg/out/<abi>/config.h` from Task 4, property keys `ffmpeg.abis`, `ffmpeg.decoders`, `ffmpeg.pageSize`, `ndk.version`. Env overrides: `FFMPEG_OUT_DIR` (default `<root>/ffmpeg/out`), `ANDROID_NDK_HOME`.
- Produces: extracted AAR at `build/verify/aar/` (used by Task 6); exit 0 only if every check passes. CLI: `verify.sh [<aar>]` or `verify.sh --extracted <dir>`.

- [ ] **Step 1: Write the failing test** — `ffmpeg/test/test_verify.sh`

```bash
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

# config.h for every ABI, with the LAST configured decoder deliberately missing.
last="${DECODERS##* }"
for abi in $ABIS; do
  mkdir -p "$FFMPEG_OUT_DIR/$abi"
  {
    echo '#define FFMPEG_LICENSE "LGPL version 2.1 or later"'
    for d in $DECODERS; do
      [[ "$d" == "$last" ]] && continue
      echo "#define CONFIG_$(printf '%s' "$d" | tr '[:lower:]' '[:upper:]')_DECODER 1"
    done
  } > "$FFMPEG_OUT_DIR/$abi/config.h"
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
  must "$abi: decoder '$last' is not enabled in config.h"
done
must "missing classes.jar"
must "missing proguard.txt"
must "verify: FAILED"

if [[ $fails -eq 0 ]]; then echo "test_verify: OK"; else echo "test_verify: $fails failure(s)"; echo "--- output ---"; echo "$output"; exit 1; fi
```

- [ ] **Step 2: Run it to verify it fails**

Run: `bash ffmpeg/test/test_verify.sh`
Expected: fails — `ffmpeg/verify.sh: No such file or directory`.

- [ ] **Step 3: Write `ffmpeg/verify.sh`**

```bash
#!/usr/bin/env bash
#
# media3-ffmpeg-lgpl: verify a built AAR before it is released.
#
#   ffmpeg/verify.sh [AAR]              default: lib/build/outputs/aar/media3-ffmpeg-lgpl-release.aar
#   ffmpeg/verify.sh --extracted DIR    check an already-unzipped AAR (used by the tests)
#
# Every claim the README makes is checked here, and all failures are reported before exiting
# non-zero, because a list of everything wrong is more useful than the first thing wrong.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROPS="$ROOT/gradle.properties"
OUT="${FFMPEG_OUT_DIR:-$ROOT/ffmpeg/out}"
DIST="$ROOT/dist"

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
  local so="$1" label="$2"
  if "$READELF" -d "$so" | grep -q 'TEXTREL'; then fail "$label: has text relocations (Android refuses to load it)"; fi
}
check_ffmpeg_lib() {  # licence string and plain soname
  local so="$1" label="$2" name="$3" soname
  "$STRINGS" "$so" | grep -q 'license: LGPL version 2.1 or later' || fail "$label: LGPL-2.1 licence string not found"
  if "$STRINGS" "$so" | grep -qE 'license: (GPL|nonfree)'; then fail "$label: GPL or nonfree licence string present"; fi
  soname="$("$READELF" -d "$so" | grep 'SONAME' | grep -oE '\[[^]]+\]' | tr -d '[]' || true)"
  [[ "$soname" == "$name" ]] || fail "$label: SONAME is '$soname', expected '$name'"
}
check_jni_lib() {  # plain NEEDED entries and exported JNI symbols
  local so="$1" label="$2" need sym needed
  needed="$("$READELF" -d "$so" | grep 'NEEDED' || true)"
  for need in libavcodec.so libavutil.so libswresample.so; do
    grep -q "\[$need\]" <<<"$needed" || fail "$label: missing NEEDED $need"
  done
  if grep -qE '\[lib(avcodec|avutil|swresample)\.so\.[0-9]' <<<"$needed"; then fail "$label: versioned NEEDED entry (soname patching failed)"; fi
  for sym in "${JNI_SYMBOLS[@]}"; do
    "$NM" -D "$so" | grep -qE " T $sym\$" || fail "$label: does not export $sym"
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
  cfg="$OUT/$abi/config.h"
  if [[ ! -f "$cfg" ]]; then fail "$abi: missing $cfg"; continue; fi
  grep -qxF '#define FFMPEG_LICENSE "LGPL version 2.1 or later"' "$cfg" || fail "$abi: config.h licence is not LGPL-2.1+"
  for d in $DECODERS; do
    grep -qxF "#define CONFIG_$(printf '%s' "$d" | tr '[:lower:]' '[:upper:]')_DECODER 1" "$cfg" \
      || fail "$abi: decoder '$d' is not enabled in config.h"
  done
done

if [[ -f "$EXTRACTED/classes.jar" ]]; then
  for cls in FfmpegAudioRenderer FfmpegLibrary FfmpegAudioDecoder; do
    unzip -l "$EXTRACTED/classes.jar" | grep -q "androidx/media3/decoder/ffmpeg/$cls.class" || fail "classes.jar lacks $cls.class"
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
```

- [ ] **Step 4: Make executable, run the test to verify it passes**

Run: `chmod +x ffmpeg/verify.sh ffmpeg/test/test_verify.sh && bash -n ffmpeg/verify.sh && bash ffmpeg/test/test_verify.sh`
Expected: `test_verify: OK`

- [ ] **Step 5: Commit**

```bash
git add -A && git -c user.email="indiananimeserver@gmail.com" -c user.name="Karti" commit -q -F - <<'EOF'
ffmpeg/verify.sh: licence, soname, NEEDED, 16 KB alignment, TEXTREL, JNI exports, decoders

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
EOF
```

### Task 6: `ffmpeg/record.sh` — the release directory and the LGPL §6 build record (test first)

**Files:**
- Create: `ffmpeg/test/test_record.sh` (the test), `ffmpeg/record.sh`

**Interfaces:**
- Consumes: the AAR path and version (args); `build/verify/aar/` from Task 5; `ffmpeg/out/{ffmpeg-commit.txt,ffmpeg-tag.txt,<abi>/configure.cmd,<abi>/config.h}` and `ffmpeg/src` (git) from Task 4; `NOTICE`, `LICENSE` from the root. Env overrides: `FFMPEG_SRC_DIR`, `FFMPEG_OUT_DIR`, `DIST_DIR`, `EXTRACTED_DIR`.
- Produces: `dist/<artifact>-<version>.aar`, `dist/BUILD_RECORD.md`, `dist/SHA256SUMS`, `dist/ffmpeg-corresponding-source.txt`, `dist/ffmpeg-<tag>-src.tar.gz`, `dist/NOTICE`, `dist/LICENSE`. CLI: `record.sh <aar> <version>`.

- [ ] **Step 1: Write the failing test** — `ffmpeg/test/test_record.sh`

```bash
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
```

- [ ] **Step 2: Run it to verify it fails**

Run: `bash ffmpeg/test/test_record.sh`
Expected: fails — `ffmpeg/record.sh: No such file or directory`.

- [ ] **Step 3: Write `ffmpeg/record.sh`**

```bash
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
  ( cd "$EXTRACTED" && find jni -name '*.so' | sort | xargs sha )
  echo '```'
} > "$DIST/BUILD_RECORD.md"

{
  ( cd "$DIST" && sha "$AAR_NAME" "$TARBALL" )
  ( cd "$EXTRACTED" && find jni -name '*.so' | sort | xargs sha )
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
```

- [ ] **Step 4: Make executable, run the test to verify it passes**

Run: `chmod +x ffmpeg/record.sh ffmpeg/test/test_record.sh && bash -n ffmpeg/record.sh && bash ffmpeg/test/test_record.sh`
Expected: `test_record: OK`. (Requires `NOTICE` and `LICENSE` at the root — `LICENSE` exists from Task 1; if `NOTICE` does not exist yet, create it first as in Task 8 Step 1.)

- [ ] **Step 5: Commit**

```bash
git add -A && git -c user.email="indiananimeserver@gmail.com" -c user.name="Karti" commit -q -F - <<'EOF'
ffmpeg/record.sh: release directory with the LGPL section 6 build record and checksums

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
EOF
```

### Task 7: CI — `.github/workflows/build.yml`

**Files:**
- Create: `.github/workflows/build.yml`

**Interfaces:**
- Consumes: `ffmpeg/build.sh` (Task 4), `:lib:assembleRelease` (Task 2), `ffmpeg/verify.sh` (Task 5), `ffmpeg/record.sh` (Task 6), `:lib:connectedDebugAndroidTest` (Task 3), property keys `ndk.version`, `cmake.version`, `lib.compileSdk`, `publish.version`.
- Produces: artifacts `dist` (release files), `ffmpeg-native` (jniLibs + headers + metadata, consumed by the `smoke` job), `smoke-test-reports`; on a `v*` tag, a GitHub Release with the AAR, `BUILD_RECORD.md`, `SHA256SUMS`, `ffmpeg-corresponding-source.txt`, the FFmpeg source tarball, `NOTICE`, `LICENSE`.

- [ ] **Step 1: Write the workflow**

```yaml
name: build

on:
  push:
    branches: [main]
    tags: ['v*']
  pull_request:
  workflow_dispatch:

permissions:
  contents: read

concurrency:
  group: ${{ github.workflow }}-${{ github.ref }}
  cancel-in-progress: true

jobs:
  build:
    name: Build FFmpeg (LGPL, shared, 16 KB pages) and the AAR
    runs-on: ubuntu-24.04
    outputs:
      version: ${{ steps.version.outputs.version }}
    steps:
      - uses: actions/checkout@v4

      - name: Read gradle.properties
        id: props
        run: |
          for key in ndk.version cmake.version lib.compileSdk ffmpeg.tag publish.version; do
            value="$(grep -E "^${key}=" gradle.properties | cut -d= -f2- | tr -d '\r')"
            echo "${key//./_}=${value}" >> "$GITHUB_OUTPUT"
          done

      - name: Decide the version
        id: version
        run: |
          if [[ "$GITHUB_REF_TYPE" == "tag" ]]; then
            echo "version=${GITHUB_REF_NAME#v}" >> "$GITHUB_OUTPUT"
          else
            echo "version=${{ steps.props.outputs.publish_version }}" >> "$GITHUB_OUTPUT"
          fi

      - uses: actions/setup-java@v4
        with:
          distribution: temurin
          java-version: '21'

      - uses: android-actions/setup-android@v3

      - name: Install the NDK, CMake and the platform
        run: |
          sdkmanager --install \
            "ndk;${{ steps.props.outputs.ndk_version }}" \
            "cmake;${{ steps.props.outputs.cmake_version }}" \
            "platforms;android-${{ steps.props.outputs.lib_compileSdk }}"

      - uses: gradle/actions/setup-gradle@v4

      # build.sh finds the NDK under $ANDROID_HOME/ndk/<ndk.version>; sdkmanager put it there.
      - name: Build FFmpeg
        run: ./ffmpeg/build.sh

      - name: Build the AAR
        run: ./gradlew :lib:assembleRelease -Ppublish.version="${{ steps.version.outputs.version }}" --no-daemon --stacktrace

      - name: Verify the AAR
        run: ./ffmpeg/verify.sh

      - name: Assemble dist
        run: ./ffmpeg/record.sh lib/build/outputs/aar/media3-ffmpeg-lgpl-release.aar "${{ steps.version.outputs.version }}"

      - name: Upload configure logs
        if: failure()
        uses: actions/upload-artifact@v4
        with:
          name: ffmpeg-configure-logs
          if-no-files-found: ignore
          path: |
            ffmpeg/src/ffbuild/config.log
            ffmpeg/out/*/configure.cmd
            ffmpeg/out/*/config.h

      - name: Upload dist
        uses: actions/upload-artifact@v4
        with:
          name: dist
          if-no-files-found: error
          path: dist/

      - name: Upload native outputs for the smoke test
        uses: actions/upload-artifact@v4
        with:
          name: ffmpeg-native
          if-no-files-found: error
          path: |
            lib/src/main/jniLibs/**
            ffmpeg/out/*/include/**
            ffmpeg/out/*/config.h
            ffmpeg/out/*/configure.cmd
            ffmpeg/out/ffmpeg-commit.txt
            ffmpeg/out/ffmpeg-tag.txt

  smoke:
    name: Smoke test on a 16 KB-page emulator
    needs: build
    runs-on: ubuntu-24.04
    steps:
      - uses: actions/checkout@v4

      - name: Read gradle.properties
        id: props
        run: |
          for key in ndk.version cmake.version lib.compileSdk; do
            value="$(grep -E "^${key}=" gradle.properties | cut -d= -f2- | tr -d '\r')"
            echo "${key//./_}=${value}" >> "$GITHUB_OUTPUT"
          done

      # The artifact root is the repository root (least common ancestor of its paths), so this
      # restores lib/src/main/jniLibs and ffmpeg/out exactly where the build job left them.
      - uses: actions/download-artifact@v4
        with:
          name: ffmpeg-native
          path: .

      - name: Confirm the native outputs are in place
        run: ls -R lib/src/main/jniLibs && ls ffmpeg/out

      - uses: actions/setup-java@v4
        with:
          distribution: temurin
          java-version: '21'

      - uses: android-actions/setup-android@v3

      - name: Install the NDK, CMake and the platform
        run: |
          sdkmanager --install \
            "ndk;${{ steps.props.outputs.ndk_version }}" \
            "cmake;${{ steps.props.outputs.cmake_version }}" \
            "platforms;android-${{ steps.props.outputs.lib_compileSdk }}"

      - uses: gradle/actions/setup-gradle@v4

      - name: Enable KVM
        run: |
          echo 'KERNEL=="kvm", GROUP="kvm", MODE="0666", OPTIONS+="static_node=kvm"' | sudo tee /etc/udev/rules.d/99-kvm4all.rules
          sudo udevadm control --reload-rules
          sudo udevadm trigger --name-match=kvm

      # google_apis_ps16k is a 16 KB page-size system image: this is where "aligned in the ELF
      # headers" becomes "loads on a 16 KB kernel".
      - name: Run the instrumented smoke test
        uses: reactivecircus/android-emulator-runner@v2
        with:
          api-level: 35
          target: google_apis_ps16k
          arch: x86_64
          ram-size: 3072M
          emulator-options: -no-window -gpu swiftshader_indirect -noaudio -no-boot-anim -camera-back none
          disable-animations: true
          script: ./gradlew :lib:connectedDebugAndroidTest --no-daemon --stacktrace

      - name: Upload test reports
        if: always()
        uses: actions/upload-artifact@v4
        with:
          name: smoke-test-reports
          if-no-files-found: ignore
          path: |
            lib/build/reports/androidTests/**
            lib/build/outputs/androidTest-results/**

  release:
    name: GitHub Release
    needs: [build, smoke]
    if: startsWith(github.ref, 'refs/tags/v')
    runs-on: ubuntu-24.04
    permissions:
      contents: write
    steps:
      - uses: actions/download-artifact@v4
        with:
          name: dist
          path: dist

      - name: Show what will be released
        run: ls -la dist && cat dist/SHA256SUMS

      - uses: softprops/action-gh-release@v2
        with:
          name: media3-ffmpeg-lgpl ${{ needs.build.outputs.version }}
          body_path: dist/BUILD_RECORD.md
          files: |
            dist/*.aar
            dist/BUILD_RECORD.md
            dist/SHA256SUMS
            dist/ffmpeg-corresponding-source.txt
            dist/ffmpeg-*-src.tar.gz
            dist/NOTICE
            dist/LICENSE
```

- [ ] **Step 2: Sanity-check the YAML structure** (no YAML tooling is installed; this catches indentation slips)

Run: `grep -nE "^\s+- (uses|name):" .github/workflows/build.yml | awk -F: '{print $1}' | wc -l` and `grep -cE "^  (build|smoke|release):$" .github/workflows/build.yml`
Expected: a step count ≥ 25, and `3` jobs. Then read the file once, top to bottom, checking every `- name:`/`- uses:` sits at the same indentation within its job.

- [ ] **Step 3: Commit**

```bash
git add -A && git -c user.email="indiananimeserver@gmail.com" -c user.name="Karti" commit -q -F - <<'EOF'
CI: build FFmpeg and the AAR, verify, smoke-test on a 16 KB-page emulator, release on tag

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
EOF
```

### Task 8: `NOTICE` and `README.md`

**Files:**
- Create: `NOTICE`, `README.md`

**Interfaces:**
- Consumes: everything above (documents it). `NOTICE` is copied into `dist/` by `record.sh` (Task 6) and attached to releases (Task 7).

- [ ] **Step 1: Write `NOTICE`** (create this before running Task 6's test if executing out of order)

```text
media3-ffmpeg-lgpl
Copyright (c) 2026 the media3-ffmpeg-lgpl contributors

Licensed under the Apache License, Version 2.0 (see LICENSE). That licence covers what this
repository itself contributes: the build system, CI, scripts, tests and documentation.

--------------------------------------------------------------------------------------------

This repository includes the following files from Jetpack Media3
(https://github.com/androidx/media), tag 1.11.0, Copyright (C) The Android Open Source Project,
licensed under the Apache License, Version 2.0:

  lib/src/main/java/androidx/media3/decoder/ffmpeg/FfmpegAudioDecoder.java
  lib/src/main/java/androidx/media3/decoder/ffmpeg/FfmpegAudioRenderer.java
  lib/src/main/java/androidx/media3/decoder/ffmpeg/FfmpegDecoderException.java
  lib/src/main/java/androidx/media3/decoder/ffmpeg/FfmpegLibrary.java   (MODIFIED - see below)
  lib/src/main/java/androidx/media3/decoder/ffmpeg/package-info.java
  lib/src/main/jni/ffmpeg_jni.cc
  lib/consumer-rules.pro                                                (first two rules)

Modification (Apache License 2.0, section 4(b)): FfmpegLibrary.java loads libavutil,
libswresample and libavcodec before libffmpegJNI, because this distribution links FFmpeg
dynamically rather than statically. The change is marked in the file. Nothing else is changed.

--------------------------------------------------------------------------------------------

The build output (the .aar) contains FFmpeg (https://ffmpeg.org), Copyright (c) the FFmpeg
developers, licensed under the GNU Lesser General Public License, version 2.1 or later
(https://www.gnu.org/licenses/old-licenses/lgpl-2.1.html).

FFmpeg is NOT included in this repository. It is fetched from source at the tag pinned in
gradle.properties (ffmpeg.tag) and built unmodified with --disable-gpl --disable-nonfree, so
only LGPL components are present. The exact tag, commit, configure options and checksums of
each build are in BUILD_RECORD.md, attached to every release together with a source archive
of that exact commit.

FFmpeg is linked dynamically: libavutil.so, libswresample.so and libavcodec.so are separate
files inside the .aar and may be replaced by any compatible build.

Codec patents (Dolby AC-3, E-AC-3 and TrueHD; DTS; and others) are not licensed by this
project, and no open-source licence covers them. Whether a patent licence is needed depends on
what you ship, where, and to whom.
```

- [ ] **Step 2: Write `README.md`**

````markdown
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

Linux or macOS (on Windows use WSL; the NDK ships no Windows-native FFmpeg toolchain path we
support). Needs `git`, `make`, a JDK 21, and the Android NDK:

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
````

- [ ] **Step 3: Verify every path the README and NOTICE mention exists**

Run:
```bash
for p in ffmpeg/build.sh ffmpeg/verify.sh ffmpeg/record.sh lib/consumer-rules.pro lib/src/main/jni/ffmpeg_jni.cc \
  lib/src/main/java/androidx/media3/decoder/ffmpeg/FfmpegLibrary.java gradle.properties LICENSE NOTICE .github/workflows/build.yml; do
  [[ -e "$p" ]] && echo "ok  $p" || echo "MISSING $p"; done
```
Expected: every line `ok`.

- [ ] **Step 4: Commit**

```bash
git add -A && git -c user.email="indiananimeserver@gmail.com" -c user.name="Karti" commit -q -F - <<'EOF'
NOTICE and README: what is inside, what CI proves, what shipping it obliges

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
EOF
```

### Task 9: Whole-repository verification and hand-off notes

**Files:** none new. Modify nothing unless a check fails.

- [ ] **Step 1: Run every local check in one go**

```bash
cd /d/android_app/media3-ffmpeg-lgpl
bash -n ffmpeg/build.sh ffmpeg/verify.sh ffmpeg/record.sh
bash ffmpeg/test/test_build_config.sh && bash ffmpeg/test/test_verify.sh && bash ffmpeg/test/test_record.sh
./gradlew.bat help :lib:compileReleaseJavaWithJavac :lib:compileDebugAndroidTestJavaWithJavac --console=plain 2>&1 | grep -E "^e:|error:|BUILD"
./gradlew.bat :lib:assembleRelease --console=plain 2>&1 | grep -E "FFmpeg has not been built|BUILD"
git status --short
```
Expected: three `OK` lines, `BUILD SUCCESSFUL`, then the guard message + `BUILD FAILED`, and an empty `git status`.

- [ ] **Step 2: Confirm nothing generated is tracked**

Run: `git ls-files | grep -E "^(ffmpeg/(src|out)|lib/src/main/jniLibs|dist|build)/" || echo "clean"`
Expected: `clean`

- [ ] **Step 3: Record the hand-off in the final report to the owner** (not a file): create the GitHub repository, replace `CHANGEME` in `gradle.properties`, `README.md` and `lib/build.gradle.kts`, `git remote add origin … && git push -u origin main`, watch the `build` workflow, then `git tag v1.11.0-1 && git push origin v1.11.0-1` for the first release. After that: integrate into DV Player per spec §11.

---

## Plan self-review

**Spec coverage.** §5 layout → Tasks 1, 2, 4-8. §6 properties → Task 1. §7.1 build.sh → Task 4 (every listed flag appears in `configure_args` and is asserted by its test). §7.2 Gradle → Task 2 Step 6 (guard scoped to packaging tasks, CMake conditional, BuildConfig fields, deps incl. `checker-qual`, publishing). §7.3 CMake → Task 2 Step 5 (page size now from `FFMPEG_PAGE_SIZE`). §7.4 sources + modification → Task 2 Steps 1-2. §7.5 consumer rules → Task 2 Step 4. §7.6 verify → Task 5 (all ten rows of the spec table). §7.7 record → Task 6 (extraction dir moved from `dist/aar` to `build/verify/aar` so `dist/` holds only release files; spec §7.7 wording should be read with that substitution). §7.8 smoke test → Task 3. §8 CI → Task 7 (three jobs, artifacts, release assets incl. `LICENSE`, which the spec omitted). §9 versioning → README (Task 8) + CI tag handling. §10 licensing → Task 8. §11 integration → README + hand-off. §12/§13 → covered by the checks above.

**Placeholders.** `io.github.CHANGEME` / `CHANGEME` are deliberate owner-supplied values listed in spec §14, not gaps. No TBD/TODO.

**Type/name consistency.** Script env overrides: `FFMPEG_OUT_DIR` (verify, record), `FFMPEG_SRC_DIR`, `DIST_DIR`, `EXTRACTED_DIR` (record), `FFMPEG_HOST_TAG` (build) — used identically in scripts and tests. AAR name `media3-ffmpeg-lgpl-release.aar` (from `base.archivesName`) is what verify defaults to and CI passes to record. `BuildConfig.FFMPEG_DECODERS` defined in Task 2, read in Task 3. JNI symbol names in Task 5 match the `LIBRARY_FUNC`/`AUDIO_DECODER_FUNC` macros in upstream `ffmpeg_jni.cc`.
