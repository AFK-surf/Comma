package surf.comma.android.media;

import android.graphics.ImageDecoder;
import java.io.FileDescriptor;
import java.io.FileInputStream;
import java.io.IOException;
import java.nio.ByteBuffer;
import org.robolectric.annotation.Implementation;
import org.robolectric.annotation.Implements;
import org.robolectric.shadows.ShadowNativeImageDecoder;
import org.robolectric.util.ReflectionHelpers;
import org.robolectric.util.ReflectionHelpers.ClassParameter;

/**
 * Host Skia cannot decode Android file descriptors at API 35. Bridge just the input transport
 * to bytes; native ImageDecoder still performs EXIF orientation, sampling, and pixel decoding.
 * Production always uses the resolver-backed descriptor. Test images are generated in memory.
 */
@Implements(value = ImageDecoder.class, minSdk = 35, callNativeMethodsByDefault = true)
public class JvmImageDecoder extends ShadowNativeImageDecoder {
    @Implementation
    protected static ImageDecoder nCreate(FileDescriptor fd, long length, boolean animated,
                                           ImageDecoder.Source source) throws IOException {
        // The platform source owns fd; do not close it through this temporary wrapper.
        byte[] bytes = new FileInputStream(fd).readAllBytes();
        return ReflectionHelpers.callStaticMethod(ImageDecoder.class, "nCreate",
                ClassParameter.from(ByteBuffer.class, ByteBuffer.wrap(bytes)),
                ClassParameter.from(int.class, 0),
                ClassParameter.from(int.class, bytes.length),
                ClassParameter.from(boolean.class, animated),
                ClassParameter.from(ImageDecoder.Source.class, source));
    }
}
