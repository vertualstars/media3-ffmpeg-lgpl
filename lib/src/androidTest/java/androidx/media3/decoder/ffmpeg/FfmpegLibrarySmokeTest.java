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
 * <p>Same package as the library so it can call the package-private {@link
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
