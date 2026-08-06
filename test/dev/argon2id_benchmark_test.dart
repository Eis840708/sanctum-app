// Host-side LOGIC tests for the Argon2id benchmark harness (DEV-P0-03
// B2-5a-native stage 1a). These verify floor enforcement, statistics, the
// debug-mode refusal and JSON shape — NOT timing. Real timing is measured
// on-device only (integration_test/argon2id_benchmark_test.dart), never here.
import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sanctum/core/crypto/v3/vault_v3_keys.dart';
import 'package:sanctum/dev/argon2id_benchmark.dart';

/// A hierarchy whose KEK derivation returns instantly, so happy-path tests do
/// not actually run Argon2id (keeps logic tests fast and deterministic).
class _FastHierarchy extends VaultV3KeyHierarchy {
  @override
  Future<SecretKey> deriveKek({
    required String password,
    required KdfDescriptor descriptor,
  }) async =>
      SecretKey(List<int>.filled(32, 7));
}

void main() {
  group('grid builders', () {
    test('default grid is all >= floor', () {
      final grid = Argon2idBenchmark.defaultGrid();
      expect(grid, isNotEmpty);
      for (final c in grid) {
        expect(c.belowFloor, isFalse, reason: c.label);
      }
    });

    test('p1 subset is all lanes == 1', () {
      final subset = Argon2idBenchmark.p1Subset();
      expect(subset, isNotEmpty);
      expect(subset.every((c) => c.lanes == 1), isTrue);
    });

    test('smoke grid is exactly the floor combo', () {
      final smoke = Argon2idBenchmark.smokeGrid();
      expect(smoke.length, 1);
      expect(smoke.single.memoryKib, KdfDescriptor.floorMemoryKib);
      expect(smoke.single.iterations, KdfDescriptor.floorIterations);
      expect(smoke.single.lanes, KdfDescriptor.floorLanes);
    });

    test('gridFromName resolves names', () {
      expect(gridFromName('full').length,
          Argon2idBenchmark.defaultGrid().length);
      expect(gridFromName('p1').length, Argon2idBenchmark.p1Subset().length);
      expect(gridFromName('smoke').length, 1);
      expect(gridFromName('unknown').length, 1); // defaults to smoke
    });
  });

  group('belowFloor', () {
    test('sub-floor combos flagged', () {
      expect(
          const Argon2idParamCombo(memoryKib: 18 * 1024, iterations: 2, lanes: 1)
              .belowFloor,
          isTrue);
      expect(
          const Argon2idParamCombo(
                  memoryKib: 19 * 1024, iterations: 1, lanes: 1)
              .belowFloor,
          isTrue);
      expect(
          const Argon2idParamCombo(
                  memoryKib: 19 * 1024, iterations: 2, lanes: 0)
              .belowFloor,
          isTrue);
      expect(
          const Argon2idParamCombo(
                  memoryKib: 19 * 1024, iterations: 2, lanes: 1)
              .belowFloor,
          isFalse);
    });
  });

  group('measureCombo floor enforcement', () {
    test('sub-floor combo is rejected, never timed', () async {
      final bench = Argon2idBenchmark(hierarchy: _FastHierarchy());
      final r = await bench.measureCombo(
        const Argon2idParamCombo(memoryKib: 10 * 1024, iterations: 2, lanes: 1),
        samples: 6,
      );
      expect(r.isRejected, isTrue);
      expect(r.rejectedReason, isNotNull);
      expect(r.sampleMs, isEmpty);
    });

    test('valid combo yields exactly `samples` timed values + warm-up', () async {
      final bench = Argon2idBenchmark(hierarchy: _FastHierarchy());
      final r = await bench.measureCombo(
        const Argon2idParamCombo(memoryKib: 19 * 1024, iterations: 2, lanes: 1),
        samples: 6,
      );
      expect(r.isRejected, isFalse);
      expect(r.sampleMs.length, 6);
      expect(r.discardedWarmupMs, isNotNull);
    });
  });

  group('statistics', () {
    Argon2idComboResult withSamples(List<double> ms) =>
        Argon2idComboResult.measured(
          combo: const Argon2idParamCombo(
              memoryKib: 19 * 1024, iterations: 2, lanes: 1),
          discardedWarmupMs: 999,
          sampleMs: ms,
        );

    test('median odd/even, min, max, mean', () {
      final odd = withSamples(<double>[30, 10, 20, 50, 40]);
      expect(odd.medianMs, 30);
      expect(odd.minMs, 10);
      expect(odd.maxMs, 50);
      expect(odd.meanMs, 30);

      final even = withSamples(<double>[10, 20, 30, 40]);
      expect(even.medianMs, 25);
    });

    test('stddev of constant samples is zero', () {
      expect(withSamples(<double>[20, 20, 20]).stddevMs, 0);
    });

    test('thermal suspected when monotonically rising', () {
      expect(withSamples(<double>[10, 12, 15, 20]).thermalSuspected, isTrue);
      expect(withSamples(<double>[10, 12, 11, 20]).thermalSuspected, isFalse);
    });
  });

  group('run() debug-mode refusal', () {
    test('throws in debug mode without override', () async {
      // `flutter test` runs in debug mode.
      final bench = Argon2idBenchmark(hierarchy: _FastHierarchy());
      await expectLater(
        bench.run(Argon2idBenchmark.smokeGrid(),
            cooldownBetweenCombos: Duration.zero),
        throwsA(isA<DebugModeMeasurementRefused>()),
      );
    });

    test('allowDebugDryRun bypasses the refusal and records mode', () async {
      final bench = Argon2idBenchmark(hierarchy: _FastHierarchy());
      final result = await bench.run(
        Argon2idBenchmark.smokeGrid(),
        samplesPerCombo: 3,
        allowDebugDryRun: true,
        cooldownBetweenCombos: Duration.zero,
      );
      expect(result.buildMode, 'debug');
      expect(result.measured.single.sampleMs.length, 3);
      expect(result.rejected, isEmpty);
    });
  });

  group('JSON shape', () {
    test('result JSON carries device/run/samples/rejected sections', () async {
      final bench = Argon2idBenchmark(hierarchy: _FastHierarchy());
      final result = await bench.run(
        <Argon2idParamCombo>[
          const Argon2idParamCombo(
              memoryKib: 19 * 1024, iterations: 2, lanes: 1),
          const Argon2idParamCombo(
              memoryKib: 8 * 1024, iterations: 2, lanes: 1), // sub-floor
        ],
        samplesPerCombo: 2,
        allowDebugDryRun: true,
        cooldownBetweenCombos: Duration.zero,
        deviceModel: 'TEST-MODEL',
        abi: 'armeabi-v7a',
        apiLevel: 24,
      );
      final json = result.toJson();
      expect(json['harness'], 'b2-5a-argon2id');
      expect((json['device']! as Map)['model'], 'TEST-MODEL');
      expect((json['device']! as Map)['api'], 24);
      expect((json['run']! as Map)['build_mode'], 'debug');
      expect((json['samples']! as List).length, 1);
      expect((json['rejected_below_floor']! as List).length, 1);
      expect(result.toJsonString(), contains('b2-5a-argon2id'));
    });
  });
}
