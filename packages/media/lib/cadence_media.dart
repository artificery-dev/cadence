/// Cadence's media foundation: typed libraries of items over files,
/// namespaced tags, and the SQLite schema and repositories behind them.
///
/// Pure Dart. The database connection is injected — tests bring memory,
/// the app brings a file, a future scanner brings whatever it likes.
library;

export 'package:drift/drift.dart' show DatabaseConnection;

export 'src/database/database.dart';
export 'src/extract/extract.dart';
export 'src/extract/format.dart';
export 'src/extract/sidecar.dart';
export 'src/extract/extractor.dart';
export 'src/kinds.dart';
export 'src/metadata.dart';
export 'src/repositories/collections_repository.dart';
export 'src/repositories/library_repository.dart';
export 'src/repositories/play_log.dart';
export 'src/repositories/scanner_repository.dart';
export 'src/repositories/search_repository.dart';
export 'src/repositories/settings_store.dart';
export 'src/scan/artwork_jobs.dart';
export 'src/scan/hasher.dart';
export 'src/scan/scan_jobs.dart';
export 'src/scan/scan_budget.dart';
export 'src/scan/scan_policy.dart';
export 'src/scan/scanner.dart';
export 'src/service/media_client.dart';
export 'src/service/media_service.dart';
export 'src/service/protocol.dart';
export 'src/tags.dart';
export 'src/filesystem.dart';
export 'src/watch_adapter.dart';
