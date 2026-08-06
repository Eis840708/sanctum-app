// DEV / MEASUREMENT TOOLING — NOT wired into lib/main.dart, never referenced by
// the shipping app, so it is tree-shaken out of any release build.
//
// DEV-P0-03 B2-5a-native stage 1a (TDR-2026-026): on-device Argon2id KEK-derive
// measurement. Design: DEV-P0-03-B2-5a-native-argon2id-harness-design-v1.
// Director approval: DEV-P0-03-B2-5a-native-stage0-approval-director-v1.
//
// Hard invariants enforced in code (director ruling):
//   * build mode must be profile/release; measuring in debug is REFUSED (JIT
//     numbers are misleading) unless explicitly overridden for a dry-run.
//   * the security floor mem>=19MiB / t>=2 / p>=1 is never measured as an
//     "option": sub-floor combos are rejected via the SAME production guard
//     (KdfDescriptor.forNewParameters -> KdfFloorViolation) and only recorded
//     as rejected, never timed.
//   * synthetic passwords/salts only — no real vault material.
//
// This measures the real production KEK path (VaultV3KeyHierarchy.deriveKek),
// so whatever Argon2id backend the app ships (currently pure-Dart) is what gets
// timed. The backend fingerprint is recorded so pure-Dart vs a future native
// backend can be compared in one table.
import 'dart:convert';
import 'dart:io' show Platform;
import 'dart:math';

import 'package:cryptography/cryptography.dart';
import 'package:flutter/foundation.dart';

import '../core/crypto/v3/vault_v3_keys.dart';

/// One Argon2id parameter combination to measure.
class Argon2idParamCombo {
  const Argon2idParamCombo({
    required this.memoryKib,
    required this.iterations,
    required this.lanes,
    this.outLength = 32,
  });

  final int memoryKib;
  final int iterations;
  final int lanes;
  final int outLength;

  /// True when this combo sits below the production security floor. Such combos
  /// are recorded as rejected, never timed.
  bool get belowFloor =>
      memoryKib < KdfDescriptor.floorMemoryKib ||
      iterations < KdfDescriptor.floorIterations ||
      lanes < KdfDescriptor.floorLanes;

  String get label => '${memoryKib ~/ 1024}MiB/t$iterations/p$lanes';

  Map<String, Object?> toJson() => <String, Object?>{
        'mem_kib': memoryKib,
        'iterations': iterations,
        'lanes': lanes,
        'out_len': outLength,
      };
}

/// Result for one combo: either a set of timing samples or a rejection reason.
class Argon2idComboResult {
  Argon2idComboResult.measured({
    required this.combo,
    required this.discardedWarmupMs,
    required this.sampleMs,
  }) : rejectedReason = null;

  Argon2idComboResult.rejected({
    required this.combo,
    required this.rejectedReason,
  })  : discardedWarmupMs = null,
        sampleMs = const <double>[];

  final Argon2idParamCombo combo;
  final String? rejectedReason;

  /// First (warm-up / JIT) run, discarded from statistics but kept for the record.
  final double? discardedWarmupMs;

  /// Valid timing samples (warm-up already excluded).
  final List<double> sampleMs;

  bool get isRejected => rejectedReason != null;

  double get _sortedMedian {
    final s = List<double>.from(sampleMs)..sort();
    final n = s.length;
    if (n == 0) return double.nan;
    return n.isOdd ? s[n ~/ 2] : (s[n ~/ 2 - 1] + s[n ~/ 2]) / 2.0;
  }

  double get medianMs => _sortedMedian;
  double get minMs => sampleMs.isEmpty ? double.nan : sampleMs.reduce(min);
  double get maxMs => sampleMs.isEmpty ? double.nan : sampleMs.reduce(max);
  double get meanMs =>
      sampleMs.isEmpty ? double.nan : sampleMs.reduce((a, b) => a + b) / sampleMs.length;
  double get stddevMs {
    if (sampleMs.length < 2) return 0;
    final m = meanMs;
    final variance =
        sampleMs.map((x) => (x - m) * (x - m)).reduce((a, b) => a + b) /
            sampleMs.length;
    return sqrt(variance);
  }

  /// Heuristic: samples trending monotonically upward suggests thermal throttle.
  bool get thermalSuspected {
    if (sampleMs.length < 3) return false;
    for (var i = 1; i < sampleMs.length; i++) {
      if (sampleMs[i] < sampleMs[i - 1]) return false;
    }
    return true;
  }

