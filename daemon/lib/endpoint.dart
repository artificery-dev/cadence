import 'package:cadence_client/cadence_client.dart';

/// A hosted service owns its event epoch independently of client connections.
abstract interface class MediaEndpoint implements MediaTransport {
  String get epoch;
}
