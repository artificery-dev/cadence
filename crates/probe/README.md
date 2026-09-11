# cadence-probe

The native enrichment tier of Cadence's media extractor: a Rust cdylib
that reads the tags, dimensions, chapters, EXIF, and document metadata
the pure-Dart tier cannot reach — lofty for audio, matroska and re_mp4
for video containers, nom-exif for EXIF (HEIC included), lopdf and
for PDF metadata, rbook for EPUBs — and answers over four C symbols
(`cadence_abi_version`, `cadence_probe_file`, `cadence_hash_file`,
`cadence_free_string`) as a JSON envelope whose field names match the
Dart `MediaMetadata` model. `cadence_hash_file` streams a file's SHA-256
through the `sha2` crate, the identity hash the scanner would otherwise
compute in pure Dart at a fraction of the speed.
The library is strictly optional: when it is absent the Dart stack runs
without it, and `daemon/lib/probe.dart` documents
where the loader looks.

```sh
cargo build --release
```

(or `dart run tool/bin/cadence.dart native build` from the repository root).
