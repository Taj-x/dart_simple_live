import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

String _errorSummary(Object e) {
  if (e is FormatException) return e.message;
  if (e is HttpException) return e.message;
  return e.runtimeType.toString();
}

/// A signed URL and a conservative deadline measured from requesting that URL.
class FlvLease {
  final Uri uri;
  final Map<String, String> headers;
  final DateTime? renewAt;

  FlvLease(String url, {Map<String, String>? headers, DateTime? requestedAt})
    : uri = Uri.parse(url),
      headers = Map.unmodifiable(headers ?? const {}),
      renewAt = _deadline(url, requestedAt ?? DateTime.now());

  static bool appliesTo(String url) {
    final uri = Uri.tryParse(url);
    return uri != null &&
        (uri.scheme == 'http' || uri.scheme == 'https') &&
        uri.path.toLowerCase().endsWith('.flv') &&
        (int.tryParse(uri.queryParameters['expire'] ?? '') ?? 0) > 0;
  }

  static DateTime? _deadline(String url, DateTime requestedAt) {
    final seconds = int.tryParse(
      Uri.parse(url).queryParameters['expire'] ?? '',
    );
    if (seconds == null || seconds <= 0) return null;
    final margin = min(45, max(1, seconds ~/ 4));
    return requestedAt.add(Duration(seconds: max(1, seconds - margin)));
  }
}

/// One FLV tag, excluding the file header. Sequence headers are not keyframes.
class FlvTag {
  final Uint8List bytes;
  FlvTag(this.bytes);
  int get type => bytes[0];
  int get timestamp =>
      (bytes[7] << 24) | (bytes[4] << 16) | (bytes[5] << 8) | bytes[6];
  int get payloadLength => bytes.length - 15;
  bool get isMedia => type == 8 || type == 9;
  bool get isVideoConfig =>
      type == 9 &&
      payloadLength >= 2 &&
      (bytes[11] & 15) == 7 &&
      bytes[12] == 0;
  bool get isAudioConfig =>
      type == 8 &&
      payloadLength >= 2 &&
      (bytes[11] >> 4) == 10 &&
      bytes[12] == 0;
  bool get isConfig => isVideoConfig || isAudioConfig;
  bool get isKeyframe =>
      type == 9 &&
      payloadLength >= 2 &&
      (bytes[11] >> 4) == 1 &&
      (bytes[11] & 15) == 7 &&
      bytes[12] == 1;
  bool get isVideoPacket => type == 9 && !isVideoConfig;
  bool get isAudioPacket => type == 8 && !isAudioConfig;

  Uint8List atTimestamp(int timestamp) {
    final result = Uint8List.fromList(bytes);
    result[4] = (timestamp >> 16) & 255;
    result[5] = (timestamp >> 8) & 255;
    result[6] = timestamp & 255;
    result[7] = (timestamp >> 24) & 255;
    return result;
  }
}

/// Incremental FLV reader: supports HTTP chunks splitting any header/tag field.
class FlvReader {
  final StreamIterator<List<int>> _iterator;
  final Duration idleTimeout;
  List<int> _chunk = const [];
  int _position = 0;
  bool _headerRead = false;
  FlvReader(
    Stream<List<int>> stream, {
    this.idleTimeout = const Duration(seconds: 15),
  }) : _iterator = StreamIterator(stream);

  Future<Uint8List?> _read(int length, {bool allowEof = false}) async {
    final result = Uint8List(length);
    var offset = 0;
    while (offset < length) {
      if (_position == _chunk.length) {
        if (!await _iterator.moveNext().timeout(idleTimeout)) {
          if (allowEof && offset == 0) return null;
          throw const FormatException('Truncated FLV');
        }
        _chunk = _iterator.current;
        _position = 0;
        if (_chunk.isEmpty) continue;
      }
      final count = min(length - offset, _chunk.length - _position);
      result.setRange(offset, offset + count, _chunk, _position);
      offset += count;
      _position += count;
    }
    return result;
  }

  Future<Uint8List> readHeader() async {
    if (_headerRead) throw StateError('FLV header already read');
    final header = (await _read(9))!;
    if (header[0] != 70 ||
        header[1] != 76 ||
        header[2] != 86 ||
        header[3] != 1) {
      throw const FormatException('Expected FLV version 1');
    }
    final length = ByteData.sublistView(header).getUint32(5);
    if (length < 9 || length > 65536) {
      throw const FormatException('Invalid FLV header length');
    }
    final tail = (await _read(length - 9 + 4))!;
    if (ByteData.sublistView(tail).getUint32(tail.length - 4) != 0) {
      throw const FormatException('Invalid first FLV previous-tag size');
    }
    _headerRead = true;
    return Uint8List.fromList([...header, ...tail]);
  }

