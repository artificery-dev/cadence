/// The image pHash, by hand — no wrapper library, so the algorithm is ours
/// to pin and never drift.
///
/// The pipeline, exactly:
///
/// 1. decode (`package:image`), grayscale with its luminance weights;
/// 2. resize to 32×32, [img.Interpolation.average] so re-encodes and mild
///    rescales land on the same pixels;
/// 3. take the red channel as luma (grayscale made the channels agree);
/// 4. 2D DCT-II over the 32×32 grid, separable and unnormalized — the
///    threshold below compares coefficients to each other, so scale
///    factors cancel;
/// 5. keep the top-left 8×8 block in row-major order and drop the DC term,
///    leaving 63 coefficients;
/// 6. threshold at their median (the 32nd smallest of the 63);
/// 7. pack MSB-first in row-major order — the DC position is the top bit
///    and is always zero — setting a bit where its coefficient exceeds
///    the median;
/// 8. render as 16 lowercase hex digits.
///
/// Near-duplicates — a re-encode, a resize — differ in a handful of bits;
/// unrelated images disagree on roughly half. [hammingDistance] counts the
/// disagreement.
library;

import 'dart:math' as math;
import 'dart:typed_data';

import 'package:image/image.dart' as img;

/// The DCT grid is 32×32; the hash keeps its top-left 8×8.
const int _grid = 32;
const int _block = 8;

/// Hashes encoded image [bytes], or answers null when nothing in
/// `package:image` can decode them — a decoder that throws counts as a
/// decoder that couldn't.
String? perceptualHash(List<int> bytes) {
  final img.Image? decoded;
  try {
    decoded = img.decodeImage(
      bytes is Uint8List ? bytes : Uint8List.fromList(bytes),
    );
  } catch (_) {
    return null;
  }
  return decoded == null ? null : perceptualHashOf(decoded);
}

/// Hashes an already-decoded [image] — the pinned pipeline from the
/// library doc, starting at the grayscale step.
String perceptualHashOf(img.Image image) {
  final small = img.copyResize(
    img.grayscale(img.Image.from(image)),
    width: _grid,
    height: _grid,
    interpolation: img.Interpolation.average,
  );

  final luma = List.generate(
    _grid,
    (y) => List.generate(_grid, (x) => small.getPixel(x, y).r.toDouble()),
    growable: false,
  );

  final coefficients = _dctBlock(luma);
  final ranked = coefficients.sublist(1)..sort();
  final median = ranked[(ranked.length - 1) ~/ 2];

  var hash = 0;
  for (var i = 1; i < coefficients.length; i++) {
    if (coefficients[i] > median) {
      hash |= 1 << (coefficients.length - 1 - i);
    }
  }
  return hash.toRadixString(16).padLeft(16, '0');
}

/// How many bits two 64-bit hex hashes disagree on. Works on any pair of
/// equal-length hex strings — pHash against pHash, SimHash against SimHash.
int hammingDistance(String a, String b) {
  if (a.length != b.length) {
    throw ArgumentError('hash lengths differ: ${a.length} vs ${b.length}');
  }
  var distance = 0;
  for (var i = 0; i < a.length; i++) {
    var nibble = int.parse(a[i], radix: 16) ^ int.parse(b[i], radix: 16);
    while (nibble != 0) {
      distance += nibble & 1;
      nibble >>= 1;
    }
  }
  return distance;
}

/// The top-left [_block]×[_block] of the 2D DCT-II of [luma], row-major.
/// Separable: each row is transformed to [_block] frequency terms, then
/// each of those columns is transformed the same way.
List<double> _dctBlock(List<List<double>> luma) {
  final cos = List.generate(
    _block,
    (k) => List.generate(
      _grid,
      (i) => math.cos((2 * i + 1) * k * math.pi / (2 * _grid)),
      growable: false,
    ),
    growable: false,
  );

  final rows = List.generate(
    _grid,
    (y) => List.generate(_block, (v) {
      var sum = 0.0;
      for (var x = 0; x < _grid; x++) {
        sum += luma[y][x] * cos[v][x];
      }
      return sum;
    }, growable: false),
    growable: false,
  );

  final out = List<double>.filled(_block * _block, 0);
  for (var u = 0; u < _block; u++) {
    for (var v = 0; v < _block; v++) {
      var sum = 0.0;
      for (var y = 0; y < _grid; y++) {
        sum += rows[y][v] * cos[u][y];
      }
      out[u * _block + v] = sum;
    }
  }
  return out;
}
