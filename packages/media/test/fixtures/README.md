# The fixture corpus

Tiny media files for extractor and scanner tests: 0.2 seconds of sine wave,
16×16 video, 8×8 stills — the whole tree stays under 200KB. Regenerate any
time with `dart run tool/bin/cadence.dart fixtures` (needs ffmpeg and exiftool); the script
wipes and regrows the five subdirectories below and leaves this file alone.
Tests reach every asset through the getters in `test/fixtures.dart` — never
by spelling paths.

All tags are fictional. The house band is The Fixtures; their album is
*Test Pattern*.

## audio/

| file | inside |
| --- | --- |
| `id3v23.mp3` | ID3v2.3: title/artist/album, track 1/8, year 2001, genre, TXXX `fixture_note` |
| `id3v24.mp3` | ID3v2.4: track 2/8, full release date `2001-03-12` |
| `apic.mp3` | ID3v2.3 + APIC front cover (the 32×32 `sidecar/cover.jpg`) |
| `id3v1.mp3` | ID3v1 **only** — no v2 header; title/artist/album/year/comment/track/genre |
| `tagged.flac` | Vorbis comments (date `2001-03-12`, track 3/8), `MUSICBRAINZ_{TRACKID,ALBUMID,ARTISTID}`, `REPLAYGAIN_{TRACK,ALBUM}_{GAIN,PEAK}`, embedded PICTURE |
| `vorbis.ogg` | Ogg Vorbis, TITLE/ARTIST/ALBUM/DATE |
| `tone.opus` | Opus at 48kHz, TITLE/ARTIST/ALBUM |
| `itunes.m4a` | iTunes atoms incl. `aART` (album artist) and `cpil` (compilation), track 5/8, disc 1/2 |
| `chapters.m4b` | Audiobook with two chapters ("Chapter One" 0–100ms, "Chapter Two" 100–200ms) |
| `riff.wav` | RIFF INFO list: INAM/IART/IPRD/IGNR/ICRD |
| `plain.aiff` | Untagged — technical properties only |
| `wmav2.wma` | ASF/wmav2 with title and artist |

A fifth MP3 dialect, ID3v2.2, is not on disk: ffmpeg no longer writes it,
so `Fixtures.id3v22Mp3` hand-builds one (TT2 + TP1 frames grafted onto a
copy of `id3v1.mp3`) in a directory the test provides.

## video/

| file | inside |
| --- | --- |
| `titled.mp4` | h264 16×16, container title "Test Card" |
| `titled.mkv` | Title "Two Track Mind"; h264 video + AAC audio, no subtitles |
| `vp9.webm` | VP9, untagged |
| `mjpeg.avi` | MJPEG, untagged |
| `Fixture Show S01E02.mkv` | Tagless on purpose — series/season/episode live in the filename |
| `Cool Show (2020) - S01E02.mkv` | Embedded title is scene-release noise (`Cool.Show.S01E02.1080p.WEB-DL.x264-GRP`) — for the title-displacement rule |

## image/

All 8×8. `exif.jpg` carries EXIF injected by exiftool: Make "Cadence",
Model "Fixture Cam 1000", LensModel, ISO 200, 1/250s, f/2.8, 35mm,
orientation 1, DateTimeOriginal `2020:05:17 10:30:00`, GPS 51.5007N
0.1246W at 11.5m, and an ImageDescription. The rest — `tiny.png`,
`tiny.gif`, `tiny.webp`, `tiny.bmp`, `tiny.tiff` — are bare test cards.

## doc/

| file | inside |
| --- | --- |
| `info.pdf` | Hand-written single-page PDF; Info dict with Title "Fixture Document", Author "Cadence Fixtures", CreationDate |
| `book.epub` | EPUB 2: title "The Fixture Book", creator, language, publisher, ISBN identifier, description, one XHTML chapter |
| `notes.txt` | Plain prose — title comes from the filename |

## sidecar/

| file | inside |
| --- | --- |
| `lyrics.lrc` | Three timestamped lines plus `[ar:]`/`[ti:]` headers |
| `subs.srt` | Two cues |
| `cover.jpg` | 32×32 folder art — the same image the audio fixtures embed |
