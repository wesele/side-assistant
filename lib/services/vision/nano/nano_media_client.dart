import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:http/http.dart' as http;
import '../../../core/platform/foundation_bridge.dart';
import 'duml_packet.dart';
import 'nano_commands.dart';
import 'nano_datalink.dart';

const Set<String> photoExtensions = {
  'JPG',
  'JPEG',
  'DNG',
  'HEIC',
  'TIF',
  'TIFF',
  'PANO'
};
const Set<String> videoExtensions = {
  'MP4',
  'MOV',
  'OSV',
  'INSV',
  'LRF',
  'LRV',
  'XRF'
};

class NanoMediaFile {
  final String path;
  final int handle;
  final int sizeBytes;
  final bool isPhoto;
  final int storage; // 0 = SD, 1 = 内置

  const NanoMediaFile({
    required this.path,
    required this.handle,
    required this.sizeBytes,
    required this.isPhoto,
    required this.storage,
  });

  String get name => path.split('/').last;

  @override
  String toString() =>
      'NanoMediaFile($name, size=$sizeBytes, storage=$storage, isPhoto=$isPhoto)';
}

class MediaChunkAssembler {
  final Map<int, BytesBuilder> _data = {};
  final Set<int> _started = {};
  final Set<int> _ended = {};
  final Map<int, DateTime> _startTimes = {};

  void reset() {
    _data.clear();
    _started.clear();
    _ended.clear();
    _startTimes.clear();
  }

  bool ingest(DumlFrame frame) {
    if (frame.cmdSet != 0x00 || frame.cmdId != 0x27) return false;
    final p = frame.payload;
    if (p.length < 10 || p[0] != 0x4A) return false;
    final subtype = p[1];
    final counter = p[4];

    if (subtype == 0x04) {
      _started.add(counter);
      _startTimes[counter] = DateTime.now();
      _data.putIfAbsent(counter, () => BytesBuilder(copy: false));
      return true;
    }
    if (subtype == 0x03) {
      _ended.add(counter);
      return true;
    }
    if (subtype == 0x01 && p.length > 10) {
      _data
          .putIfAbsent(counter, () => BytesBuilder(copy: false))
          .add(p.sublist(10));
      return true;
    }
    return false;
  }

  bool isClosed(int counter) {
    if (_ended.contains(counter)) return true;
    if (_started.contains(counter) && (_data[counter]?.isEmpty ?? true)) {
      final st = _startTimes[counter];
      if (st != null && DateTime.now().difference(st).inMilliseconds > 200) {
        return true;
      }
    }
    return false;
  }

  bool isStartedEmpty(int counter) {
    return _started.contains(counter) && (_data[counter]?.isEmpty ?? true);
  }

  Uint8List getBytes(int counter) {
    return _data[counter]?.toBytes() ?? Uint8List(0);
  }
}

class NanoMediaClient {
  final NanoDatalink datalink;

  NanoMediaClient(this.datalink);

  static int _u32(Uint8List data, int off) {
    if (off + 4 > data.length || off < 0) return 0;
    return data[off] |
        (data[off + 1] << 8) |
        (data[off + 2] << 16) |
        (data[off + 3] << 24);
  }

  static (String, int)? _readPath(
      Uint8List data, int i, int sub, String prefix) {
    if (i + 6 > data.length || data[i] != 0x1A) return null;
    if (data[i + 2] != 0 || data[i + 3] != 0 || data[i + 4] != 0) return null;
    if (data[i + 5] != sub) return null;
    final slen = data[i + 1] - 6;
    if (slen < prefix.length || i + 6 + slen > data.length) return null;
    final raw = data.sublist(i + 6, i + 6 + slen);
    for (final b in raw) {
      if (b < 0x20 || b > 0x7E) return null;
    }
    final value = latin1.decode(raw);
    if (!value.startsWith(prefix)) return null;
    return (value, i + 6 + slen);
  }

