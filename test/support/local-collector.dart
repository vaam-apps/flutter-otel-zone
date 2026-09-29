import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// One request a [LocalCollector] received.
final class CollectedRequest {
  /// Records a request.
  const CollectedRequest(this.headers, this.body);

  /// The request's headers, names lower-cased.
  final Map<String, String> headers;

  /// The body, decoded byte-for-byte as Latin-1.
  ///
  /// OTLP/HTTP bodies are protobuf, which is not text, but every string in
  /// them is stored verbatim, so `contains` finds a body or an event name
  /// without a decoder.
  final String body;
}

/// A collector on the loopback interface that records what reaches it.
///
/// Real sockets rather than a fake exporter, because the point of the tests
/// that use it is what actually goes on the wire — a header a fake never sees
/// is a header a test cannot vouch for. Bound to 127.0.0.1 only, so nothing
/// leaves the machine.
final class LocalCollector {
  LocalCollector._(this._server, {required this.hang}) {
    _server.listen(_handle);
  }

  /// Starts a collector on a free port.
  ///
  /// With [hang], it accepts a request and never answers, which is a
  /// collector on a connection that has stalled.
  static Future<LocalCollector> start({bool hang = false}) async {
    final HttpServer server = await HttpServer.bind(
      InternetAddress.loopbackIPv4,
      0,
    );
    return LocalCollector._(server, hang: hang);
  }

  final HttpServer _server;

  /// Whether requests are left unanswered.
  final bool hang;

  /// Every request received, oldest first.
  final List<CollectedRequest> requests = <CollectedRequest>[];

  /// Where an exporter should be pointed.
  String get endpoint => 'http://127.0.0.1:${_server.port}';

  /// Completes once [count] requests have arrived.
  Future<void> waitForRequests(int count) async {
    for (int i = 0; i < 400 && requests.length < count; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    if (requests.length < count) {
      throw StateError('expected $count requests, saw ${requests.length}');
    }
  }

  /// Stops listening and drops any connection still open.
  Future<void> close() => _server.close(force: true);

  Future<void> _handle(HttpRequest request) async {
    final Map<String, String> headers = <String, String>{};
    request.headers.forEach(
      (String name, List<String> values) => headers[name] = values.join(','),
    );
    final List<int> body = <int>[
      for (final List<int> chunk in await request.toList()) ...chunk,
    ];
    requests.add(CollectedRequest(headers, latin1.decode(body)));
    if (hang) return;
    request.response.statusCode = HttpStatus.ok;
    await request.response.close();
  }
}
