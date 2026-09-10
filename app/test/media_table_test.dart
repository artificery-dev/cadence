import 'package:cadence/src/model/view_prefs.dart';
import 'package:cadence/src/widgets/media_table.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tomeui/tomeui.dart';

void main() {
  testWidgets('a clipped cell speaks its whole text on hover; a fitting '
      'one stays silent', (tester) async {
    tester.view.physicalSize = const Size(600, 400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    const long = 'An Impossibly Long Title That Cannot Fit';
    await tester.pumpWidget(
      TomeApp(
        home: Scaffold(
          body: MediaTable<String>(
            items: const [long, 'Short'],
            prefs: const ViewPrefs(),
            onPrefs: (_) {},
            columns: [
              MediaColumn<String>(
                id: 'title',
                label: 'Title',
                width: 120,
                cell: (context, item) => tableText(context, item),
              ),
            ],
          ),
        ),
      ),
    );
    await tester.pump();

    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: Offset.zero);
    addTearDown(mouse.removePointer);

    // The long title is ellipsised into its 120px column; lingering on
    // it speaks the whole thing.
    await mouse.moveTo(tester.getCenter(find.text(long)));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pump();
    expect(find.text(long), findsNWidgets(2), reason: 'cell and tooltip');

    // The short one fits, so hovering it says nothing new.
    await mouse.moveTo(tester.getCenter(find.text('Short')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pump();
    expect(find.text('Short'), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
  });
}
