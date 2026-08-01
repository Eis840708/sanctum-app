// Web platform stub — backup features require mobile app
import 'dart:typed_data';

class BackupHelper {
  static Future<void> saveLocal(String json, DateTime date) async {
    throw UnsupportedError('Backup requires mobile app');
  }

  static Future<void> saveLocalBytes(Uint8List bytes, DateTime date) async {
    throw UnsupportedError('Backup requires mobile app');
  }

  static Future<Uint8List> readBackupBytes() async {
    throw UnsupportedError('Restore requires mobile app');
  }

  static Future<void> shareFile() async {
    throw UnsupportedError('Share requires mobile app');
  }

  static Future<void> restoreFromFile() async {
    throw UnsupportedError('Restore requires mobile app');
  }

  static Future<Map<String, dynamic>> readBackupFile() async {
    throw UnsupportedError('Restore requires mobile app');
  }
}
