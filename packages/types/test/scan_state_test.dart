import 'package:cadence_types/cadence_types.dart';
import 'package:test/test.dart';

void main() {
  test('every state round-trips through its wire name', () {
    for (final state in ScanState.values) {
      expect(ScanState.values.byName(state.name), state);
    }
  });

  test('the queue states the daemon writes are members', () {
    // What PersistentScanQueue puts on the wire before and between
    // attempts; a reader that only knew the coordinator's states threw
    // on both.
    expect(ScanState.values.byName('queued'), ScanState.queued);
    expect(ScanState.values.byName('interrupted'), ScanState.interrupted);
  });

  test('pending, in motion and running partition the states', () {
    for (final state in ScanState.values) {
      expect(state.pending && state.inMotion, isFalse, reason: state.name);
      expect(
        state.running,
        state.pending || state.inMotion,
        reason: state.name,
      );
    }
    expect(ScanState.values.where((s) => s.pending), [
      ScanState.queued,
      ScanState.interrupted,
    ]);
    expect(ScanState.values.where((s) => !s.running), [
      ScanState.idle,
      ScanState.done,
      ScanState.failed,
      ScanState.cancelled,
    ]);
  });

  test('library types are named as the wire spells them', () {
    for (final type in LibraryType.values) {
      expect(LibraryType.values.byName(type.name), type);
    }
  });
}
