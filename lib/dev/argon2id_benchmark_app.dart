// DEV-ONLY ENTRYPOINT — the convenience run path (verified on a real Android
// device in profile mode). Run with:
//   flutter run --profile -t lib/dev/argon2id_benchmark_app.dart -d <deviceId> \
//     --dart-define=SANCTUM_BENCH_GRID=p1 --dart-define=SANCTUM_BENCH_SAMPLES=6
//
// `flutter run` DOES accept --profile (unlike `flutter test`). The sweep starts
// AUTOMATICALLY on launch (no manual tap needed) and the result JSON is printed
// to the run console AND written to the app documents dir. Set
// --dart-define=SANCTUM_BENCH_AUTORUN=false to require a manual tap instead.
//
// This file is a SEPARATE entrypoint. It is never imported by lib/main.dart, so
// it is not part of the shipping app and cannot reach a release build. It exists
// only so the measurement gate owner (Eis) can drive the on-device Argon2id
// sweep without wiring flutter drive.
//
// DEV-P0-03 B2-5a-native stage 1a (TDR-2026-026). See
// DEV-P0-03-B2-5a-native-argon2id-harness-design-v1.
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

import 'argon2id_benchmark.dart';

// Belt-and-suspenders gate on top of the separate-entrypoint gate.
const bool _kBenchEnabled =
    bool.fromEnvironment('SANCTUM_BENCH_ENABLED', defaultValue: true);

const String _kGridName =
    String.fromEnvironment('SANCTUM_BENCH_GRID', defaultValue: 'smoke');
const int _kSamples =
    int.fromEnvironment('SANCTUM_BENCH_SAMPLES', defaultValue: 6);
const bool _kAutoRun =
    bool.fromEnvironment('SANCTUM_BENCH_AUTORUN', defaultValue: true);
const String _kModel =
    String.fromEnvironment('SANCTUM_BENCH_MODEL', defaultValue: '');
const String _kAbi =
    String.fromEnvironment('SANCTUM_BENCH_ABI', defaultValue: '');
const int _kApi = int.fromEnvironment('SANCTUM_BENCH_API', defaultValue: 0);

void main() {
  runApp(const _BenchmarkApp());
}

class _BenchmarkApp extends StatelessWidget {
  const _BenchmarkApp();

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Sanctum Argon2id Benchmark (dev)',
      theme: ThemeData.dark(useMaterial3: true),
      home: _kBenchEnabled
          ? const _BenchmarkScreen()
          : const Scaffold(
              body: Center(child: Text('Benchmark disabled')),
            ),
    );
  }
}

class _BenchmarkScreen extends StatefulWidget {
  const _BenchmarkScreen();

  @override
  State<_BenchmarkScreen> createState() => _BenchmarkScreenState();
}

class _BenchmarkScreenState extends State<_BenchmarkScreen> {
  final _model = TextEditingController();
  final _abi = TextEditingController();
  final _api = TextEditingController();
  final _battery = TextEditingController();

  bool _running = false;
  String _log = '';
  String? _outputPath;

  bool get _isDebug => Argon2idBenchmark.currentBuildMode == 'debug';

  @override
  void initState() {
    super.initState();
    if (_kModel.isNotEmpty) _model.text = _kModel;
    if (_kAbi.isNotEmpty) _abi.text = _kAbi;
    if (_kApi != 0) _api.text = '$_kApi';
    if (_kAutoRun) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _run());
    }
  }

  void _append(String line) => setState(() => _log = '$_log$line\n');

  Future<void> _run() async {
    setState(() {
      _running = true;
      _log = '';
      _outputPath = null;
    });
    final grid = gridFromName(_kGridName);
    _append('build_mode=${Argon2idBenchmark.currentBuildMode}  '
        'backend=${Argon2idBenchmark.backendFingerprint()}');
    _append('grid=$_kGridName (${grid.length} combos)  samples=$_kSamples');
    if (_isDebug) {
      _append('WARNING: debug build — numbers are NOT authoritative. '
          'Re-run with --profile.');
    }
    try {
      final result = await Argon2idBenchmark().run(
        grid,
        samplesPerCombo: _kSamples,
        allowDebugDryRun: true, // screen allows a debug dry-run; JSON records the mode
        deviceModel: _model.text.trim().isEmpty ? null : _model.text.trim(),
        abi: _abi.text.trim().isEmpty ? null : _abi.text.trim(),
        apiLevel: int.tryParse(_api.text.trim()),
        batteryPct: int.tryParse(_battery.text.trim()),
        onProgress: _append,
      );
      final json = result.toJsonString();
      final dir = await getApplicationDocumentsDirectory();
      final file = File('${dir.path}/argon2id_benchmark_result.json');
      await file.writeAsString(json);
      setState(() => _outputPath = file.path);
      _append('--- RESULT JSON written to: ${file.path} ---');
      _append(json);
      // Mirror the JSON to the run console so `flutter run` captures it without
      // pulling the file off-device. debugPrint chunks long output line-by-line.
      debugPrint('[argon2id-bench] RESULT JSON >>>');
      for (final line in const LineSplitter().convert(json)) {
        debugPrint(line);
      }
      debugPrint('[argon2id-bench] <<< RESULT JSON');
    } catch (e) {
      _append('ERROR: $e');
    } finally {
      setState(() => _running = false);
    }
  }

  @override
  void dispose() {
    _model.dispose();
    _abi.dispose();
    _api.dispose();
    _battery.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Argon2id Benchmark (dev)')),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: ListView(
            children: <Widget>[
              if (_isDebug)
                Container(
                  padding: const EdgeInsets.all(12),
                  margin: const EdgeInsets.only(bottom: 12),
                  color: Colors.red.shade900,
                  child: const Text(
                    'DEBUG BUILD — numbers are misleading. Run with '
                    '--profile for authoritative results.',
                  ),
                ),
              Text('Build: ${Argon2idBenchmark.currentBuildMode}   '
                  'Backend: ${Argon2idBenchmark.backendFingerprint()}'),
              Text('CPUs: ${Platform.numberOfProcessors}   '
                  'OS: ${Platform.operatingSystemVersion}'),
              const SizedBox(height: 12),
              _field(_model, 'Device model (e.g. SM-J250F)'),
              _field(_abi, 'ABI (e.g. armeabi-v7a)'),
              _field(_api, 'API level (e.g. 24)'),
              _field(_battery, 'Battery % (optional)'),
              const SizedBox(height: 12),
              FilledButton(
                onPressed: _running ? null : _run,
                child: Text(_running ? 'Running…' : 'Run sweep ($_kGridName)'),
              ),
              if (_outputPath != null) ...<Widget>[
                const SizedBox(height: 8),
                SelectableText('JSON: $_outputPath'),
              ],
              const SizedBox(height: 12),
              SelectableText(
                _log,
                style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _field(TextEditingController c, String label) => Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: TextField(
          controller: c,
          decoration: InputDecoration(
            labelText: label,
            border: const OutlineInputBorder(),
            isDense: true,
          ),
        ),
      );
}
