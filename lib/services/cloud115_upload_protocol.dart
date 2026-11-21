import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:pointycastle/export.dart';

// 115 upload encryption format adapted from github.com/deadblue/elevengo.
//
// MIT License
//
// Copyright (c) 2022 Tomo Kunagisa
//
// Permission is hereby granted, free of charge, to any person obtaining a copy
// of this software and associated documentation files (the "Software"), to deal
// in the Software without restriction, including without limitation the rights
// to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
// copies of the Software, and to permit persons to whom the Software is
// furnished to do so, subject to the following conditions:
//
// The above copyright notice and this permission notice shall be included in all
// copies or substantial portions of the Software.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
// AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
// OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
// SOFTWARE.

class Cloud115UploadProtocol {
  static const _serverPublicKey =
      '0457a29257cd2320e5d6d143322fa4bb8a3cf9d3cc623ef5edac62b7678a89c91'
      'a83ba800d6129f522d034c895dd2465243addc250953beeba';
  static final _crcSalt = ascii.encode('^j>WD3Kr?J2gLFjD4W2y@');
  static final _random = Random.secure();

  final Uint8List _publicKey;
  final Uint8List _sharedSecret;

  Cloud115UploadProtocol._(this._publicKey, this._sharedSecret);

  factory Cloud115UploadProtocol() {
    final curve = ECDomainParameters('secp224r1');
    BigInt scalar;
    do {
      scalar = BigInt.parse(
        List.generate(
          28,
          (_) => _random.nextInt(256).toRadixString(16).padLeft(2, '0'),
        ).join(),
        radix: 16,
      );
    } while (scalar == BigInt.zero || scalar >= curve.n);
    final peer = Uint8List.fromList([
      for (var i = 0; i < _serverPublicKey.length; i += 2)
        int.parse(_serverPublicKey.substring(i, i + 2), radix: 16),
    ]);
    final sharedPoint = (curve.curve.decodePoint(peer)! * scalar)!;
    final secret = Uint8List.sublistView(sharedPoint.getEncoded(true), 1);
    final publicKey = (curve.G * scalar)!.getEncoded(true);
    return Cloud115UploadProtocol._(
      Uint8List.fromList([publicKey.length, ...publicKey]),
      secret,
    );
  }

  String encodeToken(int timestamp) {
    final bytes = Uint8List(48);
    bytes.setRange(0, 15, _publicKey);
    bytes.setRange(24, 39, _publicKey, 15);
    bytes[16] = 115;
    bytes[40] = 1;
    final fields = ByteData.sublistView(bytes);
    fields.setUint32(20, timestamp & 0xffffffff, Endian.little);
    final firstMask = _random.nextInt(255);
    final secondMask = _random.nextInt(255);
    for (var i = 0; i < 44; i++) {
      bytes[i] ^= i < 24 ? firstMask : secondMask;
    }
    fields.setUint32(
      44,
      _crc32(Uint8List.sublistView(bytes, 0, 44)),
      Endian.little,
    );
    return base64Encode(bytes);
  }

  Uint8List encrypt(String form) {
    final bytes = utf8.encode(form);
    final padded = Uint8List((bytes.length + 15) ~/ 16 * 16);
    padded.setRange(0, bytes.length, bytes);
    return _crypt(padded, encrypt: true);
  }

  Map<String, dynamic> decodeResponse(Uint8List bytes) {
    final payloadLength = bytes.length - 12;
    if (payloadLength < 16 || payloadLength % 16 != 0) {
      throw const FormatException('Invalid 115 upload response length');
    }
    final tail = Uint8List.sublistView(bytes, payloadLength);
    final fields = ByteData.sublistView(tail);
    if (_crc32(Uint8List.sublistView(tail, 0, 8)) !=
        fields.getUint32(8, Endian.little)) {
      throw const FormatException('Invalid 115 upload response checksum');
    }
    var length = 0;
    for (var i = 0; i < 4; i++) {
      length |= (tail[i] ^ tail[7]) << (i * 8);
    }
    if (length == 0 || length > 1024 * 1024) {
      throw const FormatException('Invalid 115 upload response size');
    }

    final plaintext = _crypt(
      Uint8List.sublistView(bytes, 0, payloadLength),
      encrypt: false,
    );
    final output = Uint8List(length);
    var sourceOffset = 0;
    for (var offset = 0; offset < output.length; offset += 8192) {
      final compressedLength = ByteData.sublistView(
        plaintext,
      ).getUint16(sourceOffset, Endian.little);
      sourceOffset += 2;
      _decodeLz4Block(
        Uint8List.sublistView(
          plaintext,
          sourceOffset,
          sourceOffset + compressedLength,
        ),
        Uint8List.sublistView(output, offset, min(offset + 8192, length)),
      );
      sourceOffset += compressedLength;
    }
    final result = jsonDecode(utf8.decode(output));
    if (result is! Map<String, dynamic>) {
      throw const FormatException('Invalid 115 upload response');
    }
    return result;
  }

  Uint8List _crypt(Uint8List data, {required bool encrypt}) {
    final cipher = CBCBlockCipher(AESEngine())..init(
      encrypt,
      ParametersWithIV(
        KeyParameter(Uint8List.sublistView(_sharedSecret, 0, 16)),
        Uint8List.sublistView(_sharedSecret, _sharedSecret.length - 16),
      ),
    );
    final output = Uint8List(data.length);
    for (var offset = 0; offset < data.length; offset += cipher.blockSize) {
      cipher.processBlock(data, offset, output, offset);
    }
    return output;
  }

  static int _crc32(List<int> bytes) {
    var crc = 0xffffffff;
    for (final byte in [..._crcSalt, ...bytes]) {
      crc ^= byte;
      for (var i = 0; i < 8; i++) {
        crc = (crc >> 1) ^ ((crc & 1) == 0 ? 0 : 0xedb88320);
      }
    }
    return crc ^ 0xffffffff;
  }

  static void _decodeLz4Block(Uint8List source, Uint8List output) {
    var input = 0;
    var written = 0;

    int readLength(int length) {
      if (length < 15) return length;
      int next;
      do {
        next = source[input++];
        length += next;
      } while (next == 255);
      return length;
    }

    while (input < source.length) {
      final token = source[input++];
      final literals = readLength(token >> 4);
      output.setRange(written, written + literals, source, input);
      written += literals;
      input += literals;
      if (input == source.length) break;

      final distance = source[input] | (source[input + 1] << 8);
      input += 2;
      if (distance == 0 || distance > written) {
        throw const FormatException('Invalid 115 upload response block');
      }
      final matchLength = readLength(token & 15) + 4;
      for (var i = 0; i < matchLength; i++) {
        output[written] = output[written - distance];
        written++;
      }
    }
    if (written != output.length) {
      throw const FormatException('Incomplete 115 upload response block');
    }
  }
}
