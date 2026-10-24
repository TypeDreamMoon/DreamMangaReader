import 'dart:typed_data';

/// SHA-256（FIPS 180-4），小写十六进制。
///
/// 和 C++ 版 `src/sha256.cpp` 是同一套实现、同一批测试向量。
/// 服务端的 `version` 就是内容哈希，所以客户端能自己算一遍，回答一个
/// 光看状态码回答不了的问题：**「服务端上现在这一份，是不是我刚才提交的那份？」**
String sha256Hex(List<int> data) {
  final h = List<int>.from(_h0);
  final buf = Uint8List.fromList(data);
  final len = buf.length;

  final fullBlocks = len ~/ 64;
  for (var i = 0; i < fullBlocks; i++) {
    _transform(h, buf, i * 64);
  }

  // 尾部：剩余字节 + 0x80 + 补零 + 64 位大端比特长度
  final rest = len - fullBlocks * 64;
  final tailLen = rest < 56 ? 64 : 128;
  final tail = Uint8List(tailLen);
  tail.setRange(0, rest, buf, fullBlocks * 64);
  tail[rest] = 0x80;

  final bits = len * 8;
  for (var i = 0; i < 8; i++) {
    tail[tailLen - 1 - i] = (bits >> (8 * i)) & 0xFF;
  }
  for (var off = 0; off < tailLen; off += 64) {
    _transform(h, tail, off);
  }

  final sb = StringBuffer();
  for (final v in h) {
    sb.write(v.toRadixString(16).padLeft(8, '0'));
  }
  return sb.toString();
}

int _rotr(int x, int n) => ((x >> n) | (x << (32 - n))) & 0xFFFFFFFF;

void _transform(List<int> h, Uint8List block, int offset) {
  final w = List<int>.filled(64, 0);
  for (var i = 0; i < 16; i++) {
    final o = offset + i * 4;
    w[i] = ((block[o] << 24) |
            (block[o + 1] << 16) |
            (block[o + 2] << 8) |
            block[o + 3]) &
        0xFFFFFFFF;
  }
  for (var i = 16; i < 64; i++) {
    final s0 = _rotr(w[i - 15], 7) ^ _rotr(w[i - 15], 18) ^ (w[i - 15] >> 3);
    final s1 = _rotr(w[i - 2], 17) ^ _rotr(w[i - 2], 19) ^ (w[i - 2] >> 10);
    w[i] = (w[i - 16] + s0 + w[i - 7] + s1) & 0xFFFFFFFF;
  }

  var a = h[0], b = h[1], c = h[2], d = h[3];
  var e = h[4], f = h[5], g = h[6], hh = h[7];

  for (var i = 0; i < 64; i++) {
    final s1 = _rotr(e, 6) ^ _rotr(e, 11) ^ _rotr(e, 25);
    final ch = (e & f) ^ ((~e & 0xFFFFFFFF) & g);
    final t1 = (hh + s1 + ch + _k[i] + w[i]) & 0xFFFFFFFF;
    final s0 = _rotr(a, 2) ^ _rotr(a, 13) ^ _rotr(a, 22);
    final maj = (a & b) ^ (a & c) ^ (b & c);
    final t2 = (s0 + maj) & 0xFFFFFFFF;

    hh = g;
    g = f;
    f = e;
    e = (d + t1) & 0xFFFFFFFF;
    d = c;
    c = b;
    b = a;
    a = (t1 + t2) & 0xFFFFFFFF;
  }

  h[0] = (h[0] + a) & 0xFFFFFFFF;
  h[1] = (h[1] + b) & 0xFFFFFFFF;
  h[2] = (h[2] + c) & 0xFFFFFFFF;
  h[3] = (h[3] + d) & 0xFFFFFFFF;
  h[4] = (h[4] + e) & 0xFFFFFFFF;
  h[5] = (h[5] + f) & 0xFFFFFFFF;
  h[6] = (h[6] + g) & 0xFFFFFFFF;
  h[7] = (h[7] + hh) & 0xFFFFFFFF;
}

const _h0 = <int>[
  0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, //
  0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19,
];

const _k = <int>[
  0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, //
  0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
  0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3,
  0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
  0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc,
  0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
  0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7,
  0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
  0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13,
  0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
  0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3,
  0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
  0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5,
  0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
  0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208,
  0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
];
