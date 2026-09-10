import 'dart:io';

import 'package:cadence/src/version.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('the version constant matches pubspec.yaml', () {
    final pubspec = File('pubspec.yaml').readAsStringSync();
    final declared = RegExp(
      r'^version: *([0-9][^+\s]*)',
      multiLine: true,
    ).firstMatch(pubspec)!.group(1);
    expect(appVersion, declared);
  });
}
