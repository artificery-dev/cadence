import '../filesystem.dart';

import 'dart:typed_data';

import 'package:crypto/crypto.dart';

/// How much of a file rides in each read: 256KiB, large enough to keep the
/// disk busy, small enough that a worker never holds much in memory.
const int sha256ChunkSize = 256 * 1024;

/// How far into each end of a file the identity hash reads: one mebibyte
/// from the head, one from the tail. A file of twice this or less is read
/// whole.
const int sampledSpan = 1024 * 1024;

/// The identity hash, as lowercase hex: sha256 over the file's first
/// [span] bytes, its last [span] bytes, and its length as eight
/// little-endian bytes. A file of `2 * span` or less contributes every
/// byte once, then its length.
///
/// This is what names a file's bytes to the scanner: the same file
/// anywhere on disk answers with the same string, which is how a move is
/// told from a stranger. The read is a fixed two mebibytes however long
/// the file, so identifying a library costs minutes rather than the hours
/// a full read of every track would on a small player with a large card.
/// The trade is that two files differing only between the spans are one
/// file to the scanner - a deliberate near-duplicate can fool it; nothing
/// a library does by accident will.
///
/// The native probe library computes the same hash (`cadence_hash_file`),
/// and the two must agree byte for byte: a library hashed by one is
/// rescanned by the other.
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
