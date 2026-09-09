/// The wire shapes for talking to the media service.
///
/// HTTP over isolate ports: requests carry a method, a path, and a JSON
/// body; responses carry a status and a JSON body. The service runs in its
/// own isolate today and speaks over ports — but nothing in these shapes
/// knows that, which is the point: REST and WebSocket bindings later bind
/// the same envelopes to real sockets, and a standalone server walks out
/// of this app with its protocol already worn in.
library;

enum ServiceMethod { get, post, put, delete }

class ServiceRequest {
  const ServiceRequest({
    required this.id,
    required this.method,
    required this.path,
    this.body,
  });

  factory ServiceRequest.fromMap(Map<String, Object?> map) => ServiceRequest(
    id: map['id'] as int,
    method: ServiceMethod.values.byName(map['method'] as String),
    path: map['path'] as String,
    body: map['body'] as Map<String, Object?>?,
  );

  /// Correlates a response with its request across the port.
  final int id;
  final ServiceMethod method;

  /// URL-shaped: `/libraries/3/items`. A query string rides along where a
  /// route wants one (`/search?q=…`).
  final String path;
  final Map<String, Object?>? body;

  Map<String, Object?> toMap() => {
    'id': id,
    'method': method.name,
    'path': path,
    if (body != null) 'body': body,
  };
}

class ServiceResponse {
  const ServiceResponse({
    required this.id,
    required this.status,
    this.body = const {},
  });

  factory ServiceResponse.fromMap(Map<String, Object?> map) => ServiceResponse(
    id: map['id'] as int,
    status: map['status'] as int,
    body: (map['body'] as Map<String, Object?>?) ?? const {},
  );

  final int id;

  /// HTTP's own vocabulary: 200, 201, 400, 404, 501 — the future REST
  /// binding returns these untranslated.
  final int status;
  final Map<String, Object?> body;

  bool get ok => status >= 200 && status < 300;

  Map<String, Object?> toMap() => {'id': id, 'status': status, 'body': body};
}
