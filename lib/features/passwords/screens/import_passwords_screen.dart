import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:file_picker/file_picker.dart';
import '../../../core/storage/providers.dart';
import '../../../core/storage/vault_service.dart';
import '../../../shared/theme/app_theme.dart';

// ── CSV Format Definitions ────────────────────────────────────
enum CsvFormat { chrome, bitwarden, onePassword, lastPass, unknown }

class _CsvEntry {
  final String site;
  final String username;
  final String password;
  final String notes;
  bool selected = true;

  _CsvEntry({
    required this.site,
    required this.username,
    required this.password,
    this.notes = '',
  });
}

// ── Screen ────────────────────────────────────────────────────
class ImportPasswordsScreen extends ConsumerStatefulWidget {
  const ImportPasswordsScreen({super.key});

  @override
  ConsumerState<ImportPasswordsScreen> createState() => _ImportPasswordsScreenState();
}

class _ImportPasswordsScreenState extends ConsumerState<ImportPasswordsScreen> {
  bool _loading = false;
  String? _error;
  String? _fileName;
  CsvFormat _format = CsvFormat.unknown;
  List<_CsvEntry> _entries = [];
  bool _importing = false;
  int _importedCount = 0;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: SanctumTheme.bg,
      appBar: AppBar(
        backgroundColor: SanctumTheme.bg,
        elevation: 0,
        title: const Text('匯入密碼', style: TextStyle(color: SanctumTheme.textPrimary, fontSize: 17, fontWeight: FontWeight.w600)),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back, color: SanctumTheme.textSecondary),
          onPressed: () => Navigator.of(context).pop(),
        ),
        actions: [
          if (_entries.isNotEmpty && !_importing)
            TextButton(
              onPressed: _doImport,
              child: const Text('匯入', style: TextStyle(color: SanctumTheme.gold, fontWeight: FontWeight.w700, fontSize: 15)),
            ),
        ],
      ),
      body: _importedCount > 0 ? _buildSuccess() : _buildBody(),
    );
  }

  Widget _buildBody() {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [

        // Info card
        Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: SanctumTheme.bg2,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: SanctumTheme.border),
          ),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Row(children: [
              Icon(Icons.info_outline, size: 15, color: SanctumTheme.gold),
              SizedBox(width: 8),
              Text('支援的格式', style: TextStyle(color: SanctumTheme.gold, fontWeight: FontWeight.w600, fontSize: 13)),
            ]),
            const SizedBox(height: 10),
            ...[
              ('Chrome', 'chrome://settings/passwords → 匯出'),
              ('Bitwarden', '工具 → 匯出 → .csv'),
              ('1Password', '檔案 → 匯出 → 1Password（CSV）'),
              ('LastPass', '帳號設定 → 匯出'),
            ].map((e) => Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: Row(children: [
                Container(width: 6, height: 6, margin: const EdgeInsets.only(right: 8, top: 1),
                  decoration: BoxDecoration(color: SanctumTheme.gold.withValues(alpha: 0.5), shape: BoxShape.circle)),
                Text('${e.$1}：', style: const TextStyle(color: SanctumTheme.textSecondary, fontSize: 12, fontWeight: FontWeight.w500)),
                Expanded(child: Text(e.$2, style: const TextStyle(color: SanctumTheme.textTertiary, fontSize: 12))),
              ]),
            )),
          ]),
        ),
        const SizedBox(height: 16),

        // Pick file button
        SizedBox(
          width: double.infinity,
          child: OutlinedButton.icon(
            onPressed: _loading ? null : _pickFile,
            style: OutlinedButton.styleFrom(
              foregroundColor: SanctumTheme.textPrimary,
              side: const BorderSide(color: SanctumTheme.border),
              padding: const EdgeInsets.symmetric(vertical: 14),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
            ),
            icon: const Icon(Icons.upload_file_outlined, size: 18),
            label: Text(_loading ? '讀取中…' : '選擇 CSV 檔案',
              style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w500)),
          ),
        ),

        // Error
        if (_error != null) ...[
          const SizedBox(height: 12),
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(color: SanctumTheme.red.withValues(alpha: 0.1), borderRadius: BorderRadius.circular(8)),
            child: Row(children: [
              const Icon(Icons.warning_amber, color: SanctumTheme.red, size: 16),
              const SizedBox(width: 8),
              Expanded(child: Text(_error!, style: const TextStyle(color: SanctumTheme.red, fontSize: 13))),
            ]),
          ),
        ],

        // File info + entries
        if (_fileName != null && _entries.isNotEmpty) ...[
          const SizedBox(height: 16),
          Row(children: [
            Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(_fileName!, style: const TextStyle(color: SanctumTheme.textPrimary, fontSize: 13, fontWeight: FontWeight.w500)),
              Text('${_formatLabel(_format)} · ${_entries.length} 個帳號', style: const TextStyle(color: SanctumTheme.textTertiary, fontSize: 12)),
            ])),
            TextButton(
              onPressed: _toggleAll,
              child: Text(_entries.every((e) => e.selected) ? '取消全選' : '全選',
                style: const TextStyle(color: SanctumTheme.gold, fontSize: 13)),
            ),
          ]),
          const SizedBox(height: 8),
          ListView.builder(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            itemCount: _entries.length,
            itemBuilder: (_, i) {
              final entry = _entries[i];
              return Container(
                margin: const EdgeInsets.only(bottom: 6),
                decoration: BoxDecoration(
                  color: SanctumTheme.bg2,
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: entry.selected ? SanctumTheme.gold.withValues(alpha: 0.25) : SanctumTheme.border),
                ),
                child: ListTile(
                  contentPadding: const EdgeInsets.fromLTRB(12, 4, 8, 4),
                  leading: Checkbox(
                    value: entry.selected,
                    onChanged: (v) => setState(() => entry.selected = v ?? false),
                    activeColor: SanctumTheme.gold,
                    side: const BorderSide(color: SanctumTheme.border),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(4)),
                  ),
                  title: Text(entry.site.isEmpty ? '（無網站）' : entry.site,
                    style: const TextStyle(color: SanctumTheme.textPrimary, fontSize: 13, fontWeight: FontWeight.w500)),
                  subtitle: entry.username.isNotEmpty
                      ? Text(entry.username, style: const TextStyle(color: SanctumTheme.textTertiary, fontSize: 12))
                      : null,
                  trailing: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                    decoration: BoxDecoration(
                      color: SanctumTheme.bg3, borderRadius: BorderRadius.circular(6),
                      border: Border.all(color: SanctumTheme.border),
                    ),
                    child: const Text('••••••', style: TextStyle(color: SanctumTheme.textTertiary, fontSize: 12, letterSpacing: 2)),
                  ),
                ),
              );
            },
          ),
          const SizedBox(height: 16),
          SizedBox(
            width: double.infinity,
            child: ElevatedButton(
              onPressed: _importing ? null : _doImport,
              style: ElevatedButton.styleFrom(
                backgroundColor: SanctumTheme.gold,
                foregroundColor: SanctumTheme.bg,
                padding: const EdgeInsets.symmetric(vertical: 14),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
              ),
              child: _importing
                  ? const SizedBox(height: 18, width: 18, child: CircularProgressIndicator(strokeWidth: 2, color: SanctumTheme.bg))
                  : Text('匯入 ${_entries.where((e) => e.selected).length} 個帳號',
                      style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 15)),
            ),
          ),
        ],
      ]),
    );
  }

  Widget _buildSuccess() {
    return Center(child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
      Container(
        width: 72, height: 72,
        decoration: BoxDecoration(color: SanctumTheme.greenDim, shape: BoxShape.circle),
        child: const Icon(Icons.check, color: SanctumTheme.green, size: 36),
      ),
      const SizedBox(height: 20),
      Text('匯入成功！', style: const TextStyle(color: SanctumTheme.textPrimary, fontSize: 20, fontWeight: FontWeight.w700)),
      const SizedBox(height: 8),
      Text('已匯入 $_importedCount 個帳號', style: const TextStyle(color: SanctumTheme.textTertiary, fontSize: 14)),
      const SizedBox(height: 32),
      TextButton(
        onPressed: () => Navigator.of(context).pop(true),
        child: const Text('返回', style: TextStyle(color: SanctumTheme.gold, fontSize: 15)),
      ),
    ]));
  }

  String _formatLabel(CsvFormat f) {
    switch (f) {
      case CsvFormat.chrome: return 'Google Chrome';
      case CsvFormat.bitwarden: return 'Bitwarden';
      case CsvFormat.onePassword: return '1Password';
      case CsvFormat.lastPass: return 'LastPass';
      case CsvFormat.unknown: return '通用格式';
    }
  }

  Future<void> _pickFile() async {
    setState(() { _loading = true; _error = null; });
    // Pause inactivity timer — OS file picker sends app to background,
    // which would otherwise lock the vault before we return.
    ref.read(inactivityProvider.notifier).cancel();
    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['csv'],
        withData: true,
      );
      if (result == null || result.files.isEmpty) {
        setState(() => _loading = false);
        ref.read(inactivityProvider.notifier).resetTimer();
        return;
      }

      final file = result.files.first;
      final bytes = file.bytes ?? (file.path != null ? File(file.path!).readAsBytesSync() : null);
      if (bytes == null) {
        setState(() { _loading = false; _error = '無法讀取檔案'; });
        return;
      }

      final content = utf8.decode(bytes, allowMalformed: true);
      final parsed = _parseCsv(content);

      setState(() {
        _loading   = false;
        _fileName  = file.name;
        _entries   = parsed.$1;
        _format    = parsed.$2;
        if (_entries.isEmpty) _error = '找不到有效的帳號資料';
      });
    } catch (e) {
      setState(() { _loading = false; _error = '解析失敗：$e'; });
    } finally {
      ref.read(inactivityProvider.notifier).resetTimer();
    }
  }

  (List<_CsvEntry>, CsvFormat) _parseCsv(String content) {
    final lines = content.split('\n').where((l) => l.trim().isNotEmpty).toList();
    if (lines.isEmpty) return ([], CsvFormat.unknown);

    final header = lines.first.toLowerCase();
    final format = _detectFormat(header);
    final entries = <_CsvEntry>[];

    for (int i = 1; i < lines.length; i++) {
      final cols = _splitCsvLine(lines[i]);
      try {
        final entry = _parseRow(cols, format);
        if (entry != null && entry.password.isNotEmpty) entries.add(entry);
      } catch (_) {}
    }
    return (entries, format);
  }

  CsvFormat _detectFormat(String header) {
    if (header.contains('username') && header.contains('password') && header.contains('url')) {
      if (header.contains('totp')) return CsvFormat.bitwarden;
      if (header.contains('notes') && header.contains('name') && header.contains('fields')) return CsvFormat.onePassword;
      return CsvFormat.chrome;
    }
    if (header.contains('url') && header.contains('username') && header.contains('password') && header.contains('extra')) {
      return CsvFormat.lastPass;
    }
    return CsvFormat.unknown;
  }

  /// Extract a readable domain/name from a URL.
  /// "https://account.bandainamcoid.com/signup.html" → "bandainamcoid.com"
  String _domainOf(String url) {
    if (url.isEmpty) return url;
    try {
      var host = Uri.parse(url).host; // "account.bandainamcoid.com"
      if (host.startsWith('www.')) host = host.substring(4);
      // Drop leading subdomain when it's generic (account/login/auth/secure/app/my/id)
      final parts = host.split('.');
      if (parts.length > 2) {
        const generic = {'account', 'accounts', 'login', 'auth', 'secure', 'app', 'my', 'id', 'go', 'sso'};
        if (generic.contains(parts.first)) host = parts.sublist(1).join('.');
      }
      return host.isNotEmpty ? host : url;
    } catch (_) {
      return url;
    }
  }

  _CsvEntry? _parseRow(List<String> cols, CsvFormat format) {
    switch (format) {
      case CsvFormat.chrome:
        // name, url, username, password
        if (cols.length < 4) return null;
        final cName = cols[0].trim();
        final cUrl  = cols[1].trim();
        // Prefer human-readable name; fall back to cleaned-up domain
        final site = cName.isNotEmpty ? cName : _domainOf(cUrl);
        return _CsvEntry(site: site, username: cols[2], password: cols[3],
          notes: cName.isNotEmpty && cUrl.isNotEmpty ? cUrl : '');

      case CsvFormat.bitwarden:
        // folder,favorite,type,name,notes,fields,reprompt,login_uri,login_username,login_password,...
        if (cols.length < 10) return null;
        final bName = cols[3].trim();
        final bUri  = cols[7].trim();
        return _CsvEntry(
          site: bName.isNotEmpty ? bName : _domainOf(bUri),
          username: cols[8], password: cols[9], notes: cols[4],
        );

      case CsvFormat.onePassword:
        // title,username,password,url,notes,type,...
        if (cols.length < 3) return null;
        final oTitle = cols[0].trim();
        final oUrl   = cols.length > 3 ? cols[3].trim() : '';
        return _CsvEntry(
          site: oTitle.isNotEmpty ? oTitle : _domainOf(oUrl),
          username: cols[1], password: cols[2],
          notes: cols.length > 4 ? cols[4] : '',
        );

      case CsvFormat.lastPass:
        // url,username,password,extra,name,grouping,fav
        if (cols.length < 3) return null;
        final lName = cols.length > 4 ? cols[4].trim() : '';
        final lUrl  = cols[0].trim();
        return _CsvEntry(
          site: lName.isNotEmpty ? lName : _domainOf(lUrl),
          username: cols[1], password: cols[2],
          notes: cols.length > 3 ? cols[3] : '',
        );

      case CsvFormat.unknown:
        if (cols.length < 3) return null;
        final urlIdx = cols.indexWhere((c) => c.startsWith('http') || c.contains('.com') || c.contains('.'));
        if (urlIdx < 0) return null;
        final passIdx = cols.length > urlIdx + 2 ? urlIdx + 2 : cols.length - 1;
        final userIdx = urlIdx + 1 < cols.length ? urlIdx + 1 : 0;
        return _CsvEntry(site: _domainOf(cols[urlIdx]), username: cols[userIdx], password: cols[passIdx]);
    }
  }

  // RFC 4180 CSV line parser (handles quoted fields with commas)
  List<String> _splitCsvLine(String line) {
    final result = <String>[];
    bool inQuotes = false;
    final current = StringBuffer();

    for (int i = 0; i < line.length; i++) {
      final ch = line[i];
      if (ch == '"') {
        if (inQuotes && i + 1 < line.length && line[i + 1] == '"') {
          current.write('"');
          i++;
        } else {
          inQuotes = !inQuotes;
        }
      } else if (ch == ',' && !inQuotes) {
        result.add(current.toString());
        current.clear();
      } else {
        current.write(ch);
      }
    }
    result.add(current.toString());
    return result;
  }

  void _toggleAll() {
    final allSelected = _entries.every((e) => e.selected);
    setState(() {
      for (final e in _entries) e.selected = !allSelected;
    });
  }

  Future<void> _doImport() async {
    final toImport = _entries.where((e) => e.selected).toList();
    if (toImport.isEmpty) return;

    // Guard: vault may have been locked by inactivity timer while file picker was open
    if (!vaultService.isUnlocked) {
      setState(() => _error = 'Vault 已鎖定，請返回並重新解鎖後再試');
      return;
    }

    setState(() => _importing = true);
    try {
      int count = 0;
      for (final entry in toImport) {
        await ref.read(passwordsNotifierProvider.notifier).add(
          site: entry.site,
          username: entry.username,
          password: entry.password,
          notes: entry.notes,
        );
        count++;
      }
      setState(() {
        _importing = false;
        _importedCount = count;
      });
    } catch (e) {
      final msg = e is StateError ? 'Vault 已鎖定，請返回並重新解鎖後再試' : '匯入失敗：$e';
      setState(() {
        _importing = false;
        _error = msg;
      });
    }
  }
}
