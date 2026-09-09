/// The pinned 64-bit SimHash of document text — near prose, near hash.
///
/// This algorithm is a cross-language contract: the Rust probe implements
/// it bit for bit, and `test/fixtures/simhash_vectors.json` holds vectors
/// both sides must reproduce. Never change it without versioning the hash
/// kind. The steps, precisely:
///
/// 1. Normalize: lowercase the text, then turn every run of characters
///    outside ASCII `a–z0–9` (accented letters and em-dashes included —
///    anything non-ASCII is a separator) into a single space, and trim.
/// 2. Split on single spaces into words.
/// 3. Take 3-word shingles — consecutive, overlapping. A text with fewer
///    than three words contributes its whole normalized string as the one
///    shingle, the empty text included.
/// 4. Hash each shingle's UTF-8 bytes with FNV-1a 64: offset basis
///    0xcbf29ce484222325, prime 0x100000001b3, wrapping multiplication.
/// 5. Classic SimHash bit-vote: 64 counters, +1 where a shingle hash has
///    the bit set and −1 where it hasn't; the final bit is set where its
///    counter ends above zero.
/// 6. Render as 16 lowercase hex digits.
library;

import 'dart:convert';

/// The SimHash of [text], as 16 lowercase hex digits.
String simHash(String text) {
  final votes = List<int>.filled(64, 0);
  for (final shingle in _shingles(text)) {
    final hash = fnv1a64(utf8.encode(shingle));
    for (var bit = 0; bit < 64; bit++) {
      votes[bit] += (hash >>> bit) & 1 == 1 ? 1 : -1;
    }
  }
  var hash = 0;
  for (var bit = 0; bit < 64; bit++) {
    if (votes[bit] > 0) hash |= 1 << bit;
  }
  return _hex64(hash);
}

/// How many bits two hex-rendered hashes disagree on — 0 is the same
/// text re-flowed, ~32 is strangers.
int hammingDistance(String aHex, String bHex) {
  var diff = _parseHex64(aHex) ^ _parseHex64(bHex);
  var count = 0;
  while (diff != 0) {
    diff &= diff - 1;
    count++;
  }
  return count;
}

/// FNV-1a 64 over [bytes], wrapping — the shingle hash the vote counts.
int fnv1a64(List<int> bytes) {
  var hash = 0xcbf29ce484222325;
  for (final byte in bytes) {
    hash ^= byte;
    hash *= 0x100000001b3;
  }
  return hash;
}

List<String> _shingles(String text) {
  final normalized = text
      .toLowerCase()
      .replaceAll(RegExp(r'[^a-z0-9]+'), ' ')
      .trim();
  final words = normalized.isEmpty ? const <String>[] : normalized.split(' ');
  if (words.length < 3) return [normalized];
  return [
    for (var i = 0; i + 3 <= words.length; i++)
      '${words[i]} ${words[i + 1]} ${words[i + 2]}',
  ];
}

String _hex64(int value) =>
    (value >>> 32).toRadixString(16).padLeft(8, '0') +
    (value & 0xffffffff).toRadixString(16).padLeft(8, '0');

int _parseHex64(String hex) {
  final padded = hex.padLeft(16, '0');
  final high = int.parse(padded.substring(0, 8), radix: 16);
  final low = int.parse(padded.substring(8), radix: 16);
  return (high << 32) | low;
}