  /// CompositePack TLV 解析
  static List<NanoMediaFile> decodeManifest(Uint8List data, int storage) {
    final anchors = <(int, int, String)>[];
    int i = 0;
    while (i < data.length) {
      final found = _readPath(data, i, 1, 'DCIM/');
      if (found != null) {
        anchors.add((i, found.$2, found.$1));
        i = found.$2;
      } else {
        i++;
      }
    }
    if (anchors.isEmpty) return [];

    final out = <NanoMediaFile>[];
    final seen = <String>{};

    for (int k = 0; k < anchors.length; k++) {
      final pos = anchors[k].$1;
      final dir = anchors[k].$3;
      if (!seen.add(dir)) continue;

      final lo = k > 0 ? anchors[k - 1].$2 : 0;
      final hi = k + 1 < anchors.length ? anchors[k + 1].$1 : data.length;
      final base = dir.split('/').last;
      final window = data.sublist(lo, hi);

      String ext = '';
      for (int n = 0; n < window.length - 2; n++) {
        if (window[n] == 0x0D) {
          final len = window[n + 1];
          if (len > base.length && n + 2 + len <= window.length) {
            final raw = window.sublist(n + 2, n + 2 + len);
            try {
              final val = latin1.decode(raw);
              if (val.startsWith('$base.')) {
                final cand = val.substring(base.length + 1).toUpperCase();
                if (photoExtensions.contains(cand) ||
                    videoExtensions.contains(cand)) {
                  ext = cand;
                  break;
                }
              }
            } catch (_) {}
          }
        }
      }

      int handle = 0;
      int head = -1;
      for (int m = 0; m < window.length - 4; m++) {
        if ((window[m] == 0x03 || window[m] == 0x00) &&
            (window[m + 1] == 0xFF || window[m + 1] == 0xFE) &&
            window[m + 2] == 0x19 &&
            window[m + 3] == 0x06 &&
            m >= 8) {
          head = m - 8;
          break;
        }
      }

      if (head >= 0 && lo + head + 4 <= data.length) {
        handle = _u32(data, lo + head);
      } else if (pos >= 17 && data[pos - 7] == 0x19 && data[pos - 6] == 0x06) {
        handle = _u32(data, pos - 17);
      }

      final isPhoto = !videoExtensions.contains(ext);
      int size = 0;
      if (!isPhoto) {
        if (head >= 4) size = _u32(data, lo + head - 4);
      } else {
        for (int q = 0; q < window.length - 3; q++) {
          if ((window[q] == 0xFF || window[q] == 0xFE) &&
              window[q + 1] == 0x19 &&
              window[q + 2] == 0x06) {
            final mk = lo + q + 1;
            if (mk >= 14) size = _u32(data, mk - 14);
            break;
          }
        }
      }

      final finalStorage = (handle & 0x40000000) != 0 ? 1 : storage;
      final fullPath = ext.isEmpty ? dir : '$dir.$ext';
      out.add(NanoMediaFile(
        path: fullPath,
        handle: handle,
        sizeBytes: size,
        isPhoto: isPhoto,
        storage: finalStorage,
      ));
    }
    return out;
  }

  /// 获取媒体清单（先查 SD 卡，若为空查内置存储）
  Future<List<NanoMediaFile>> listMedia(
      {Duration timeout = const Duration(seconds: 4)}) async {
    final assembler = MediaChunkAssembler();
    final sub = datalink.frameStream.listen((frame) {
      assembler.ingest(frame);
    });

    try {
      // counter 1 = SD, cursor 1 = latest
      datalink.sendCommand(mediaList(1, 1));
      await Future.delayed(const Duration(milliseconds: 10));
      datalink.sendCommand(mediaListTrigger());
      await Future.delayed(const Duration(milliseconds: 10));
      // counter 2 = 内置存储, cursor 0x40000001
      datalink.sendCommand(mediaList(2, 0x40000001));
      await Future.delayed(const Duration(milliseconds: 10));
      datalink.sendCommand(mediaListTrigger());

      final started = DateTime.now();
      final deadline = DateTime.now().add(timeout);
      while (DateTime.now().isBefore(deadline)) {
        if (assembler.isClosed(1) && assembler.isClosed(2)) break;
        if (assembler.isClosed(2) &&
            (assembler.isClosed(1) || assembler.isStartedEmpty(1))) break;
        if (assembler.isClosed(1) &&
            (assembler.isClosed(2) || assembler.isStartedEmpty(2))) break;
        if ((assembler.isClosed(1) || assembler.isClosed(2)) &&
            DateTime.now().difference(started).inMilliseconds > 1200) {
          break;
        }
        await Future.delayed(const Duration(milliseconds: 25));
      }

      final sdBytes = assembler.getBytes(1);
      final intBytes = assembler.getBytes(2);
      debugPrint(
          '[NanoMediaClient] C1 字节: ${sdBytes.length}, C2 字节: ${intBytes.length}');

      final results = <NanoMediaFile>[];
      if (sdBytes.isNotEmpty) {
        results.addAll(decodeManifest(sdBytes, 0));
      }
      if (intBytes.isNotEmpty) {
        results.addAll(decodeManifest(intBytes, 1));
      }
      return results;
    } finally {
      await sub.cancel();
    }
  }

  /// 从 Nano SoftAP 下载指定照片至本地文件
  static Future<Uint8List> downloadPhotoBytes({
    required String host,
    required NanoMediaFile file,
    Duration timeout = const Duration(seconds: 15),
  }) async {
    final pathEncoded =
        Uri.encodeQueryComponent(file.path).replaceAll('%2F', '/');
    final urlStr = 'http://$host/v2?storage=${file.storage}&path=$pathEncoded';
    final uri = Uri.parse(urlStr);

    final response = await http.get(uri).timeout(timeout);
    if (response.statusCode != 200) {
      throw HttpException(
          'HTTP 下载照片失败: 状态码 ${response.statusCode} (URL: $urlStr)');
    }

    final bytes = response.bodyBytes;
    if (bytes.length < 3 ||
        bytes[0] != 0xFF ||
        bytes[1] != 0xD8 ||
        bytes[2] != 0xFF) {
      throw FormatException(
          '下载的文件不是有效 JPEG 图片 (Magic: ${bytes.take(3).toList()})');
    }
    return bytes;
  }
}
