import '../filesystem.dart';

import 'dart:typed_data';

import 'package:crypto/crypto.dart';

/// How much of a file rides in each read: 256KiB, large enough to keep the
/// disk busy, small enough that a worker never holds a movie in memory.
const int sha256ChunkSize = 256 * 1024;

/// The file's sha256 as lowercase hex, streamed chunk by chunk — the whole
/// file passes through, but never all at once. This is the identity hash:
/// the same bytes anywhere on disk answer with the same string, which is
/// how the scanner tells a move from a stranger.
Future<String> sha256OfFile(
  String path, {
  FileSystem? fileSystem,
  int chunkSize = sha256ChunkSize,
}) async {
  if (chunkSize < 1) throw ArgumentError.value(chunkSize, "chunkSize");
  final file = await (fileSystem ?? mediaFileSystem).file(path).open();
  try {
    final holder = _DigestHolder();
    final input = sha256.startChunkedConversion(holder);
    while (true) {
      final chunk = await file.read(chunkSize);
      if (chunk.isEmpty) break;
      input.add(chunk);
    }
    input.close();
    return holder.digest.toString();
  } finally {
    await file.close();
  }
}

/// Default bytes sampled from each end for a temporary work fingerprint.
const int sampledSpan = 1024 * 1024;

/// Temporary fingerprint of head + tail + size (8-byte little-endian).
/// Small files contribute all bytes once, then size. This is not a persistent
/// identity: equal samples do not establish equal content. Never use it for
/// move matching or deduplication. The scanner currently uses job/path identity
/// for pending work and computes full SHA-256 before committing each file.
Future<String> sampledSha256OfFile(
  String path, {
  FileSystem? fileSystem,
  int span = sampledSpan,
}) async {
  if (span < 1) throw ArgumentError.value(span, "span");
  final file = await (fileSystem ?? mediaFileSystem).file(path).open();
  try {
    final size = await file.length();
    final holder = _DigestHolder();
    final input = sha256.startChunkedConversion(holder);
    Future<void> feed(int from, int count) async {
      await file.setPosition(from);
      var left = count;
      while (left > 0) {
        final chunk = await file.read(
          left < sha256ChunkSize ? left : sha256ChunkSize,
        );
        if (chunk.isEmpty) break;
        input.add(chunk);
        left -= chunk.length;
      }
    }

    if (size <= 2 * span) {
      await feed(0, size);
    } else {
      await feed(0, span);
      await feed(size - span, span);
    }
    final sizeBytes = ByteData(8)..setUint64(0, size, Endian.little);
    input.add(sizeBytes.buffer.asUint8List());
    input.close();
    return holder.digest.toString();
  } finally {
    await file.close();
  }
}

/// The one-slot sink a chunked conversion pours its answer into.
class _DigestHolder implements Sink<Digest> {
  Digest? _digest;

  Digest get digest => _digest!;

  @override
  void add(Digest data) => _digest = data;

  @override
  void close() {}
}
