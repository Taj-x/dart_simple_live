// Standalone protocol tests. No Flutter, platform plugins or live credentials.
// Run: dart tool/flv_lease_relay_test.dart
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import '../lib/services/flv_lease_relay.dart';

const header = <int>[70, 76, 86, 1, 5, 0, 0, 0, 9, 0, 0, 0, 0];

Uint8List tag(int type, int time, List<int> body) {
  final b = Uint8List(body.length + 15);
  b[0] = type;
  b[1] = (body.length >> 16) & 255;
  b[2] = (body.length >> 8) & 255;
  b[3] = body.length & 255;
  b[4] = (time >> 16) & 255;
  b[5] = (time >> 8) & 255;
  b[6] = time & 255;
  b[7] = (time >> 24) & 255;
  b.setRange(11, 11 + body.length, body);
  ByteData.sublistView(b).setUint32(b.length - 4, body.length + 11);
  return b;
}

void check(bool value, String message) {
  if (!value) throw StateError(message);
}

Future<void> parserTests() async {
  final key = tag(9, 0x12345678, [0x17, 1, 0, 0, 0, 42]);
  final bytes = [
    ...header,
    ...key,
    ...tag(8, 0x12345679, [0xaf, 1, 42]),
  ];
  final reader = FlvReader(Stream.fromIterable(bytes.map((b) => [b])));
  check((await reader.readHeader()).length == 13, 'Header parsing');
  final parsed = (await reader.next())!;
  check(
    parsed.timestamp == 0x12345678 && parsed.isKeyframe,
    'Extended timestamp',
  );
  check(FlvTag(parsed.atTimestamp(42)).timestamp == 42, 'Timestamp rewrite');
  check((await reader.next())!.isAudioPacket, 'Audio parsing');
  check(await reader.next() == null, 'Clean EOF');
  await reader.close();
  check(
    !FlvTag(tag(9, 0, [0x17, 0, 0, 0, 0])).isKeyframe,
    'AVC configuration must not be treated as a keyframe',
  );
  for (final corrupt in [
    <int>[0, ...header.skip(1)],
    [...header, ...key.take(key.length - 1)],
    [...header, ...key.take(key.length - 1), 0],
  ]) {
    final bad = FlvReader(Stream.value(corrupt));
    var rejected = false;
    try {
      await bad.readHeader();
      await bad.next();
    } on FormatException {
      rejected = true;
    } finally {
      await bad.close();
    }
    check(rejected, 'Malformed FLV was accepted');
  }
  final now = DateTime(2026);
  check(
    FlvLease('https://example/live.flv?expire=300', requestedAt: now).renewAt ==
        now.add(const Duration(seconds: 255)),
    '45-second safety margin',
  );
  check(
    !FlvLease.appliesTo('https://example/live.flv?expire=0'),
    'Unlimited lease',
  );
  check(
    !FlvLease.appliesTo('https://example/live.m3u8?expire=300'),
    'FLV only',
  );
  stdout.writeln('PASS incremental parser, malformed data, lease deadlines');
}

class FakeCdn {
  final HttpServer server;
  final Stopwatch clock = Stopwatch()..start();
  final Set<HttpResponse> outputs = {};
  int opened = 0;
  bool closed = false;
  int? failFrom;
  int timestampOffset = 0;
  FakeCdn._(this.server);
  static Future<FakeCdn> start() async {
    final result = FakeCdn._(
      await HttpServer.bind(InternetAddress.loopbackIPv4, 0),
    );
    result.server.listen(result.handle);
    return result;
  }

