import 'dart:convert';
import 'package:archive/archive.dart';
import 'context.dart';

/// Stage generation so tool/codec failures leave the existing corpus intact.
Future<void> generateFixtures(
  ToolContext context, {
  required String output,
  required String ffmpeg,
  required String exiftool,
}) async {
  final fs = context.fileSystem;
  final path = context.path;
  String join(String base, String relative) =>
      path.join(base, path.joinAll(relative.split('/')));
  final destination = fs.directory(output).absolute;
  await destination.parent.create(recursive: true);
  final staging = await destination.parent.createTemp('.cadence-fixtures-');
  final out = path.join(staging.path, 'out');
  final temp = path.join(staging.path, 'temp');
  final epub = path.join(temp, 'epub');
  final cbz = path.join(temp, 'cbz');
  void write(String name, String text) {
    final file = fs.file(name)..createSync(recursive: true);
    file.writeAsStringSync(text);
  }

  Future<void> ff(List<String> args) => context.run(ffmpeg, [
    '-hide_banner',
    '-loglevel',
    'error',
    '-y',
    ...args.take(args.length - 1),
    '-bitexact',
    args.last,
  ]);
  void archive(String directory, List<String> names, String target) {
    final data = Archive();
    for (final name in names) {
      final bytes = fs.file(join(directory, name)).readAsBytesSync();
      data.add(
        ArchiveFile(name, bytes.length, bytes)
          ..lastModTime =
              DateTime.utc(2020, 5, 17, 10, 30).millisecondsSinceEpoch ~/ 1000
          ..compression = name == 'mimetype'
              ? CompressionType.none
              : CompressionType.deflate,
      );
    }
    fs.file(target).writeAsBytesSync(ZipEncoder().encode(data));
  }

  try {
    for (final directory in ['audio', 'video', 'image', 'doc', 'sidecar']) {
      fs.directory(path.join(out, directory)).createSync(recursive: true);
    }
    await ff([
      "-f",
      "lavfi",
      "-i",
      "testsrc=size=32x32:rate=1",
      "-frames:v",
      "1",
      "-pix_fmt",
      "yuvj420p",
      join(out, "sidecar/cover.jpg"),
    ]);
    write(
      join(out, "sidecar/lyrics.lrc"),
      "[ar:The Fixtures]\n[ti:Sine of the Times]\n[00:00.00]A sine wave hums in A\n[00:05.00]Four hundred forty ways to say\n[00:10.00]The fixtures never fade away\n",
    );
    write(
      join(out, "sidecar/subs.srt"),
      "1\n00:00:00,000 --> 00:00:01,000\nHello from the fixture corpus.\n\n2\n00:00:01,000 --> 00:00:02,000\nTwo cues and out.\n",
    );
    await ff([
      "-f",
      "lavfi",
      "-i",
      "sine=frequency=440:duration=0.2",
      "-id3v2_version",
      "3",
      "-metadata",
      "title=Sine of the Times",
      "-metadata",
      "artist=The Fixtures",
      "-metadata",
      "album=Test Pattern",
      "-metadata",
      "track=1/8",
      "-metadata",
      "date=2001",
      "-metadata",
      "genre=Electronic",
      "-metadata",
      "fixture_note=hand made for tests",
      join(out, "audio/id3v23.mp3"),
    ]);
    await ff([
      "-f",
      "lavfi",
      "-i",
      "sine=frequency=440:duration=0.2",
      "-id3v2_version",
      "4",
      "-metadata",
      "title=Four Forty",
      "-metadata",
      "artist=The Fixtures",
      "-metadata",
      "album=Test Pattern",
      "-metadata",
      "track=2/8",
      "-metadata",
      "date=2001-03-12",
      "-metadata",
      "genre=Electronic",
      join(out, "audio/id3v24.mp3"),
    ]);
    await ff([
      "-f",
      "lavfi",
      "-i",
      "sine=frequency=440:duration=0.2",
      "-i",
      join(out, "sidecar/cover.jpg"),
      "-map",
      "0:a",
      "-map",
      "1:v",
      "-c:v",
      "copy",
      "-id3v2_version",
      "3",
      "-metadata",
      "title=Cover Story",
      "-metadata",
      "artist=The Fixtures",
      "-metadata",
      "album=Test Pattern",
      "-metadata",
      "track=3/8",
      "-metadata:s:v",
      "title=Album cover",
      "-metadata:s:v",
      "comment=Cover (front)",
      join(out, "audio/apic.mp3"),
    ]);
    await ff([
      "-f",
      "lavfi",
      "-i",
      "sine=frequency=440:duration=0.2",
      "-write_id3v1",
      "1",
      "-id3v2_version",
      "0",
      "-metadata",
      "TIT2=Old Handshake",
      "-metadata",
      "TPE1=The Fixtures",
      "-metadata",
      "TALB=Legacy Format",
      "-metadata",
      "TDRC=1997",
      "-metadata",
      "TRCK=4",
      "-metadata",
      "TCON=Electronic",
      "-metadata",
      "comment=v1 only",
      join(out, "audio/id3v1.mp3"),
    ]);
    await ff([
      "-f",
      "lavfi",
      "-i",
      "sine=frequency=440:duration=0.2",
      "-i",
      join(out, "sidecar/cover.jpg"),
      "-map",
      "0:a",
      "-map",
      "1:v",
      "-c:a",
      "flac",
      "-c:v",
      "copy",
      "-disposition:v:0",
      "attached_pic",
      "-metadata",
      "TITLE=Lossless Bloom",
      "-metadata",
      "ARTIST=The Fixtures",
      "-metadata",
      "ALBUM=Test Pattern",
      "-metadata",
      "DATE=2001-03-12",
      "-metadata",
      "TRACKNUMBER=3",
      "-metadata",
      "TRACKTOTAL=8",
      "-metadata",
      "GENRE=Electronic",
      "-metadata",
      "MUSICBRAINZ_TRACKID=8f6bd1e4-fbe1-4f50-aa9b-4c0f8d3c0b6e",
      "-metadata",
      "MUSICBRAINZ_ALBUMID=1b7f4a90-95a3-4b47-a44a-2b7c8d1f2a3b",
      "-metadata",
      "MUSICBRAINZ_ARTISTID=c9a1e0d2-3f4b-4d5e-8a6f-7b8c9d0e1f2a",
      "-metadata",
      "REPLAYGAIN_TRACK_GAIN=-6.20 dB",
      "-metadata",
      "REPLAYGAIN_TRACK_PEAK=0.988712",
      "-metadata",
      "REPLAYGAIN_ALBUM_GAIN=-5.80 dB",
      "-metadata",
      "REPLAYGAIN_ALBUM_PEAK=0.999969",
      join(out, "audio/tagged.flac"),
    ]);
    await ff([
      "-f",
      "lavfi",
      "-i",
      "sine=frequency=440:duration=0.2",
      "-c:a",
      "libvorbis",
      "-metadata",
      "TITLE=Ogg Verbose",
      "-metadata",
      "ARTIST=The Fixtures",
      "-metadata",
      "ALBUM=Test Pattern",
      "-metadata",
      "DATE=2001",
      join(out, "audio/vorbis.ogg"),
    ]);
    await ff([
      "-f",
      "lavfi",
      "-i",
      "sine=frequency=440:duration=0.2",
      "-ar",
      "48000",
      "-c:a",
      "libopus",
      "-metadata",
      "TITLE=Opus Pocus",
      "-metadata",
      "ARTIST=The Fixtures",
      "-metadata",
      "ALBUM=Test Pattern",
      join(out, "audio/tone.opus"),
    ]);
    await ff([
      "-f",
      "lavfi",
      "-i",
      "sine=frequency=440:duration=0.2",
      "-c:a",
      "aac",
      "-metadata",
      "title=Fruit Company",
      "-metadata",
      "artist=The Fixtures",
      "-metadata",
      "album=Test Pattern",
      "-metadata",
      "album_artist=Various Fixtures",
      "-metadata",
      "compilation=1",
      "-metadata",
      "track=5/8",
      "-metadata",
      "disc=1/2",
      "-metadata",
      "genre=Electronic",
      "-metadata",
      "date=2001",
      join(out, "audio/itunes.m4a"),
    ]);
    write(
      join(temp, "chapters.ffmeta"),
      ";FFMETADATA1\ntitle=Audiobook of Fixtures\nartist=The Fixtures\n[CHAPTER]\nTIMEBASE=1/1000\nSTART=0\nEND=100\ntitle=Chapter One\n[CHAPTER]\nTIMEBASE=1/1000\nSTART=100\nEND=200\ntitle=Chapter Two\n",
    );
    await ff([
      "-f",
      "lavfi",
      "-i",
      "sine=frequency=440:duration=0.2",
      "-i",
      join(temp, "chapters.ffmeta"),
      "-map",
      "0:a",
      "-map_metadata",
      "1",
      "-map_chapters",
      "1",
      "-c:a",
      "aac",
      join(out, "audio/chapters.m4b"),
    ]);
    await ff([
      "-f",
      "lavfi",
      "-i",
      "sine=frequency=440:duration=0.2",
      "-metadata",
      "title=Riff Raff",
      "-metadata",
      "artist=The Fixtures",
      "-metadata",
      "album=Test Pattern",
      "-metadata",
      "genre=Electronic",
      "-metadata",
      "date=2001",
      join(out, "audio/riff.wav"),
    ]);
    await ff([
      "-f",
      "lavfi",
      "-i",
      "sine=frequency=440:duration=0.2",
      "-c:a",
      "pcm_s16be",
      join(out, "audio/plain.aiff"),
    ]);
    await ff([
      "-f",
      "lavfi",
      "-i",
      "sine=frequency=440:duration=0.2",
      "-c:a",
      "wmav2",
      "-metadata",
      "title=Redmond Calling",
      "-metadata",
      "artist=The Fixtures",
      join(out, "audio/wmav2.wma"),
    ]);
    await ff([
      "-f",
      "lavfi",
      "-i",
      "testsrc=size=16x16:rate=10:duration=0.2",
      "-c:v",
      "libx264",
      "-preset",
      "ultrafast",
      "-crf",
      "30",
      "-pix_fmt",
      "yuv420p",
      "-metadata",
      "title=Test Card",
      join(out, "video/titled.mp4"),
    ]);
    await ff([
      "-f",
      "lavfi",
      "-i",
      "testsrc=size=16x16:rate=10:duration=0.2",
      "-f",
      "lavfi",
      "-i",
      "sine=frequency=440:duration=0.2",
      "-map",
      "0:v",
      "-map",
      "1:a",
      "-c:v",
      "libx264",
      "-preset",
      "ultrafast",
      "-crf",
      "30",
      "-pix_fmt",
      "yuv420p",
      "-c:a",
      "aac",
      "-metadata",
      "title=Two Track Mind",
      join(out, "video/titled.mkv"),
    ]);
    write(
      join(temp, "scenes.ffmeta"),
      ";FFMETADATA1\ntitle=Scene Study\n[CHAPTER]\nTIMEBASE=1/1000\nSTART=0\nEND=100\ntitle=Opening\n[CHAPTER]\nTIMEBASE=1/1000\nSTART=100\nEND=200\ntitle=Finale\n",
    );
    await ff([
      "-f",
      "lavfi",
      "-i",
      "testsrc=size=16x16:rate=10:duration=0.2",
      "-f",
      "lavfi",
      "-i",
      "sine=frequency=440:duration=0.2",
      "-i",
      join(temp, "scenes.ffmeta"),
      "-map",
      "0:v",
      "-map",
      "1:a",
      "-map_metadata",
      "2",
      "-map_chapters",
      "2",
      "-c:v",
      "libx264",
      "-preset",
      "ultrafast",
      "-crf",
      "30",
      "-pix_fmt",
      "yuv420p",
      "-c:a",
      "aac",
      join(out, "video/scened.mkv"),
    ]);
    await ff([
      "-f",
      "lavfi",
      "-i",
      "testsrc=size=16x16:rate=10:duration=0.2",
      "-c:v",
      "libvpx-vp9",
      "-b:v",
      "20k",
      join(out, "video/vp9.webm"),
    ]);
    await ff([
      "-f",
      "lavfi",
      "-i",
      "testsrc=size=16x16:rate=10:duration=0.2",
      "-c:v",
      "mjpeg",
      "-q:v",
      "5",
      "-pix_fmt",
      "yuvj420p",
      join(out, "video/mjpeg.avi"),
    ]);
    await ff([
      "-f",
      "lavfi",
      "-i",
      "testsrc=size=16x16:rate=10:duration=0.2",
      "-c:v",
      "libx264",
      "-preset",
      "ultrafast",
      "-crf",
      "30",
      "-pix_fmt",
      "yuv420p",
      join(out, "video/Fixture Show S01E02.mkv"),
    ]);
    await ff([
      "-f",
      "lavfi",
      "-i",
      "testsrc=size=16x16:rate=10:duration=0.2",
      "-c:v",
      "libx264",
      "-preset",
      "ultrafast",
      "-crf",
      "30",
      "-pix_fmt",
      "yuv420p",
      "-metadata",
      "title=Cool.Show.S01E02.1080p.WEB-DL.x264-GRP",
      join(out, "video/Cool Show (2020) - S01E02.mkv"),
    ]);
    await ff([
      "-f",
      "lavfi",
      "-i",
      "testsrc=size=8x8:rate=1",
      "-frames:v",
      "1",
      "-pix_fmt",
      "yuvj420p",
      join(out, "image/exif.jpg"),
    ]);
    await ff([
      "-f",
      "lavfi",
      "-i",
      "testsrc=size=8x8:rate=1",
      "-frames:v",
      "1",
      join(out, "image/tiny.png"),
    ]);
    await ff([
      "-f",
      "lavfi",
      "-i",
      "testsrc=size=8x8:rate=1",
      "-frames:v",
      "1",
      join(out, "image/tiny.gif"),
    ]);
    await ff([
      "-f",
      "lavfi",
      "-i",
      "testsrc=size=8x8:rate=1",
      "-frames:v",
      "1",
      "-c:v",
      "libwebp",
      join(out, "image/tiny.webp"),
    ]);
    await ff([
      "-f",
      "lavfi",
      "-i",
      "testsrc=size=8x8:rate=1",
      "-frames:v",
      "1",
      join(out, "image/tiny.bmp"),
    ]);
    await ff([
      "-f",
      "lavfi",
      "-i",
      "testsrc=size=8x8:rate=1",
      "-frames:v",
      "1",
      "-c:v",
      "tiff",
      join(out, "image/tiny.tiff"),
    ]);
    await context.run(exiftool, [
      "-q",
      "-overwrite_original",
      "-Make=Cadence",
      "-Model=Fixture Cam 1000",
      "-LensModel=Fixture 35mm f/2",
      "-Orientation#=1",
      "-ISO=200",
      "-ExposureTime=1/250",
      "-FNumber=2.8",
      "-FocalLength=35",
      "-DateTimeOriginal=2020:05:17 10:30:00",
      "-CreateDate=2020:05:17 10:30:00",
      "-GPSLatitude=51.5007",
      "-GPSLatitudeRef=N",
      "-GPSLongitude=0.1246",
      "-GPSLongitudeRef=W",
      "-GPSAltitude=11.5",
      "-GPSAltitudeRef=Above Sea Level",
      "-ImageDescription=An eight by eight test card",
      join(out, "image/exif.jpg"),
    ]);
    write(
      join(epub, "META-INF/container.xml"),
      "<?xml version=\"1.0\" encoding=\"utf-8\"?>\n<container version=\"1.0\" xmlns=\"urn:oasis:names:tc:opendocument:xmlns:container\">\n  <rootfiles>\n    <rootfile full-path=\"OEBPS/content.opf\" media-type=\"application/oebps-package+xml\"/>\n  </rootfiles>\n</container>\n",
    );
    write(
      join(epub, "OEBPS/content.opf"),
      "<?xml version=\"1.0\" encoding=\"utf-8\"?>\n<package xmlns=\"http://www.idpf.org/2007/opf\" unique-identifier=\"bookid\" version=\"2.0\">\n  <metadata xmlns:dc=\"http://purl.org/dc/elements/1.1/\" xmlns:opf=\"http://www.idpf.org/2007/opf\">\n    <dc:title>The Fixture Book</dc:title>\n    <dc:creator opf:role=\"aut\">Cadence Fixtures</dc:creator>\n    <dc:language>en</dc:language>\n    <dc:publisher>Fixture Press</dc:publisher>\n    <dc:identifier id=\"bookid\" opf:scheme=\"ISBN\">urn:isbn:9780306406157</dc:identifier>\n    <dc:description>A very small book that exists to be read by machines.</dc:description>\n    <dc:date>2020-05-17</dc:date>\n  </metadata>\n  <manifest>\n    <item id=\"ncx\" href=\"toc.ncx\" media-type=\"application/x-dtbncx+xml\"/>\n    <item id=\"chapter1\" href=\"chapter1.xhtml\" media-type=\"application/xhtml+xml\"/>\n  </manifest>\n  <spine toc=\"ncx\">\n    <itemref idref=\"chapter1\"/>\n  </spine>\n</package>\n",
    );
    write(
      join(epub, "OEBPS/toc.ncx"),
      "<?xml version=\"1.0\" encoding=\"utf-8\"?>\n<ncx xmlns=\"http://www.daisy.org/z3986/2005/ncx/\" version=\"2005-1\">\n  <head>\n    <meta name=\"dtb:uid\" content=\"urn:isbn:9780306406157\"/>\n  </head>\n  <docTitle><text>The Fixture Book</text></docTitle>\n  <navMap>\n    <navPoint id=\"ch1\" playOrder=\"1\">\n      <navLabel><text>Chapter One</text></navLabel>\n      <content src=\"chapter1.xhtml\"/>\n    </navPoint>\n  </navMap>\n</ncx>\n",
    );
    write(
      join(epub, "OEBPS/chapter1.xhtml"),
      "<?xml version=\"1.0\" encoding=\"utf-8\"?>\n<html xmlns=\"http://www.w3.org/1999/xhtml\">\n  <head><title>Chapter One</title></head>\n  <body>\n    <h1>Chapter One</h1>\n    <p>The fixture book opens, as all fixture books must, with a paragraph\n    that exists so a simhash has something to shingle. It is short, it is\n    plain, and it repeats itself just enough to be recognisable when a test\n    rewords it slightly.</p>\n    <p>The fixture book closes, as all fixture books must, one paragraph\n    later.</p>\n  </body>\n</html>\n",
    );
    write(
      join(cbz, "ComicInfo.xml"),
      "<?xml version=\"1.0\" encoding=\"utf-8\"?>\n<ComicInfo>\n  <Title>The Test Card Menace</Title>\n  <Series>Fixture Comics</Series>\n  <Number>12.5</Number>\n  <Writer>Ray Cathode</Writer>\n  <Publisher>Bitrate Press</Publisher>\n  <LanguageISO>en</LanguageISO>\n  <Summary>Two blank pages of pure signal.</Summary>\n  <PageCount>2</PageCount>\n  <Genre>Test Pattern</Genre>\n</ComicInfo>\n",
    );
    write(
      join(out, "doc/notes.txt"),
      "Notes on the fixture corpus.\n\nPlain text is the humblest document format: no metadata, no structure, just\nwords. An extractor meeting this file should take its title from the\nfilename and its simhash from these very sentences, which exist so a test\ncan reword them slightly and measure how little the hash moves.\n",
    );
    write(join(out, 'doc/info.pdf'), fixturePdf());
    write(join(epub, 'mimetype'), 'application/epub+zip');
    archive(epub, [
      'mimetype',
      'META-INF/container.xml',
      'OEBPS/content.opf',
      'OEBPS/toc.ncx',
      'OEBPS/chapter1.xhtml',
    ], join(out, 'doc/book.epub'));
    for (final name in ['page_001.png', 'page_002.png']) {
      fs.file(join(out, 'image/tiny.png')).copySync(join(cbz, name));
    }
    archive(cbz, [
      'page_001.png',
      'page_002.png',
      'ComicInfo.xml',
    ], join(out, 'doc/issue.cbz'));
    for (final name in expectedFixtures) {
      if (!fs.file(join(out, name)).existsSync() ||
          fs.file(join(out, name)).lengthSync() == 0) {
        throw ToolFailure('Missing or empty fixture: $name');
      }
    }
    await destination.create(recursive: true);
    for (final directory in ['audio', 'video', 'image', 'doc', 'sidecar']) {
      final target = fs.directory(path.join(destination.path, directory));
      if (target.existsSync()) target.deleteSync(recursive: true);
      fs.directory(path.join(out, directory)).renameSync(target.path);
    }
    context.write('Fixture corpus rebuilt: ${expectedFixtures.length} files');
  } finally {
    await staging.delete(recursive: true);
  }
}

