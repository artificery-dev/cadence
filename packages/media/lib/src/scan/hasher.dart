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

/// How much of each end of a file the sampled hash reads: 1 MiB from the
/// head, 1 MiB from the tail. Tags live at the ends (ID3v2 at the head,
/// ID3v1 and APE at the tail; FLAC and MP4 keep theirs up front), so a
/// retag moves this hash the way it moves the full one.
const int sampledSpan = 1024 * 1024;

/// A fixed-budget identity hash: sha256 over the first [span] bytes, the
/// last [span] bytes, and the file's size as eight little-endian bytes —
/// so two files of different lengths never collide on shared ends. A
/// file no longer than twice [span] hashes whole (plus the size), and the
/// result is still not a plain sha256 of it: this is `HashKind.
/// sampledSha256`, and is only ever compared with itself.
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
