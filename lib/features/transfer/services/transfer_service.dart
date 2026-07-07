import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';
import 'package:cryptography/cryptography.dart';
import '../../../core/crypto/crypto_service.dart';
import '../../../core/storage/vault_service.dart';

/// Secure device-to-device vault transfer service.
///
/// Security model:
///  • 32-byte random [transferKey] is exchanged via QR code only (physical proximity).
///  • Vault data (already AES-256-GCM encrypted with master key) is wrapped in a
///    second AES-256-GCM layer using [transferKey] for transit.
///  • HTTP server is one-shot: closes immediately after first successful download.
///  • Transfer key expires automatically after 5 minutes.
///  • Imported vault still requires the original master password to unlock.
class TransferService {
  HttpServer? _server;
  Timer?      _timer;
  bool        _served = false;

  // ── Key helpers ──────────────────────────────────────────
  String generateKey() {
    final r = Random.secure();
    return List.generate(32, (_) => r.nextInt(256))
        .map((b) => b.toRadixString(16).padLeft(2, '0'))
        .join();
  }

  Uint8List _fromHex(String h) => Uint8List.fromList(
      List.generate(h.length ~/ 2, (i) =>
          int.parse(h.substring(i * 2, i * 2 + 2), radix: 16)));

  Future<String> _enc(String plain, String keyHex) =>
      cryptoService.encrypt(plain, SecretKey(_fromHex(keyHex)));

  Future<String> _dec(String cipher, String keyHex) =>
      cryptoService.decrypt(cipher, SecretKey(_fromHex(keyHex)));

  // ── Vault serialization ──────────────────────────────────
  Future<String> _serialize() async {
    final meta = vaultService.rawMeta;
    if (meta == null) throw StateError('Vault not initialised');
    return jsonEncode({
      'v':  1,
      't':  'sct',
      'sl': meta.salt,
      'vh': meta.verifyHash,
      'pw': vaultService.rawPasswords.map((e) => {
        'id': e.id,  'si': e.site,      'un': e.username,
        'ep': e.encryptedPassword,      'no': e.notes,
        'ca': e.createdAt.millisecondsSinceEpoch,
        'ua': e.updatedAt.millisecondsSinceEpoch,
        'ie': e.iconEmoji,
      }).toList(),
      'di': vaultService.rawDiary.map((e) => {
        'id': e.id,  'ti': e.title,     'ec': e.encryptedContent,
        'mo': e.mood,'tg': e.tags,
        'ca': e.createdAt.millisecondsSinceEpoch,
        'ua': e.updatedAt.millisecondsSinceEpoch,
      }).toList(),
      'fi': vaultService.rawFinance.map((e) => {
        'id': e.id,  'ty': e.type,      'am': e.amount,
        'ct': e.category,               'de': e.description,
        'dt': e.date.millisecondsSinceEpoch,
        'ca': e.createdAt.millisecondsSinceEpoch,
        'cu': e.currency,
        if (e.lineItemsJson != null) 'li': e.lineItemsJson,
      }).toList(),
      'im': vaultService.rawImages,
      'ii': vaultService.rawImageIndex,
    });
  }

  Future<void> _deserialize(String json) async {
    final d = jsonDecode(json) as Map<String, dynamic>;
    if (d['t'] != 'sct') throw const FormatException('Not a Sanctum transfer payload');
    await vaultService.importTransfer(d);
  }

  // ── WiFi Sender ──────────────────────────────────────────
  /// Starts a local HTTP server, returns {ip, port} for the QR code.
  Future<Map<String, dynamic>> startWifiSend(String keyHex) async {
    stop();
    _served = false;

    final plain     = await _serialize();
    final encrypted = await _enc(plain, keyHex);
    final bytes     = utf8.encode(encrypted);

    _server = await HttpServer.bind(InternetAddress.anyIPv4, 0);
    final port = _server!.port;

    // Auto-close after 5 min
    _timer = Timer(const Duration(minutes: 5), stop);

    _server!.listen((req) async {
      if (!_served && req.method == 'GET' && req.uri.path == '/v') {
        _served = true;
        req.response.headers.contentType =
            ContentType('application', 'octet-stream');
        req.response.headers.add('Content-Length', bytes.length);
        req.response.add(bytes);
        await req.response.close();
        // Shut down after delivery
        Timer(const Duration(seconds: 2), stop);
      } else {
        req.response.statusCode = 403;
        await req.response.close();
      }
    });

    // Find local IPv4 address
    String? ip;
    for (final iface in await NetworkInterface.list(
        type: InternetAddressType.IPv4)) {
      for (final addr in iface.addresses) {
        if (!addr.isLoopback) { ip = addr.address; break; }
      }
      if (ip != null) break;
    }
    if (ip == null) throw Exception('No WiFi interface found.\nPlease connect to a WiFi network first.');

    return {'ip': ip, 'port': port};
  }

  void stop() {
    _timer?.cancel();
    _server?.close(force: true);
    _server = null;
  }

  bool get isServing => _server != null;
  bool get wasServed => _served;

  // ── WiFi Receiver ────────────────────────────────────────
  Future<void> receiveWifi(String ip, int port, String keyHex,
      {void Function(double)? onProgress}) async {
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 15);
    try {
      final req = await client.get(ip, port, '/v');
      req.headers.set('User-Agent', 'Sanctum/1.0');
      final res = await req.close();

      if (res.statusCode != 200) {
        throw Exception('Server returned ${res.statusCode}. Transfer may have already been used.');
      }

      final total  = res.contentLength;
      final buffer = <int>[];
      await for (final chunk in res) {
        buffer.addAll(chunk);
        if (total > 0) onProgress?.call(buffer.length / total);
      }
      onProgress?.call(1.0);

      final encrypted = utf8.decode(buffer);
      final plain     = await _dec(encrypted, keyHex);
      await _deserialize(plain);
    } finally {
      client.close();
    }
  }

  // ── QR payload builders ──────────────────────────────────
  /// Build QR JSON for WiFi mode
  static String buildWifiQr(String ip, int port, String keyHex) =>
      jsonEncode({'v': 1, 'm': 'w', 'h': ip, 'p': port, 'k': keyHex,
                  'e': DateTime.now().add(const Duration(minutes: 5))
                           .millisecondsSinceEpoch});

  /// Parse QR JSON, returns mode + params or throws
  static Map<String, dynamic> parseQr(String raw) {
    final d = jsonDecode(raw) as Map<String, dynamic>;
    if (d['v'] != 1) throw FormatException('Unknown QR version');
    final exp = d['e'] as int?;
    if (exp != null && DateTime.now().millisecondsSinceEpoch > exp) {
      throw Exception('QR code expired. Please generate a new one.');
    }
    return d;
  }
}

final transferService = TransferService();
