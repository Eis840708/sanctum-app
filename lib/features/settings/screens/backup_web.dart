// Web platform stub — backup features require mobile app
class BackupHelper {
  static Future<void> saveLocal(String json, DateTime date) async {
    throw UnsupportedError('Backup requires mobile app');
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
