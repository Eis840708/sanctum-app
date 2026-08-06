// Driver for `flutter drive` runs of the Argon2id measurement harness
// (DEV-P0-03 B2-5a-native stage 1a / TDR-2026-026).
//
// It takes the `reportData` the on-device test sends back and writes the
// benchmark JSON onto the HOST filesystem at build/argon2id_benchmark_result.json
// so the numbers can be pulled without adb. Used by:
//
//   flutter drive \
//     --driver=test_driver/integration_test.dart \
//     --target=integration_test/argon2id_benchmark_test.dart \
//     --profile -d <deviceId>
import 'dart:convert';
import 'dart:io';

import 'package:integration_test/integration_test_driver.dart';

Future<void> main() {
  return integrationDriver(
    responseDataCallback: (Map<String, dynamic>? data) async {
      final result = data?['argon2id_benchmark'];
      if (result == null) {
        // ignore: avoid_print
        print('[argon2id-bench] no benchmark data reported (test skipped?).');
        return;
      }
      final file = File('build/argon2id_benchmark_result.json');
      await file.parent.create(recursive: true);
      await file.writeAsString(
        const JsonEncoder.withIndent('  ').convert(result),
      );
      // ignore: avoid_print
      print('[argon2id-bench] host JSON written: ${file.absolute.path}');
    },
  );
}
