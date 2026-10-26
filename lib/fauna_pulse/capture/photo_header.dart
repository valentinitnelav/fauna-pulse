// FaunaPulse (round 326): the pixel size of a photo, read from its file header, and the one
// rule for decoding photos in Dart.
//
// Photos can come from an imported FaunaLapse zip, so their bytes are user input. A file
// header can claim a size far larger than the file (30,000 x 30,000 px in a few hundred
// bytes), and a PNG's compressed data can unpack to gigabytes behind a small header. So Dart
// decodes only JPEGs whose frame header fits [kMaxPhotoPixels] ([decodeJpegWithinLimit]);
// every other photo goes to Android's decoder, which has the same limit (MAX_DECODE_PIXELS in
// the plugin's YOLOPlugin.kt) and reads only the rows it needs.

import 'dart:typed_data';

import 'package:image/image.dart' as img;

/// Photos above this many pixels are refused before any decode (round 326). A file header
/// can claim e.g. 30,000 x 30,000 px in a file of a few hundred bytes, which needs gigabytes
/// once decoded. Keep equal to MAX_DECODE_PIXELS in the plugin's YOLOPlugin.kt (the reason
/// for the value is there): a photo refused only by the native side would switch the rest of
/// the run to the slow pure-Dart path.
const kMaxPhotoPixels = 120000000;

/// Throws a FormatException when the header of [bytes] claims more than [kMaxPhotoPixels].
/// A header that cannot be read is left to the decoders, which then fail on their own.
void checkPhotoPixels(Uint8List bytes) {
  final dims = photoDimensions(bytes);
  if (dims != null && !photoFitsPixelLimit(dims)) {
    throw FormatException(
      'photo of ${dims.$1} x ${dims.$2} px is larger than '
      '${kMaxPhotoPixels ~/ 1000000} megapixels',
    );
  }
}

/// Whether [dims] (width, height) stays within [kMaxPhotoPixels].
bool photoFitsPixelLimit((int, int) dims) =>
    dims.$1 <= kMaxPhotoPixels && dims.$2 <= kMaxPhotoPixels && dims.$1 * dims.$2 <= kMaxPhotoPixels;

/// Width/height read from the photo's HEADER only (the JPEG frame header or the PNG IHDR
/// chunk): no pixel decode and no memory that grows with the claimed size. The image
/// package's `startDecode` is not used: it prepares buffers for the claimed size, so a
/// crafted 30,000 x 30,000 px JPEG of 700 bytes took gigabytes. Null for other formats or
/// corrupt bytes.
(int, int)? photoDimensions(Uint8List bytes) {
  if (bytes.length >= 24 && bytes[0] == 0x89 && bytes[1] == 0x50 && bytes[2] == 0x4E && bytes[3] == 0x47) {
    final d = ByteData.sublistView(bytes);
    final (w, h) = (d.getUint32(16), d.getUint32(20));
    return w > 0 && h > 0 ? (w, h) : null;
  }
  return jpegDimensions(bytes);
}

// JPEG start-of-frame markers (baseline, extended, progressive, lossless and their
// arithmetic-coded forms); 0xC4, 0xC8 and 0xCC are other segments.
const _jpegFrameMarkers = {0xC0, 0xC1, 0xC2, 0xC3, 0xC5, 0xC6, 0xC7, 0xC9, 0xCA, 0xCB, 0xCD, 0xCE, 0xCF};

/// Width/height read from the JPEG HEADER only (see [photoDimensions]); microseconds
/// instead of the ~100 ms a full 1024 px decode costs. The native tiled path needs the
/// dimensions BEFORE the photo crosses the channel, to plan the tile grid in Dart. Null for
/// non-JPEG/corrupt bytes (SAHI then sends the photo to one native whole-photo pass).
(int, int)? jpegDimensions(Uint8List bytes) {
  if (bytes.length < 4 || bytes[0] != 0xFF || bytes[1] != 0xD8) return null;
  // Walk the segments: FF, marker, then (for most markers) a 2-byte length that counts
  // itself, up to the frame header, which holds precision (1 byte), height and width.
  var i = 2;
  while (i + 3 < bytes.length) {
    if (bytes[i] != 0xFF) return null;
    final marker = bytes[i + 1];
    if (marker == 0xFF) {
      i++; // fill byte
    } else if (marker == 0x01 || (marker >= 0xD0 && marker <= 0xD8)) {
      i += 2; // markers without a length
    } else if (marker == 0xD9 || marker == 0xDA) {
      return null; // end of image or start of the picture data before any frame header
    } else {
      final length = (bytes[i + 2] << 8) | bytes[i + 3];
      if (length < 2) return null;
      if (_jpegFrameMarkers.contains(marker)) {
        if (i + 8 >= bytes.length) return null;
        final h = (bytes[i + 5] << 8) | bytes[i + 6];
        final w = (bytes[i + 7] << 8) | bytes[i + 8];
        return w > 0 && h > 0 ? (w, h) : null;
      }
      i += 2 + length;
    }
  }
  return null;
}

/// [bytes] decoded in Dart, or null unless it is a JPEG whose frame header fits
/// [kMaxPhotoPixels] (a JPEG decode never allocates more than its frame header says).
img.Image? decodeJpegWithinLimit(Uint8List bytes) {
  final dims = jpegDimensions(bytes);
  if (dims == null || !photoFitsPixelLimit(dims)) return null;
  try {
    return img.decodeJpg(bytes);
  } catch (_) {
    return null; // corrupt or truncated file
  }
}