  Map<String, Object?> toJson() => <String, Object?>{
        ...combo.toJson(),
        if (isRejected) 'rejected_reason': rejectedReason,
        if (!isRejected) ...<String, Object?>{
          'discarded_warmup_ms': discardedWarmupMs,
          'elapsed_ms': sampleMs,
          'median_ms': medianMs,
          'min_ms': minMs,
          'max_ms': maxMs,
          'mean_ms': meanMs,
          'stddev_ms': stddevMs,
          'thermal_suspected': thermalSuspected,
        },
      };
}

/// Full benchmark run: device/run metadata plus per-combo results.
class Argon2idBenchmarkResult {
  Argon2idBenchmarkResult({
    required this.buildMode,
    required this.backend,
    required this.deviceModel,
    required this.abi,
    required this.apiLevel,
    required this.batteryPct,
    required this.charging,
    required this.samplesPerCombo,
    required this.os,
    required this.osVersion,
    required this.numberOfProcessors,
    required this.dartVersion,
    required this.results,
  });

  /// 'profile' | 'release' | 'debug'.
  final String buildMode;

  /// Argon2id implementation fingerprint (e.g. 'DartArgon2id' for pure-Dart).
  final String backend;

  /// Runner-supplied device annotations (Dart cannot read Build.MODEL/ABI/API
  /// without a native channel; kept dependency-free by passing them in).
  final String? deviceModel;
  final String? abi;
  final int? apiLevel;
  final int? batteryPct;
  final bool? charging;

  final int samplesPerCombo;
  final String os;
  final String osVersion;
  final int numberOfProcessors;
  final String dartVersion;
  final List<Argon2idComboResult> results;

  List<Argon2idComboResult> get measured =>
      results.where((r) => !r.isRejected).toList();
  List<Argon2idComboResult> get rejected =>
      results.where((r) => r.isRejected).toList();

  Map<String, Object?> toJson() => <String, Object?>{
        'harness': 'b2-5a-argon2id',
        'schema': '1.0',
        'device': <String, Object?>{
          'model': deviceModel,
          'abi': abi,
          'api': apiLevel,
          'os': os,
          'os_version': osVersion,
          'num_processors': numberOfProcessors,
          'dart_version': dartVersion,
        },
        'run': <String, Object?>{
          'build_mode': buildMode,
          'backend': backend,
          'samples_per_combo': samplesPerCombo,
          'battery_pct': batteryPct,
          'charging': charging,
        },
        'samples': measured.map((r) => r.toJson()).toList(),
        'rejected_below_floor': rejected.map((r) => r.toJson()).toList(),
      };

  String toJsonString() =>
      const JsonEncoder.withIndent('  ').convert(toJson());
}

/// Raised when a measurement is attempted in debug mode without an explicit
/// dry-run override (director hard rule: never report debug-mode numbers).
class DebugModeMeasurementRefused implements Exception {
  const DebugModeMeasurementRefused();
  @override
  String toString() =>
      'DebugModeMeasurementRefused: Argon2id timing must run in profile/release '
      '(debug JIT numbers are misleading). Re-run with --profile, or pass '
      'allowDebugDryRun: true for a non-authoritative smoke check.';
}

/// On-device Argon2id KEK-derive benchmark (dev tooling).
class Argon2idBenchmark {
  Argon2idBenchmark({VaultV3KeyHierarchy? hierarchy})
      : _hierarchy = hierarchy ?? VaultV3KeyHierarchy();

  final VaultV3KeyHierarchy _hierarchy;

  /// Synthetic password used for timing. Argon2id cost is independent of
  /// password content/length, so a fixed synthetic string is representative and
  /// never touches real vault material.
  static const String syntheticPassword = 'sanctum-benchmark-synthetic-pw-0';

  /// Full sweep grid (all combos >= floor). Director-approved starting grid.
  static List<Argon2idParamCombo> defaultGrid() {
    const mems = <int>[19 * 1024, 32 * 1024, 46 * 1024, 64 * 1024];
    const iters = <int>[2, 3, 4];
    const lanesList = <int>[1, 2, 4];
    return <Argon2idParamCombo>[
      for (final m in mems)
        for (final t in iters)
          for (final p in lanesList)
            Argon2idParamCombo(memoryKib: m, iterations: t, lanes: p),
    ];
  }

  /// p=1 subset — run first on pure-Dart if the full grid is too slow (the
  /// director's approved fast path; pure-Dart is single-threaded so lanes>1 does
  /// not help wall-clock anyway).
  static List<Argon2idParamCombo> p1Subset() =>
      defaultGrid().where((c) => c.lanes == 1).toList();