  Future<FlvTag?> next() async {
    if (!_headerRead) throw StateError('Read the FLV header first');
    final header = await _read(11, allowEof: true);
    if (header == null) return null;
    if (header[0] != 8 && header[0] != 9 && header[0] != 18) {
      throw const FormatException('Unsupported FLV tag type');
    }
    final size = (header[1] << 16) | (header[2] << 8) | header[3];
    if (size > 8 * 1024 * 1024) {
      throw const FormatException('FLV tag exceeds relay memory limit');
    }
    final payload = (await _read(size + 4))!;
    if (ByteData.sublistView(payload).getUint32(size) != size + 11) {
      throw const FormatException('Invalid FLV previous-tag size');
    }
    return FlvTag(Uint8List.fromList([...header, ...payload]));
  }

  Future<void> close() => _iterator.cancel();
}

/// Loopback relay for expiring H.264 FLV sources. The downstream receives one
/// header and one continuous timestamp sequence, even across signed URL leases.
/// Only aligned timelines are spliced; otherwise ordinary player recovery wins.
class FlvLeaseRelay {
  final FlvLease initial;
  final Future<FlvLease> Function() renew;
  final void Function(String) log;
  final Duration warmTimeout;
  HttpServer? _server;
  _RelaySession? _session;
  bool _closed = false;
  late String _path;

  FlvLeaseRelay({
    required this.initial,
    required this.renew,
    required this.log,
    this.warmTimeout = const Duration(seconds: 20),
  });

  Future<String> start() async {
    _path =
        '/${List.generate(24, (_) => Random.secure().nextInt(256).toRadixString(16).padLeft(2, '0')).join()}/live.flv';
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    if (_closed) {
      await server.close(force: true);
      throw StateError('Relay closed while starting');
    }
    _server = server;
    server.listen(
      _handle,
      onError: (Object e) => log('FLV中继服务错误: ${e.runtimeType}'),
    );
    return 'http://127.0.0.1:${server.port}$_path';
  }

  Future<void> _handle(HttpRequest request) async {
    final response = request.response;
    if (_closed || request.uri.path != _path) {
      response.statusCode = HttpStatus.notFound;
      await response.close();
      return;
    }
    response.headers.set(HttpHeaders.contentTypeHeader, 'video/x-flv');
    response.headers.set(HttpHeaders.cacheControlHeader, 'no-store');
    response.headers.set('Accept-Ranges', 'none');
    if (request.method == 'HEAD') {
      await response.close();
      return;
    }
    if (request.method != 'GET' || _session != null) {
      response.statusCode = HttpStatus.conflict;
      await response.close();
      return;
    }
    response.bufferOutput = false;
    final session = _RelaySession(this, response);
    _session = session;
    // A player disconnect must release both upstream connections immediately.
    unawaited(
      response.done.then(
        (_) => session.close(),
        onError: (Object _, StackTrace __) => session.close(),
      ),
    );
    try {
      await session.run();
    } catch (e) {
      if (!_closed && !session.closed) {
        log('FLV续流退出，交给播放器自动重连: ${_errorSummary(e)}');
      }
    } finally {
      session.close();
      if (identical(_session, session)) _session = null;
      try {
        await response.close();
      } catch (_) {}
    }
  }

  Future<void> close() async {
    _closed = true;
    _session?.close();
    await _server?.close(force: true);
    _server = null;
  }
}

class _Upstream {
  final HttpClient client;
  final FlvReader reader;
  final Uint8List header;
  final FlvLease lease;
  _Upstream(this.client, this.reader, this.header, this.lease);
  void close() {
    client.close(force: true);
    unawaited(reader.close());
  }
}

class _WarmStream {
  final _Upstream upstream;
  final List<FlvTag> configs;
  final FlvTag keyframe;
  _WarmStream(this.upstream, this.configs, this.keyframe);
}

class _RelaySession {
  final FlvLeaseRelay relay;
  final HttpResponse output;
  final Set<HttpClient> _clients = {};
  bool closed = false;
  bool _warming = false;
  _Upstream? _active;
  _WarmStream? _ready;
  DateTime _retryAt = DateTime.fromMillisecondsSinceEpoch(0);
  int _lastVideo = -1;
  int _lastAudio = -1;
  int _bytesSinceFlush = 0;

  _RelaySession(this.relay, this.output);

