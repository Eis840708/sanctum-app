// DEV-P0-03-B2-2 — Unicode official NormalizationTest.txt conformance for the
// vendored `unorm` NFC/NFD used by the KDF (director ruling B2-2 §3.2.3).
//
// Verifies the vendored normalizer against the authoritative Unicode vectors,
// which is how the frozen data table is validated (not by reading the table).
// Data: test/crypto/data/NormalizationTest.txt (NormalizationTest-17.0.0.txt,
// SHA-256 5019ffd530751a741900c849c0e010332f142a3612234639bd200b82138a87db).
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sanctum/core/crypto/v3/vendor/unorm/unorm.dart' as unorm;

String _fromHexCodes(String field) {
  final codes = field
      .trim()
      .split(RegExp(r'\s+'))
      .where((s) => s.isNotEmpty)
      .map((s) => int.parse(s, radix: 16))
      .toList();
  return String.fromCharCodes(codes);
}

void main() {
  test('vendored NFC/NFD match Unicode NormalizationTest.txt (17.0.0)', () {
    final file = File('test/crypto/data/NormalizationTest.txt');
    expect(file.existsSync(), isTrue,
        reason: 'official vector file must be bundled');

    var checked = 0;
    var nfcFail = 0;
    var nfdFail = 0;
    final firstFailures = <String>[];

    for (final raw in file.readAsLinesSync()) {
      final line = raw.trim();
      if (line.isEmpty || line.startsWith('#') || line.startsWith('@')) {
        continue;
      }
      final cols = line.split(';');
      if (cols.length < 5) continue;

      final source = _fromHexCodes(cols[0]);
      final expNfc = _fromHexCodes(cols[1]);
      final expNfd = _fromHexCodes(cols[2]);

      // Invariant 1: c2 == NFC(c1); c3 == NFD(c1).
      if (unorm.nfc(source) != expNfc) {
        nfcFail++;
        if (firstFailures.length < 5) firstFailures.add('NFC: $line');
      }
      if (unorm.nfd(source) != expNfd) {
        nfdFail++;
        if (firstFailures.length < 5) firstFailures.add('NFD: $line');
      }
      checked++;
    }

    // Sanity: the file really parsed a large number of vectors.
    expect(checked, greaterThan(10000),
        reason: 'expected thousands of conformance rows, got $checked');
    expect(nfcFail, 0, reason: 'NFC mismatches; samples: $firstFailures');
    expect(nfdFail, 0, reason: 'NFD mismatches; samples: $firstFailures');
  });
}
