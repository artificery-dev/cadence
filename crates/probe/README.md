# cadence-probe

The native enrichment tier of Cadence's media extractor: a Rust cdylib
that reads the tags, dimensions, chapters, EXIF, and document metadata
the pure-Dart tier cannot reach — lofty for audio, matroska and re_mp4
for video containers, nom-exif for EXIF (HEIC included), lopdf and
pdf-extract for PDFs, rbook for EPUBs — and answers over three C symbols
(`cadence_abi_version`, `cadence_probe_file`, `cadence_free_string`) as a
JSON envelope whose field names match the Dart `MediaMetadata` model.
The library is strictly optional: when it is absent the Dart stack runs
without it, and `daemon/lib/probe.dart` documents
where the loader looks.

```sh
cargo build --release
```

(or `dart run tool/bin/cadence.dart native build` from the repository root).
