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
