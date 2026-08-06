// AUTHORITATIVE on-device Argon2id measurement harness (DEV-P0-03 B2-5a-native
// stage 1a / TDR-2026-026).
//
// Run on a PHYSICAL device in PROFILE mode (debug numbers are misleading):
//   flutter test integration_test/argon2id_benchmark_test.dart --profile \
//     --dart-define=SANCTUM_BENCH_GRID=full --dart-define=SANCTUM_BENCH_SAMPLES=6
//
// Grid names: smoke (default, floor combo only — for a quick CI-safe check),
// p1 (all lanes=1 combos — pure-Dart fast path), full (director-approved grid).
//
// The result JSON is (a) printed to the test log and (b) written to the app
// documents dir as argon2id_benchmark_result.json for Eis to pull off-device.
// Numbers are read directly from this JSON into the evidence file (摘要數字紀律).
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:integration_test/integration_test.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider/path_provider.dart';
import 'package:sanctum/dev/argon2id_benchmark.dart';

const String _kGridName =
    String.fromEnvironment('SANCTUM_BENCH_GRID', defaultValue: 'smoke');
const int _kSamples =
    int.fromEnvironment('SANCTUM_BENCH_SAMPLES', defaultValue: 6);
// Authoritative runs must be profile/release. Set this only for a local dry-run.
const bool _kAllowDebug =
    bool.fromEnvironment('SANCTUM_BENCH_ALLOW_DEBUG', defaultValue: false);

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('Argon2id KEK-derive sweep ($_kGridName)', (tester) async {
    final grid = gridFromName(_kGridName);
    debugPrint('[argon2id-bench] build_mode='
        '${Argon2idBenchmark.currentBuildMode} '
        'backend=${Argon2idBenchmark.backendFingerprint()} '
        'grid=$_kGridName combos=${grid.length} samples=$_kSamples');

    if (Argon2idBenchmark.currentBuildMode == 'debug' && !_kAllowDebug) {
      debugPrint('[argon2id-bench] SKIPPED: refusing to record debug-mode '
          'timings. Re-run with --profile (or --dart-define='
          'SANCTUM_BENCH_ALLOW_DEBUG=true for a non-authoritative dry-run).');
      markTestSkipped('debug mode — not authoritative');
      return;
    }

    final result = await Argon2idBenchmark().run(
      grid,
      samplesPerCombo: _kSamples,
      allowDebugDryRun: _kAllowDebug,
      deviceModel: const String.fromEnvironment('SANCTUM_BENCH_MODEL',
          defaultValue: '').isEmpty
          ? null
          : const String.fromEnvironment('SANCTUM_BENCH_MODEL'),
      abi: const String.fromEnvironment('SANCTUM_BENCH_ABI', defaultValue: '')
              .isEmpty
          ? null
          : const String.fromEnvironment('SANCTUM_BENCH_ABI'),
      apiLevel: const int.fromEnvironment('SANCTUM_BENCH_API', defaultValue: 0) ==
              0
          ? null
          : const int.fromEnvironment('SANCTUM_BENCH_API'),
      onProgress: (m) => debugPrint('[argon2id-bench] $m'),
    );

    final json = result.toJsonString();
    debugPrint('[argon2id-bench] RESULT JSON >>>');
    // debugPrint truncates long lines; chunk so the full JSON reaches the log.
    for (final line in const LineSplitter().convert(json)) {
      debugPrint(line);
    }
    debugPrint('[argon2id-bench] <<< RESULT JSON');

    final dir = await getApplicationDocumentsDirectory();
    final file = File('${dir.path}/argon2id_benchmark_result.json');
    await file.writeAsString(json);
    debugPrint('[argon2id-bench] written: ${file.path}');

    // Sanity invariants (not timing assertions — timing is data, not pass/fail).
    expect(result.results, isNotEmpty);
    for (final r in result.measured) {
      expect(r.combo.belowFloor, isFalse,
          reason: 'a measured combo must be >= floor');
      expect(r.sampleMs.length, _kSamples);
    }
  }, timeout: const Timeout(Duration(minutes: 30)));
}
