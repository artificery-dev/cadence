/// The enums Cadence's wire contract is typed with.
///
/// cadenced writes every library type, media kind and scan state on the
/// wire as `<Enum>.<member>.name`, and readers parse with
/// `<Enum>.values.byName`, so the names here are the contract. Consumers
/// that switch over these enums exhaustively learn of a new member from
/// their compiler, which is the intent: cadence_media and cadence_client
/// both re-export this library, and a daemon client may depend on it alone.
library;

export 'src/kinds.dart';
export 'src/scan_state.dart';
