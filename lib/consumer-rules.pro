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
