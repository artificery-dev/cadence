import '../filesystem.dart';
import 'audio_extractor.dart';
import 'document_extractor.dart';
import 'extractor.dart';
import 'image_extractor.dart';
import 'video_extractor.dart';

/// Pure Dart stack. Platform hosts explicitly append optional native tiers.
MediaExtractor defaultMediaExtractor({FileSystem? fileSystem}) =>
    MediaExtractor([
      const AudioExtractor(),
      const ImageExtractor(),
      const VideoExtractor(),
      const DocumentExtractor(),
    ], fileSystem: fileSystem);
