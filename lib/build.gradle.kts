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