  /// Tiny grid for a `flutter test integration_test` smoke run that must finish
  /// quickly — the floor combo only.
  static List<Argon2idParamCombo> smokeGrid() => <Argon2idParamCombo>[
        const Argon2idParamCombo(
          memoryKib: KdfDescriptor.floorMemoryKib,
          iterations: KdfDescriptor.floorIterations,
          lanes: KdfDescriptor.floorLanes,
        ),
      ];

  static String get currentBuildMode {
    if (kReleaseMode) return 'release';
    if (kProfileMode) return 'profile';
    return 'debug';
  }

  /// Backend fingerprint of the Argon2id impl the app actually resolves.
  static String backendFingerprint() =>
      Argon2id(memory: 19 * 1024, iterations: 2, parallelism: 1, hashLength: 32)
          .runtimeType
          .toString();

  /// Measures one combo. Sub-floor combos are rejected (never timed) using the
  /// production floor guard, proving the floor is enforced.
  Future<Argon2idComboResult> measureCombo(
    Argon2idParamCombo combo, {
    required int samples,
  }) async {
    final KdfDescriptor descriptor;
    try {
      descriptor = KdfDescriptor.forNewParameters(
        salt: _hierarchy.generateSalt(),
        memoryKib: combo.memoryKib,
        iterations: combo.iterations,
        lanes: combo.lanes,
      );
    } on KdfFloorViolation catch (e) {
      return Argon2idComboResult.rejected(
        combo: combo,
        rejectedReason: e.reason,
      );
    }

    // One warm-up run (discarded) + `samples` timed runs.
    final timed = <double>[];
    double? warmupMs;
    for (var i = 0; i < samples + 1; i++) {
      final sw = Stopwatch()..start();
      await _hierarchy.deriveKek(
        password: syntheticPassword,
        descriptor: descriptor,
      );
      sw.stop();
      final ms = sw.elapsedMicroseconds / 1000.0;
      if (i == 0) {
        warmupMs = ms;
      } else {
        timed.add(ms);
      }
    }
    return Argon2idComboResult.measured(
      combo: combo,
      discardedWarmupMs: warmupMs,
      sampleMs: timed,
    );
  }

  /// Runs the full sweep. Throws [DebugModeMeasurementRefused] in debug mode
  /// unless [allowDebugDryRun] is set (belt-and-suspenders on the director's
  /// "profile/release only" rule).
  Future<Argon2idBenchmarkResult> run(
    List<Argon2idParamCombo> grid, {
    int samplesPerCombo = 6,
    bool allowDebugDryRun = false,
    Duration cooldownBetweenCombos = const Duration(seconds: 2),
    String? deviceModel,
    String? abi,
    int? apiLevel,
    int? batteryPct,
    bool? charging,
    void Function(String message)? onProgress,
  }) async {
    if (kDebugMode && !allowDebugDryRun) {
      throw const DebugModeMeasurementRefused();
    }
    // samplesPerCombo is the count of VALID (post-warm-up) samples. Director
    // requires >=6 total (warm-up + 5 valid); we keep 6 valid by default.
    final results = <Argon2idComboResult>[];
    for (var i = 0; i < grid.length; i++) {
      final combo = grid[i];
      onProgress?.call(
          'combo ${i + 1}/${grid.length}: ${combo.label} '
          '(${combo.belowFloor ? "sub-floor → reject" : "measuring"})');
      results.add(await measureCombo(combo, samples: samplesPerCombo));
      if (i < grid.length - 1 && cooldownBetweenCombos > Duration.zero) {
        await Future<void>.delayed(cooldownBetweenCombos);
      }
    }

    return Argon2idBenchmarkResult(
      buildMode: currentBuildMode,
      backend: backendFingerprint(),
      deviceModel: deviceModel,
      abi: abi,
      apiLevel: apiLevel,
      batteryPct: batteryPct,
      charging: charging,
      samplesPerCombo: samplesPerCombo,
      os: Platform.operatingSystem,
      osVersion: Platform.operatingSystemVersion,
      numberOfProcessors: Platform.numberOfProcessors,
      dartVersion: Platform.version,
      results: results,
    );
  }
}

/// Resolves the sweep grid from a `--dart-define=SANCTUM_BENCH_GRID=` value.
/// smoke (default) | p1 | full.
List<Argon2idParamCombo> gridFromName(String name) {
  switch (name) {
    case 'full':
      return Argon2idBenchmark.defaultGrid();
    case 'p1':
      return Argon2idBenchmark.p1Subset();
    case 'smoke':
    default:
      return Argon2idBenchmark.smokeGrid();
  }
}
