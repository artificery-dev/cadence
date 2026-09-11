import 'package:cadence_media/cadence_media.dart';
import 'package:test/test.dart';

void main() {
  test('a queued job record reads as a pending, running status', () {
    final status = ScanStatus.fromJson({
      'jobId': 'epoch-1',
      'libraryId': 1,
      'state': 'queued',
      'attemptCount': 0,
    });
    expect(status.state, ScanState.queued);
    expect(status.state.pending, isTrue);
    expect(status.running, isTrue);
    expect(status.seen, 0);
  });

  test('an interrupted state reads as owed, not as walking', () {
    final status = ScanStatus.fromJson({'state': 'interrupted'});
    expect(status.state, ScanState.interrupted);
    expect(status.state.inMotion, isFalse);
    expect(status.running, isTrue);
  });

  test('the coordinator states round-trip through a snapshot', () {
    for (final state in ScanState.values) {
      final json = ScanSnapshot(state: state).toJson();
      expect(ScanStatus.fromJson(json).state, state, reason: state.name);
    }
  });

  test('a name off the contract still throws rather than guessing', () {
    expect(() => ScanStatus.fromJson({'state': 'paused'}), throwsArgumentError);
  });
}
