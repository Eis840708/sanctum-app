// lib/core/crypto/shamir_service.dart
import 'dart:math';
import 'dart:typed_data';

class ShamirService {
  static const int _poly = 0x11b;

  static int _gfMul(int a, int b) {
    int result = 0;
    int aa = a & 0xff;
    int bb = b & 0xff;
    for (int i = 0; i < 8; i++) {
      if ((bb & 1) != 0) result ^= aa;
      final carry = aa & 0x80;
      aa = (aa << 1) & 0xff;
      if (carry != 0) aa ^= (_poly & 0xff);
      bb >>= 1;
    }
    return result & 0xff;
  }

  static int _gfPow(int base, int exp) {
    int result = 1;
    int b = base & 0xff;
    for (int i = 0; i < exp; i++) {
      result = _gfMul(result, b);
    }
    return result;
  }

  static int _gfInv(int a) => _gfPow(a, 254);
  static int _gfDiv(int a, int b) => _gfMul(a, _gfInv(b));

  static int _evalAt(List<int> coefficients, int x) {
    int result = 0;
    for (int i = coefficients.length - 1; i >= 0; i--) {
      result = _gfMul(result, x) ^ coefficients[i];
    }
    return result;
  }

  List<Uint8List> split(List<int> secret, int n, int k) {
    assert(n >= k && k >= 2);
    assert(n <= 255);
    final rng = Random.secure();
    final polys = List<List<int>>.generate(secret.length, (i) {
      final c = List<int>.filled(k, 0);
      c[0] = secret[i] & 0xff;
      for (int j = 1; j < k; j++) c[j] = rng.nextInt(256);
      return c;
    });
    return List<Uint8List>.generate(n, (si) {
      final x = si + 1;
      final share = Uint8List(1 + secret.length);
      share[0] = x;
      for (int bi = 0; bi < secret.length; bi++) {
        share[1 + bi] = _evalAt(polys[bi], x);
      }
      return share;
    });
  }

  List<int> combine(List<Uint8List> shares) {
    assert(shares.isNotEmpty);
    final len = shares[0].length - 1;
    final k = shares.length;
    final xs = shares.map((s) => s[0]).toList();
    final secret = List<int>.filled(len, 0);
    for (int bi = 0; bi < len; bi++) {
      final ys = shares.map((s) => s[1 + bi]).toList();
      int value = 0;
      for (int i = 0; i < k; i++) {
        int num = 1, den = 1;
        for (int j = 0; j < k; j++) {
          if (i == j) continue;
          num = _gfMul(num, xs[j]);
          den = _gfMul(den, xs[i] ^ xs[j]);
        }
        value ^= _gfMul(ys[i], _gfDiv(num, den));
      }
      secret[bi] = value;
    }
    return secret;
  }

  String encodeShare(Uint8List share) {
    final hex = share.map((b) => b.toRadixString(16).padLeft(2, '0').toUpperCase()).join();
    final groups = <String>[];
    for (int i = 0; i < hex.length; i += 4) {
      groups.add(hex.substring(i, (i + 4).clamp(0, hex.length)));
    }
    return groups.join('-');
  }

  Uint8List? decodeShare(String encoded) {
    final clean = encoded.replaceAll('-', '').replaceAll(' ', '').toUpperCase();
    if (clean.isEmpty || clean.length.isOdd) return null;
    if (!RegExp(r'^[0-9A-F]+$').hasMatch(clean)) return null;
    final bytes = Uint8List(clean.length ~/ 2);
    for (int i = 0; i < bytes.length; i++) {
      bytes[i] = int.parse(clean.substring(i * 2, i * 2 + 2), radix: 16);
    }
    return bytes;
  }

  String buildDocument({
    required int index,
    required int total,
    required int threshold,
    required String shareCode,
    required DateTime createdAt,
  }) {
    final d = createdAt;
    final dateStr = '${d.year}-${d.month.toString().padLeft(2,'0')}-${d.day.toString().padLeft(2,'0')} ${d.hour.toString().padLeft(2,'0')}:${d.minute.toString().padLeft(2,'0')}';
    return '''
╔══════════════════════════════════════════╗
║       Sanctum 密閣  ·  主密碼碎片           ║
╚══════════════════════════════════════════╝

【碎片編號】  $index / $total
【最低重建數】  任意 $threshold 份碎片可還原主密碼
【建立時間】  $dateStr

────────────────────────────────────────────
  碎片代碼（請妥善保存，切勿洩露）
────────────────────────────────────────────

  $shareCode

────────────────────────────────────────────

⚠️  注意事項：
  • 此碎片本身不含任何可破解的密碼資訊
  • 需要集齊至少 $threshold 份碎片方可還原主密碼
  • 請將每份碎片分別交給不同的可信任人士保管
  • 切勿將多份碎片存放於同一地點

Sanctum 密閣  ─  離線加密金庫
''';
  }
}

final shamirService = ShamirService();