  String get url => 'http://127.0.0.1:${server.port}/live.flv?expire=2';
  Future<void> handle(HttpRequest request) async {
    final connection = ++opened;
    final response = request.response;
    if (failFrom != null && opened >= failFrom!) {
      response.statusCode = 403;
      await response.close();
      return;
    }
    final offset = connection > 1 ? timestampOffset : 0;
    // Model a newly opened CDN connection with a little less transport latency.
    // Both still share one media timeline. If both generate and deliver the same
    // keyframe in the same event-loop turn, test success depends on OS ordering.
    final transportLead = connection * 80;
    outputs.add(response);
    response.bufferOutput = false;
    response.headers.contentType = ContentType('video', 'x-flv');
    response.add(header);
    response.add(tag(9, 0, [0x17, 0, 0, 0, 0, 1, 2, 3]));
    response.add(tag(8, 0, [0xaf, 0, 0x12, 0x10]));
    var disconnected = false;
    unawaited(
      response.done.then(
        (_) {
          disconnected = true;
        },
        onError: (Object _) {
          disconnected = true;
        },
      ),
    );
    var last = (clock.elapsedMilliseconds + transportLead) ~/ 20 - 1;
    try {
      while (!disconnected && !closed) {
        final tick = (clock.elapsedMilliseconds + transportLead) ~/ 20;
        while (last < tick) {
          last++;
          final time = last * 20 + offset;
          response.add(tag(8, time, [0xaf, 1, 42]));
          if (last.isEven) {
            response.add(
              tag(9, time, [last % 10 == 0 ? 0x17 : 0x27, 1, 0, 0, 0, 42]),
            );
          }
          await response.flush();
        }
        // Coarse polling also exercises Windows-like timer granularity.
        await Future<void>.delayed(const Duration(milliseconds: 16));
      }
    } catch (_) {
    } finally {
      outputs.remove(response);
      try {
        await response.close();
      } catch (_) {}
    }
  }

  Future<void> close() async {
    closed = true;
    await server.close(force: true);
  }
}

Future<void> relayTest({
  bool failRenewal = false,
  bool badTimeline = false,
}) async {
  final cdn = await FakeCdn.start();
  if (failRenewal) cdn.failFrom = 2;
  if (badTimeline) cdn.timestampOffset = 120000;
  final logs = <String>[];
  var renewals = 0;
  final relay = FlvLeaseRelay(
    initial: FlvLease(cdn.url),
    renew: () async {
      renewals++;
      return FlvLease(cdn.url);
    },
    log: logs.add,
    warmTimeout: const Duration(seconds: 2),
  );
  final client = HttpClient();
  FlvReader? reader;
  try {
    final url = await relay.start();
    final forbidden = await (await client.getUrl(
      Uri.parse('$url-wrong'),
    )).close();
    check(forbidden.statusCode == 404, 'Loopback path must be protected');
    await forbidden.drain<void>();
    final head = await client.openUrl('HEAD', Uri.parse(url));
    await (await head.close()).drain<void>();
    final response = await (await client.getUrl(Uri.parse(url))).close();
    reader = FlvReader(response, idleTimeout: const Duration(seconds: 3));
    await reader.readHeader();
    var lastVideo = -1;
    var lastAudio = -1;
    var maxVideoGap = 0;
    var maxAudioGap = 0;
    var configs = 0;
    // Wait for the behavior being tested, not two renewals inside an arbitrary
    // 3.8-second wall-clock window. The timeout still fails broken renewal.
    final start = cdn.clock.elapsedMilliseconds;
    final end = start + 15000;
    while (cdn.clock.elapsedMilliseconds < end) {
      final packet = await reader.next();
      check(packet != null, 'Downstream disconnected');
      final t = packet!;
      if (t.isVideoConfig) configs++;
      if (t.isVideoPacket) {
        check(t.timestamp > lastVideo, 'Video timestamp repeated/reversed');
        if (lastVideo >= 0 && t.timestamp - lastVideo > maxVideoGap) {
          maxVideoGap = t.timestamp - lastVideo;
        }
        lastVideo = t.timestamp;
      }
      if (t.isAudioPacket) {
        check(t.timestamp > lastAudio, 'Audio timestamp repeated/reversed');
        if (lastAudio >= 0 && t.timestamp - lastAudio > maxAudioGap) {
          maxAudioGap = t.timestamp - lastAudio;
        }
        lastAudio = t.timestamp;
      }
      final handovers = logs.where((s) => s.contains('关键帧续流完成')).length;
      if (!failRenewal && !badTimeline && configs >= 3 && handovers >= 2) break;
      if ((failRenewal || badTimeline) &&
          logs.any((s) => s.contains('保留旧连接')) &&
          cdn.clock.elapsedMilliseconds - start >= 2500)
        break;
    }
    check(renewals >= 1, 'No renewal attempted');
    check(
      maxVideoGap <= 80 && maxAudioGap <= 60,
      'Timeline gap: video=$maxVideoGap audio=$maxAudioGap',
    );
    if (failRenewal || badTimeline) {
      check(configs == 1, 'Failed renewal changed downstream source');
      check(logs.any((s) => s.contains('保留旧连接')), 'No fallback logged');
    } else {
      check(
        configs >= 3,
        'Expected at least two handovers; '
        'renewals=$renewals, configs=$configs, logs=$logs',
      );
      check(
        logs.where((s) => s.contains('关键帧续流完成')).length >= 2,
        'No seamless handovers',
      );
    }
    final before = renewals;
    await relay.close();
    await Future<void>.delayed(const Duration(milliseconds: 100));
    check(renewals == before, 'Renewal after disposal');
    stdout.writeln(
      'PASS ${failRenewal
          ? "HTTP failure"
          : badTimeline
          ? "unaligned timeline"
          : "multiple seamless handovers"}: '
      'video gap=$maxVideoGap ms, audio gap=$maxAudioGap ms',
    );
  } finally {
    await relay.close();
    await reader?.close();
    client.close(force: true);
    await cdn.close();
  }
}

