import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:file_picker/file_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

class BackupHelper {
  static String? _lastFilePath;

  /// Save JSON to app documents dir and record the path for sharing.
  static Future<String> saveLocal(String json, DateTime date) async {
    final dir  = await getApplicationDocumentsDirectory();
    final name = 'sanctum-${date.year}${date.month.toString().padLeft(2,'0')}${date.day.toString().padLeft(2,'0')}.vault';
    final file = File('${dir.path}/$name');
    await file.writeAsString(json);
    _lastFilePath = file.path;

    // Also keep an always-current latest file so auto-backup is easy to find
    final latest = File('${dir.path}/sanctum-latest.vault');
    await latest.writeAsString(json);

    return file.path;
  }

  /// Save raw bytes (a binary v3 `SNCB3` backup) to the app documents dir and
  /// record the path for sharing. Additive sibling of [saveLocal]; the v2 string
  /// path is unchanged.
  static Future<String> saveLocalBytes(Uint8List bytes, DateTime date) async {
    final dir  = await getApplicationDocumentsDirectory();
    final name = 'sanctum-${date.year}${date.month.toString().padLeft(2,'0')}${date.day.toString().padLeft(2,'0')}.vault';
    final file = File('${dir.path}/$name');
    await file.writeAsBytes(bytes, flush: true);
    _lastFilePath = file.path;

    final latest = File('${dir.path}/sanctum-latest.vault');
    await latest.writeAsBytes(bytes, flush: true);

    return file.path;
  }

  /// Open file picker and return the selected .vault file's RAW bytes (no JSON
  /// parse, no format assumption). The caller detects v3 (binary) vs v2 (JSON).
  static Future<Uint8List> readBackupBytes() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.any,
      withData: true,
    );
    if (result == null || result.files.isEmpty) {
      throw Exception('未選擇檔案');
    }
    final file  = result.files.first;
    final bytes = file.bytes ??
        (file.path != null ? await File(file.path!).readAsBytes() : null);
    if (bytes == null) throw Exception('無法讀取檔案');
    return bytes;
  }

  /// Share the last saved file via Android share sheet.
  static Future<void> shareFile() async {
    if (_lastFilePath == null) return;
    await Share.shareXFiles(
      [XFile(_lastFilePath!)],
      text: 'Sanctum 加密保險庫備份',
      subject: 'Sanctum Vault Backup',
    );
  }

  /// Open file picker, read the selected .vault file, and return its parsed JSON.
  /// Throws on any error.
  static Future<Map<String, dynamic>> readBackupFile() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.any,
      withData: true,
    );
    if (result == null || result.files.isEmpty) {
      throw Exception('未選擇檔案');
    }

    final file  = result.files.first;
    final bytes = file.bytes ??
        (file.path != null ? await File(file.path!).readAsBytes() : null);
    if (bytes == null) throw Exception('無法讀取檔案');

    try {
      final json = jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;
      // Basic sanity check
      if (!json.containsKey('passwords') && !json.containsKey('diary')) {
        throw Exception('檔案格式不正確，請選擇 .vault 備份檔案');
      }
      return json;
    } catch (e) {
      if (e is FormatException) throw Exception('檔案格式不正確：$e');
      rethrow;
    }
  }

  /// Returns path to the latest auto-backup, or null if none exists.
  static Future<String?> getLatestAutoBackupPath() async {
    final dir  = await getApplicationDocumentsDirectory();
    final file = File('${dir.path}/sanctum-latest.vault');
    return file.existsSync() ? file.path : null;
  }
}
