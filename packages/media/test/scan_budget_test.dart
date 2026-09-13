import 'package:cadence_media/cadence_media.dart';
import 'package:test/test.dart';

void main() {
  group('ScanBudget', () {
    late List<Duration> waits;
    late DateTime clock;
    ScanBudget budget(int? rate) => ScanBudget(
      bytesPerSecond: rate,
      wait: (d) async => waits.add(d),
      now: () => clock,
    );
    setUp(() {
      waits = [];
      clock = DateTime(2026, 9, 12, 20);
    });

    test('no rate is no waiting, however much is read', () async {
      final b = budget(null);
      await b.charge(1 << 30);
      await b.charge(1 << 30);
      expect(waits, isEmpty);
      expect(b.limited, isFalse);
      expect(b.toJson(), {'bytesPerSecond': null});
    });

    test('zero means no rate too, and negatives are refused', () {
      expect(budget(0).limited, isFalse);
      expect(() => budget(-1), throwsArgumentError);
    });

    test(
      'a second of reading at once is free; past it, the excess waits',
      () async {
        final b = budget(1000);
        await b.charge(1000);
        expect(waits, isEmpty, reason: 'one second deep');
        await b.charge(500);
        expect(waits, [const Duration(milliseconds: 500)]);
      },
    );

    test('time passing pays the debt down at the rate', () async {
      final b = budget(1000);
      await b.charge(1000);
      clock = clock.add(const Duration(milliseconds: 750));
      await b.charge(1000);
      // 1000 owed, 750 earned: 250 left, plus 1000 read = 1250, 250 over.
      expect(waits, [const Duration(milliseconds: 250)]);
    });

    test('the cost of a file is capped by what its readers touch', () {
      expect(ScanBudget.discoverCost(100), 100);
      expect(ScanBudget.discoverCost(1 << 30), 2 * sampledSpan);
      expect(ScanBudget.enrichCost(100), 100);
      expect(ScanBudget.enrichCost(1 << 30), sampledSpan);
    });

    test('lifting the rate forgives the debt', () async {
      final b = budget(1000);
      await b.charge(5000);
      b.bytesPerSecond = null;
      b.bytesPerSecond = 1000;
      await b.charge(1000);
      expect(waits, hasLength(1), reason: 'only the first overrun waited');
    });
  });
}