// Optional real-codec integration test. Create an 8-second H.264/AAC FLV
// fixture with FFmpeg and pass its path plus the captured output path.
Future<void> encodedFixtureTest(String fixturePath, String outputPath) async {
  final fileReader = FlvReader(File(fixturePath).openRead());
  final fileHeader = await fileReader.readHeader();
  final packets = <FlvTag>[];
  while (true) {
    final t = await fileReader.next();
    if (t == null) break;
    packets.add(t);
  }
  await fileReader.close();
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  final clock = Stopwatch()..start();
  var upstreams = 0;
  var stopped = false;
  server.listen((request) async {
    final number = ++upstreams;
    final r = request.response;
    r.bufferOutput = false;
    var disconnected = false;
    unawaited(
      r.done.then(
        (_) {
          disconnected = true;
        },
        onError: (Object _) {
          disconnected = true;
        },
      ),
    );
    try {
      r.add(fileHeader);
      final start = number == 1 ? 0 : clock.elapsedMilliseconds - 500;
      for (final t in packets) {
        if (stopped || disconnected) break;
        if (t.isConfig || t.type == 18) {
          r.add(t.bytes);
          continue;
        }
        if (t.timestamp < start) continue;
        final due = t.timestamp + (number == 1 ? 40 : 0);
        final wait = due - clock.elapsedMilliseconds;
        if (wait > 0) await Future<void>.delayed(Duration(milliseconds: wait));
        if (stopped || disconnected) break;
        r.add(t.bytes);
        await r.flush();
      }
    } catch (_) {
    } finally {
      try {
        await r.close();
      } catch (_) {}
    }
  });
  String source() => 'http://127.0.0.1:${server.port}/encoded.flv?expire=2';
  final logs = <String>[];
  final relay = FlvLeaseRelay(
    initial: FlvLease(source()),
    renew: () async => FlvLease(source()),
    log: logs.add,
  );
  final client = HttpClient();
  FlvReader? downstream;
  final sink = File(outputPath).openWrite();
  try {
    final local = await relay.start();
    final response = await (await client.getUrl(Uri.parse(local))).close();
    downstream = FlvReader(response);
    sink.add(await downstream.readHeader());
    var first = -1;
    while (true) {
      final t = await downstream.next();
      check(t != null, 'Encoded relay ended unexpectedly');
      sink.add(t!.bytes);
      if (t.isVideoPacket) {
        if (first < 0) first = t.timestamp;
        if (t.timestamp - first >= 5000) break;
      }
    }
    check(
      logs.where((s) => s.contains('关键帧续流完成')).length >= 2,
      'Encoded fixture did not exercise multiple handovers',
    );
    stdout.writeln(
      'PASS encoded H.264/AAC FLV: multiple handovers on one HTTP connection',
    );
  } finally {
    stopped = true;
    await relay.close();
    await downstream?.close();
    client.close(force: true);
    await sink.close();
    await server.close(force: true);
  }
}

Future<void> main(List<String> args) async {
  if (args.length == 2) {
    await encodedFixtureTest(args[0], args[1]);
    return;
  }
  await parserTests();
  await relayTest();
  await relayTest(failRenewal: true);
  await relayTest(badTimeline: true);
  stdout.writeln('ALL TESTS PASSED');
}
