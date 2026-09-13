import 'dart:math' as math;

import 'hasher.dart';

/// How fast a scan may read.
///
/// A scan on a small player shares its card with the decoder. Priorities
/// keep the decoder's reads first, but a scan at full speed still
/// saturates the card, and a Bluetooth link that was already busy breaks
/// up under it. So the host can set a budget in bytes a second - while a
/// track plays, say - and every reader the scan owns charges what it read
/// against it, waiting when it gets ahead. Null is no budget: read as fast
/// as the card allows.
///
/// The charge is an estimate the readers make from what they know - the
/// identity hash reads two mebibytes of a file at most, a tag pass or a
/// cover about one - rather than a count of bytes through the filesystem,
/// which would mean instrumenting every read. It is a pace, not a meter.
///
/// The budget is a token bucket a second deep: a scan may read one
/// second's worth at once, then waits until its debt is paid down at the
/// budget's rate. Changing the rate takes effect on the next charge.
class ScanBudget {
  ScanBudget({
    int? bytesPerSecond,
    this.wait = _sleep,
    this.now = DateTime.now,
  }) {
    this.bytesPerSecond = bytesPerSecond;
  }

  /// How the budget waits; a test hands in a recorder.
  final Future<void> Function(Duration) wait;

  /// Where the budget reads the time; a test hands in a clock.
  final DateTime Function() now;

  int? _bytesPerSecond;
  double _debt = 0;
  DateTime? _last;

  /// The rate, or null for no limit. Zero is no limit too, so a host can
  /// clear the budget by writing what it reads.
  int? get bytesPerSecond => _bytesPerSecond;
  set bytesPerSecond(int? value) {
    if (value != null && value < 0) {
      throw ArgumentError.value(
        value,
        'bytesPerSecond',
        'must not be negative',
      );
    }
    _bytesPerSecond = (value == null || value == 0) ? null : value;
    if (_bytesPerSecond == null) {
      _debt = 0;
      _last = null;
    }
  }

  bool get limited => _bytesPerSecond != null;

  /// What the identity hash costs to compute for a file of [sizeBytes].
  static int discoverCost(int sizeBytes) =>
      math.min(sizeBytes, 2 * sampledSpan);

  /// What a tag pass or a cover costs for a file of [sizeBytes]: the
  /// metadata sits at an end, and a cover within the first mebibyte.
  static int enrichCost(int sizeBytes) => math.min(sizeBytes, sampledSpan);

  /// Records a read of [bytes] and waits as long as the budget says.
  Future<void> charge(int bytes) async {
    final rate = _bytesPerSecond;
    if (rate == null || bytes <= 0) return;
    final now = this.now();
    final last = _last;
    if (last != null) {
      final earned = now.difference(last).inMicroseconds * rate / 1e6;
      _debt = math.max(0, _debt - earned);
    }
    _last = now;
    _debt += bytes;
    final over = _debt - rate;
    if (over > 0) {
      await wait(Duration(microseconds: (over * 1e6 / rate).round()));
    }
  }

  Map<String, Object?> toJson() => {'bytesPerSecond': bytesPerSecond};

  static Future<void> _sleep(Duration duration) =>
      Future<void>.delayed(duration);
}
