import 'dart:async';

/// Version 1 transports exchange JSON values; artwork has a separate byte path.
abstract interface class MediaTransport {
  Future<Map<String, Object?>> request(
    String method,
    String path, [
    Map<String, Object?>? body,
  ]);
  Future<List<int>?> artwork(int fileId);
  Stream<Map<String, Object?>> get events;
  Future<void> close();
}

class MediaError implements Exception {
  MediaError(this.code, this.message, this.status);
  final String code, message;
  final int status;
  @override
  String toString() => '$code ($status): $message';
}

/// Wire-only client: no database rows or extraction dependencies.
class CadenceClient {
  CadenceClient(this.transport);
  final MediaTransport transport;
  Future<Map<String, Object?>> call(
    String method,
    String path, [
    Map<String, Object?>? body,
  ]) => transport.request(method, path, body);
  Future<Map<String, Object?>> snapshot() => call('get', '/snapshot');
  Future<int> createLibrary(String name, String type) async =>
      (await call('post', '/libraries', {'name': name, 'type': type}))['id']
          as int;
  Future<int> addRoot(int library, String path) async =>
      (await call('post', '/libraries/$library/roots', {'path': path}))['id']
          as int;
  Future<Map<String, Object?>> scan(int library) =>
      call('post', '/libraries/$library/scan');
  Future<Map<String, Object?>> job(String id) => call('get', '/jobs/$id');
  Future<void> cancel(String id) => call('delete', '/jobs/$id');
  Future<List<Object?>> items(int library) async =>
      (await call('get', '/libraries/$library/items'))['items'] as List;
  Future<List<int>?> artwork(int file) => transport.artwork(file);
  Stream<Map<String, Object?>> get events => transport.events;
  Future<void> close() => transport.close();
}