  Future<_Upstream> _open(FlvLease lease) async {
    if (closed) throw StateError('Session closed');
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 10);
    _clients.add(client);
    try {
      final request = await client.getUrl(lease.uri).timeout(relay.warmTimeout);
      lease.headers.forEach((key, value) => request.headers.set(key, value));
      final response = await request.close().timeout(relay.warmTimeout);
      if (response.statusCode != HttpStatus.ok) {
        throw HttpException('Upstream HTTP ${response.statusCode}');
      }
      final reader = FlvReader(response);
      final header = await reader.readHeader();
      if (closed) throw StateError('Session closed');
      return _Upstream(client, reader, header, lease);
    } catch (_) {
      client.close(force: true);
      _clients.remove(client);
      rethrow;
    }
  }

  Future<void> run() async {
    _active = await _open(relay.initial);
    output.add(_active!.header);
    while (!closed) {
      final active = _active!;
      final now = DateTime.now();
      final deadline = active.lease.renewAt;
      if (deadline != null &&
          !now.isBefore(deadline) &&
          !now.isBefore(_retryAt) &&
          !_warming &&
          _ready == null &&
          _lastVideo >= 0) {
        unawaited(_warm());
      }
      final tag = await active.reader.next();
      if (closed) return;
      final ready = _ready;
      if (ready != null &&
          (tag == null ||
              (tag.isMedia &&
                  !tag.isConfig &&
                  tag.timestamp >= ready.keyframe.timestamp))) {
        // Old tags before this keyframe were delivered. Drop the overlapping
        // old suffix and the new prefix: the new keyframe is emitted only once.
        _ready = null;
        active.close();
        _clients.remove(active.client);
        _active = ready.upstream;
        for (final config in ready.configs) {
          output.add(config.atTimestamp(ready.keyframe.timestamp));
        }
        await _emit(ready.keyframe);
        await output.flush();
        relay.log('斗鱼FLV关键帧续流完成，播放器连接保持不变');
        continue;
      }
      if (tag == null)
        throw const HttpException('FLV stream ended before handover');
      await _emit(tag);
    }
  }

  Future<void> _emit(FlvTag tag) async {
    if (tag.isVideoPacket) {
      if (tag.timestamp <= _lastVideo) return;
      _lastVideo = tag.timestamp;
    } else if (tag.isAudioPacket) {
      if (tag.timestamp <= _lastAudio) return;
      _lastAudio = tag.timestamp;
    }
    output.add(tag.bytes);
    _bytesSinceFlush += tag.bytes.length;
    if (_bytesSinceFlush >= 64 * 1024) {
      _bytesSinceFlush = 0;
      await output.flush();
    }
  }

  Future<void> _warm() async {
    _warming = true;
    _Upstream? fresh;
    var expired = false;
    // Bound the whole operation, including API renewal and keyframe search.
    final timer = Timer(relay.warmTimeout, () {
      expired = true;
      fresh?.close();
    });
    try {
      relay.log('斗鱼FLV提前续期：旧连接继续播放，正在预热新连接');
      final lease = await relay.renew().timeout(relay.warmTimeout);
      if (closed || expired) throw StateError('Warmup cancelled');
      final candidate = await _open(lease);
      fresh = candidate;
      if (candidate.header[4] != _active!.header[4]) {
        throw const FormatException('FLV track layout changed');
      }
      if (closed || expired) throw StateError('Warmup cancelled');
      final configs = <int, FlvTag>{};
      while (!closed && !expired) {
        final tag = await candidate.reader.next();
        if (tag == null) throw const HttpException('New FLV stream ended');
        if (tag.isConfig) configs[tag.type] = tag;
        if (tag.type == 9 &&
            tag.payloadLength > 0 &&
            (tag.bytes[11] & 15) != 7) {
          throw const FormatException('Seamless relay requires H.264 FLV');
        }
        if (!tag.isKeyframe) continue;
        // Do not invent an offset for a different timeline; that can skip a
        // large amount of content or destroy lip sync. Keep recovery as fallback.
        if ((tag.timestamp - _lastVideo).abs() > 60000) {
          throw const FormatException('FLV timelines are not aligned');
        }
        if (tag.timestamp <= max(_lastVideo, _lastAudio)) continue;
        if (!configs.containsKey(9)) {
          throw const FormatException('New FLV is missing AVC configuration');
        }
        _ready = _WarmStream(candidate, configs.values.toList(), tag);
        fresh = null; // Ownership transfers to the active pump.
        return;
      }
    } catch (e) {
      if (!closed) relay.log('斗鱼FLV预热未成功，保留旧连接: ${_errorSummary(e)}');
      _retryAt = DateTime.now().add(const Duration(seconds: 5));
    } finally {
      timer.cancel();
      if (fresh != null) {
        fresh.close();
        _clients.remove(fresh.client);
      }
      _warming = false;
    }
  }

  void close() {
    if (closed) return;
    closed = true;
    for (final client in _clients.toList()) {
      client.close(force: true);
    }
    _clients.clear();
    _active?.close();
    _ready?.upstream.close();
    _ready = null;
  }
}
