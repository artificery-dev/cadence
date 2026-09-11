/// Where a library's scan stands, as every status on the wire names it.
///
/// The daemon's scan queue and the coordinator both write
/// `ScanState.<x>.name` and nothing else, and [ScanStatus.fromJson] on the
/// reading side parses with `ScanState.values.byName`, so this enum is the
/// wire contract. [idle] says a scan never began; [queued] and
/// [interrupted] say one is owed; the four in the middle are a scan in
/// motion; the last three are how it ended.
enum ScanState {
  /// No scan has run since the service came up.
  idle,

  /// Submitted to a hosted queue and not yet begun — another library's
  /// scan is ahead of it, or the queue is paused. The walk starts when the
  /// queue reaches it.
  queued,

  /// Cut short by a host restart or by roots going quiet before it
  /// finished. The queue owes the library another attempt and starts one
  /// itself; this is also how the cut-short attempt reads in a job's
  /// history.
  interrupted,

  /// Walking roots and diffing against the database.
  walking,

  /// Full hashing and minimal, immediately browseable library insertion.
  discovering,

  /// Metadata enrichment of already discoverable files.
  extracting,

  /// Missing marks, sidecars, folder art — the epilogue.
  finishing,

  /// Finished whole.
  done,

  /// Threw rather than finished; the errors list holds the why.
  failed,

  /// Stopped on request. Whatever landed before the stop stays landed.
  cancelled;

  /// Whether the scan is still to come or in motion — anything but [idle]
  /// or a final answer. A follower keeps following while this holds.
  bool get running => pending || inMotion;

  /// Whether the scan has yet to begin: waiting in a queue, or waiting to
  /// be picked back up after an interruption.
  bool get pending => this == queued || this == interrupted;

  /// Whether a scanner is at work on the library right now.
  bool get inMotion =>
      this == walking ||
      this == discovering ||
      this == extracting ||
      this == finishing;
}
