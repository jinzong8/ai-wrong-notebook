import 'dart:io';
import 'dart:isolate';

import 'package:crypto/crypto.dart';

/// Files larger than 256 KB are streamed inside a background isolate so ~75 MB
/// APKs use minimal memory and never block UI frames, while tiny synthetic test
/// payloads verify synchronously without hanging widget-test FakeAsync zones.
const int _kIsolateThresholdBytes = 256 * 1024;

/// Verifies that a downloaded `.apk` file is complete, begins with a valid ZIP
/// local-file signature (`PK\x03\x04`), matches [expectedSize] (when > 0), and
/// matches [expectedSha256Hex] (when non-empty).
Future<bool> verifyApkFileIntegrity({
  required String filePath,
  int? expectedSize,
  String? expectedSha256Hex,
}) async {
  final normalizedExpectedHash = expectedSha256Hex?.trim().toLowerCase();
  final file = File(filePath);
  if (!file.existsSync()) return false;
  final actualSize = file.lengthSync();
  if (actualSize < 4) return false;
  if (expectedSize != null && expectedSize > 0 && actualSize != expectedSize) {
    return false;
  }

  if (actualSize <= _kIsolateThresholdBytes) {
    final bytes = file.readAsBytesSync();
    if (bytes.length < 4 ||
        bytes[0] != 0x50 ||
        bytes[1] != 0x4B ||
        bytes[2] != 0x03 ||
        bytes[3] != 0x04) {
      return false;
    }
    if (normalizedExpectedHash != null && normalizedExpectedHash.isNotEmpty) {
      final actualHash = sha256.convert(bytes).toString().toLowerCase();
      if (actualHash != normalizedExpectedHash) {
        return false;
      }
    }
    return true;
  }

  return Isolate.run(() async {
    final isoFile = File(filePath);
    if (!isoFile.existsSync()) return false;
    final raf = isoFile.openSync(mode: FileMode.read);
    try {
      final magic = raf.readSync(4);
      if (magic.length < 4 ||
          magic[0] != 0x50 ||
          magic[1] != 0x4B ||
          magic[2] != 0x03 ||
          magic[3] != 0x04) {
        return false;
      }
    } finally {
      raf.closeSync();
    }

    if (normalizedExpectedHash != null && normalizedExpectedHash.isNotEmpty) {
      final digest = await sha256.bind(isoFile.openRead()).first;
      if (digest.toString().toLowerCase() != normalizedExpectedHash) {
        return false;
      }
    }
    return true;
  });
}