String fixturePdf() {
  final buffer = StringBuffer('%PDF-1.4\n');
  final offsets = <int>[];
  void object(String contents) {
    offsets.add(utf8.encode(buffer.toString()).length);
    buffer.write(contents);
  }

  object('1 0 obj\n<< /Type /Catalog /Pages 2 0 R >>\nendobj\n');
  object('2 0 obj\n<< /Type /Pages /Kids [3 0 R] /Count 1 >>\nendobj\n');
  object(
    '3 0 obj\n<< /Type /Page /Parent 2 0 R /MediaBox [0 0 72 72] /Contents 4 0 R /Resources << >> >>\nendobj\n',
  );
  const stream = '0 0 m\n72 72 l\nS';
  object(
    '4 0 obj\n<< /Length ${stream.length} >>\nstream\n$stream\nendstream\nendobj\n',
  );
  // Preserve the original corpus producer field for compatibility.
  object(
    '5 0 obj\n<< /Title (Fixture Document) /Author (Cadence Fixtures) /Producer (make_fixtures.sh) /CreationDate (D:20200517103000Z) >>\nendobj\n',
  );
  final xref = utf8.encode(buffer.toString()).length;
  buffer.write('xref\n0 6\n0000000000 65535 f \n');
  for (final offset in offsets) {
    buffer.write('${offset.toString().padLeft(10, '0')} 00000 n \n');
  }
  buffer.write(
    'trailer\n<< /Size 6 /Root 1 0 R /Info 5 0 R >>\nstartxref\n$xref\n%%EOF\n',
  );
  return buffer.toString();
}

const expectedFixtures = [
  "audio/id3v23.mp3",
  "audio/id3v24.mp3",
  "audio/apic.mp3",
  "audio/id3v1.mp3",
  "audio/tagged.flac",
  "audio/vorbis.ogg",
  "audio/tone.opus",
  "audio/itunes.m4a",
  "audio/chapters.m4b",
  "audio/riff.wav",
  "audio/plain.aiff",
  "audio/wmav2.wma",
  "video/titled.mp4",
  "video/titled.mkv",
  "video/scened.mkv",
  "video/vp9.webm",
  "video/mjpeg.avi",
  "video/Fixture Show S01E02.mkv",
  "video/Cool Show (2020) - S01E02.mkv",
  "image/exif.jpg",
  "image/tiny.png",
  "image/tiny.gif",
  "image/tiny.webp",
  "image/tiny.bmp",
  "image/tiny.tiff",
  "doc/info.pdf",
  "doc/book.epub",
  "doc/notes.txt",
  "doc/issue.cbz",
  "sidecar/lyrics.lrc",
  "sidecar/subs.srt",
  "sidecar/cover.jpg",
];
