import 'dart:async';
import 'dart:math';

import 'package:cadence_media/cadence_media.dart';
import 'package:tomeui/tomeui.dart';

import 'audio_engine.dart';

enum LoopMode { off, all, one }

/// An [AudioItem], wearing the general coat — the queue panel, the
/// inspector, and the tap grammar all speak [MediaItem].
MediaItem mediaItemOf(AudioItem track) => MediaItem(
  id: track.id,
  fileId: track.fileId,
  path: track.path,
  metadata: track.metadata,
  tags: track.tags,
);

/// The mock playback engine — and the deck's one truth. An audio queue
/// with a clock and every transport control, plus [open]: any kind of
/// item may take the deck (a film runs the clock, a book or comic turns
/// pages, an image just stands), and [deckKind] tells the bar which
/// controls to wear. Callers hand items over and read the deck back —
/// nobody outside needs to know what "playing" means for the kind. No
/// real engines yet — the ticker stands in for the DAC; real backends
/// take these seats later. Plays and progress land in the [PlayLog]
/// when one is given.
class PlaybackController extends ChangeNotifier {
  PlaybackController(
    List<AudioItem> library, {
    MediaClient? journal,
    AudioEngine? engine,
    double initialVolume = 0.72,
    void Function(double value)? onVolumeChanged,
  }) // Start lived-in: a track on the deck, paused mid-song.
    : _library = library,
      queue = List.of(library),
      _journal = journal, // ignore: prefer_initializing_formals
      _engine = engine, // ignore: prefer_initializing_formals
      _onVolumeChanged = onVolumeChanged, // ignore: prefer_initializing_formals
      _volume = initialVolume.clamp(0.0, 1.0),
      _current = library.isEmpty ? null : library[3 % library.length],
      _positionBase = const Duration(seconds: 67) {
    // The engine speaks; the deck listens. Position lands whenever the
    // engine holds the deck's timed face — the audio queue, or an
    // opened film.
    if (engine != null) {
      _engineSubs.add(
        engine.positions.listen((at) {
          if (!_engineHoldsDeck) return;
          _positionBase = at;
          _sinceTick.reset();
          notifyListeners();
        }),
      );
      _engineSubs.add(
        engine.completed.listen((_) {
          if (!_engineHoldsDeck) return;
          if (_opened != null) {
            // A film ends where it ends; there is no queue behind it.
            _position = currentDuration;
            _playing = false;
            _checkpoint();
            notifyListeners();
          } else if (_repeat == LoopMode.one) {
            _position = Duration.zero;
            _engineDo((e) => e.load(_current!.path));
            notifyListeners();
          } else {
            _advance(wrap: _repeat == LoopMode.all);
          }
        }),
      );
      // The deck's level is the truth; a fresh engine starts loud.
      _engineDo((e) => e.setVolume(audibleVolume));
    }
  }

  /// Whether the engine is the metronome for what the deck holds now:
  /// the audio queue's current track, or an opened film — either way,
  /// only once the engine has actually loaded that very file.
  bool get _engineHoldsDeck {
    if (_engine == null) return false;
    if (_opened case final held?) {
      return held.metadata is VideoMetadata && _loadedId == held.id;
    }
    return _current != null && _loadedId == _current!.id;
  }

  /// The whole shelf — what the queue returns to when a collection ends
  /// its reign.
  final List<AudioItem> _library;
  final List<AudioItem> queue;
  final MediaClient? _journal;

  /// The thing that actually makes sound — null runs the mock clock,
  /// which the tests still keep time by.
  final AudioEngine? _engine;
  final List<StreamSubscription<void>> _engineSubs = [];

  /// The item the engine has loaded, so verbs know whether to seek the
  /// standing file or fetch a new one.
  int? _loadedId;
  final _random = Random();

  AudioItem? _current;
  bool _playing = false;
  Duration _positionBase;

  /// A non-audio item holding the deck — a film, a book, an issue, an
  /// image. Null means the audio queue reigns. Set by [open], cleared
  /// the moment audio plays again.
  MediaItem? _opened;

  /// The open document's page, zero-based.
  int _page = 0;

  /// Real time since the needle was last placed. The ticker is the
  /// metronome, but the eye wants more than four frames a second — this
  /// clock carries [position] smoothly between its beats.
  final Stopwatch _sinceTick = Stopwatch();

  Duration get _position => _positionBase;
  set _position(Duration value) {
    _positionBase = value;
    _sinceTick.reset();
  }

  double _volume;

  /// Where a settled level gets written down — hooked to the settings
  /// table by whoever built the deck. Debounced: a drag is one write.
  final void Function(double value)? _onVolumeChanged;
  Timer? _volumeSave;
  bool _muted = false;
  bool _shuffle = false;
  LoopMode _repeat = LoopMode.off;
  Timer? _ticker;

  AudioItem? get current => _current;
  bool get playing => _playing;

  /// What holds the deck when it isn't the audio queue.
  MediaItem? get opened => _opened;

  /// The run the deck is walking, whatever plays: the audio queue while
  /// it reigns, or the opened item standing alone. The queue panel
  /// draws this — starting ANY media updates it, not just music.
  List<MediaItem> get run => _opened != null
      ? [_opened!]
      : [for (final track in queue) mediaItemOf(track)];

  /// Whether the picture has the whole window. Deck state like shuffle:
  /// the shell obeys it, the bar's watching face toggles it, and it
  /// falls away when the film leaves the deck.
  bool get fullscreen => _fullscreen;
  bool _fullscreen = false;

  void toggleFullscreen() {
    if (_opened?.metadata is! VideoMetadata) return;
    _fullscreen = !_fullscreen;
    notifyListeners();
  }

  /// The engine's live picture, when it has eyes — the video surfaces
  /// ask here so nobody else meets the engine.
  Widget? videoSurface(BuildContext context) =>
      _engine?.videoSurface(context);

  /// Which face the deck wears — the opened item's kind, or audio while
  /// the queue reigns. The bar reads this to choose its controls.
  MediaKind get deckKind => _opened?.metadata.kind ?? MediaKind.audio;

  /// Whether the deck's face has a running clock: the audio queue, or an
  /// opened film. Pages and pictures hold still.
  bool get timed =>
      _opened == null ? _current != null : _opened!.metadata is VideoMetadata;

  /// The open document's page, zero-based, and how many it has.
  int get page => _page;
  int get pageCount => switch (_opened?.metadata) {
    DocumentMetadata(:final pageCount) => pageCount ?? 0,
    _ => 0,
  };

  /// The deck's marks along the clock — an audiobook's chapters, a
  /// film's scene stops — for whichever timed holder stands. Empty when
  /// the holder keeps none, and the bar hides the hop buttons with it.
  List<ChapterMark> get stops => switch (_opened?.metadata) {
    VideoMetadata(:final chapters) => chapters,
    null => _current?.metadata.chapters ?? const [],
    _ => const [],
  };

  /// Seek to the first stop past the needle. Past the last, nothing.
  void nextStop() {
    if (!timed) return;
    for (final mark in stops) {
      if (mark.start > position + const Duration(seconds: 1)) {
        _seekDeck(mark.start);
        return;
      }
    }
  }

  /// The classic rule, spoken in stops: deep into one, back to its
  /// top; near its top, back to the one before.
  void previousStop() {
    if (!timed || stops.isEmpty) return;
    final at = position;
    ChapterMark? standing;
    ChapterMark? before;
    for (final mark in stops) {
      if (mark.start > at) break;
      before = standing;
      standing = mark;
    }
    _seekDeck(switch (standing) {
      null => Duration.zero,
      final mark when at - mark.start > const Duration(seconds: 3) =>
        mark.start,
      _ => before?.start ?? Duration.zero,
    });
  }

  void _seekDeck(Duration to) {
    _position = to;
    if (_engineHoldsDeck) _engineDo((e) => e.seek(to));
    notifyListeners();
  }

  /// Where the needle stands right now — the last tick's place plus
  /// whatever real time has passed since, so a seek bar reading this
  /// every frame glides instead of stepping.
  Duration get position {
    if (!_playing) return _position;
    final live = _position + _sinceTick.elapsed;
    return live > currentDuration ? currentDuration : live;
  }

  double get volume => _volume;
  bool get muted => _muted;
  bool get shuffle => _shuffle;
  LoopMode get repeat => _repeat;

  /// What actually reaches the speakers.
  double get audibleVolume => _muted ? 0 : _volume;

  /// The deck's clock face: the opened film's runtime, or the current
  /// track's. Zero for the kinds that hold still.
  Duration get currentDuration => switch (_opened?.metadata) {
    VideoMetadata(:final duration) => duration ?? Duration.zero,
    null => _current?.metadata.duration ?? Duration.zero,
    _ => Duration.zero,
  };

  /// How far along the deck stands, 0–1, whatever it holds: the clock
  /// for timed kinds, the page for documents. Seek bars read this.
  double get progress {
    if (_opened?.metadata is DocumentMetadata) {
      if (pageCount < 2) return 0;
      return (_page / (pageCount - 1)).clamp(0.0, 1.0);
    }
    final duration = currentDuration;
    if (duration == Duration.zero) return 0;
    return (position.inMilliseconds / duration.inMilliseconds).clamp(0.0, 1.0);
  }

  int get currentIndex => _current == null ? -1 : queue.indexOf(_current!);

  void play(AudioItem item) {
    // Playing from the library takes the deck back from any collection.
    if (!queue.any((q) => q.id == item.id)) {
      queue
        ..clear()
        ..addAll(_library);
    }
    _playItem(item);
  }

  /// Puts a collection on the deck and drops the needle — on [startAt],
  /// or its first item. It plays in its laid order until told otherwise;
  /// shuffle and repeat stay on the table.
  void playCollection(List<AudioItem> items, {AudioItem? startAt}) {
    if (items.isEmpty) return;
    queue
      ..clear()
      ..addAll(items);
    _playItem(startAt ?? items.first);
  }

  /// Takes any item onto the deck, whatever its kind: audio joins the
  /// queue and plays; a film starts its clock; a book or comic opens at
  /// its first page; an image simply stands. The bar follows [deckKind];
  /// the caller doesn't need to know which of these happened.
  void open(MediaItem item) {
    if (item.metadata case final AudioMetadata metadata) {
      play(
        AudioItem(
          id: item.id,
          fileId: item.fileId,
          path: item.path,
          metadata: metadata,
          tags: item.tags,
        ),
      );
      return;
    }
    _checkpoint();
    _opened = item;
    _page = 0;
    _position = Duration.zero;
    // Only a film runs; the reading and looking kinds hold still —
    // and whatever the engine was sounding steps aside either way.
    if (item.metadata is! VideoMetadata) _fullscreen = false;
    _playing = item.metadata is VideoMetadata;
    if (_playing && _engine != null) {
      _loadedId = item.id;
      _engineDo((e) => e.load(item.path));
    } else {
      _engineDo((e) => e.pause());
    }
    _playing ? _startTicker() : _stopTicker();
    _logPlay(item.id);
    notifyListeners();
  }

  void _playItem(AudioItem item) {
    _checkpoint();
    _opened = null;
    _fullscreen = false;
    _current = item;
    _position = Duration.zero;
    _playing = true;
    _startTicker();
    _engineSyncCurrent(play: true);
    _logPlay(item.id);
    notifyListeners();
  }

  void toggle() {
    if (_opened != null) {
      // Only a film has a clock to hold or release; the still kinds
      // have nothing to toggle.
      if (_opened!.metadata is! VideoMetadata) return;
    } else if (_current == null) {
      if (queue.isEmpty) return;
      play(queue.first);
      return;
    }
    // Pausing pins the needle where the ear last heard it, not at the
    // last tick.
    if (_playing) _position = position;
    _playing = !_playing;
    _playing ? _startTicker() : _stopTicker();
    if (_engineHoldsDeck) {
      // Resuming what the engine still holds is just "play".
      _engineDo((e) => _playing ? e.play() : e.pause());
    } else if (_opened == null) {
      // A fresh boot's lived-in track loads from where it sat.
      if (_playing) _engineSyncCurrent(play: true);
    }
    if (!_playing) _checkpoint();
    notifyListeners();
  }

  void stop() {
    _checkpoint();
    _playing = false;
    _position = Duration.zero;
    _stopTicker();
    _loadedId = null;
    _engineDo((e) => e.stop());
    notifyListeners();
  }

  /// The deck moves house: a new shelf becomes the library and the queue,
  /// the needle lifts, and whatever was playing is let go — without a
  /// checkpoint, because the old shelf's items may already be gone.
  void adopt(List<AudioItem> library) {
    _playing = false;
    _position = Duration.zero;
    _opened = null;
    _fullscreen = false;
    _stopTicker();
    _loadedId = null;
    _engineDo((e) => e.stop());
    _library
      ..clear()
      ..addAll(library);
    queue
      ..clear()
      ..addAll(library);
    _current = library.isEmpty ? null : library.first;
    notifyListeners();
  }

  void next() {
    if (_opened != null) return;
    _advance(wrap: true);
  }

  /// The classic rule: early in a track, go to the previous one; deeper in,
  /// go back to the top of this one.
  void previous() {
    if (_opened != null) return;
    if (_position > const Duration(seconds: 3)) {
      _position = Duration.zero;
      if (_loadedId == _current?.id) _engineDo((e) => e.seek(Duration.zero));
      notifyListeners();
      return;
    }
    final index = currentIndex;
    if (index <= 0) {
      _position = Duration.zero;
      if (_loadedId == _current?.id) _engineDo((e) => e.seek(Duration.zero));
      notifyListeners();
      return;
    }
    _checkpoint();
    _current = queue[_shuffle ? _randomOtherIndex() : index - 1];
    _position = Duration.zero;
    _engineSyncCurrent(play: _playing);
    notifyListeners();
  }

  /// Nudge the clock — the 10-second hops. Clamped to whatever runs.
  void skipBy(Duration delta) {
    if (!timed) return;
    var next = position + delta;
    if (next < Duration.zero) next = Duration.zero;
    if (next > currentDuration) next = currentDuration;
    _position = next;
    if (_engineHoldsDeck) _engineDo((e) => e.seek(next));
    notifyListeners();
  }

  /// The seek bar's verb, kind-blind: a fraction of the clock for the
  /// timed kinds, a fraction of the pages for a document.
  void seekTo(double fraction) {
    if (_opened?.metadata is DocumentMetadata) {
      if (pageCount == 0) return;
      _page = ((pageCount - 1) * fraction.clamp(0.0, 1.0)).round();
      notifyListeners();
      return;
    }
    if (!timed) return;
    _position = currentDuration * fraction.clamp(0.0, 1.0);
    if (_engineHoldsDeck) {
      final at = _position;
      _engineDo((e) => e.seek(at));
    }
    notifyListeners();
  }

  /// Turn the open document's pages. Clamped to the covers.
  void turnPage(int delta) {
    if (pageCount == 0) return;
    final next = (_page + delta).clamp(0, pageCount - 1);
    if (next == _page) return;
    _page = next;
    notifyListeners();
  }

  set volume(double value) {
    _volume = value.clamp(0.0, 1.0);
    // Reaching for the level is already an answer about the mute.
    if (_muted && _volume > 0) _muted = false;
    _engineDo((e) => e.setVolume(audibleVolume));
    if (_onVolumeChanged != null) {
      _volumeSave?.cancel();
      _volumeSave = Timer(
        const Duration(milliseconds: 400),
        () => _onVolumeChanged(_volume),
      );
    }
    notifyListeners();
  }

  void toggleMute() {
    _muted = !_muted;
    _engineDo((e) => e.setVolume(audibleVolume));
    notifyListeners();
  }

  /// The whole library, dealt into the queue in a fresh order, playing
  /// from the top with shuffle lit.
  void shuffleAll() => playShuffled(_library);

  /// [items] dealt into the queue in a fresh order, playing from the top
  /// with shuffle lit — an album or an artist's shelf, shuffled.
  void playShuffled(List<AudioItem> items) {
    if (items.isEmpty) return;
    queue
      ..clear()
      ..addAll(List.of(items)..shuffle(_random));
    _shuffle = true;
    _playItem(queue.first);
  }

  /// Appends [items] to the queue, once each — what "add to queue"
  /// means. The current track and mode stay put.
  void enqueue(List<AudioItem> items) {
    var grew = false;
    for (final item in items) {
      if (queue.any((q) => q.id == item.id)) continue;
      queue.add(item);
      grew = true;
    }
    if (grew) notifyListeners();
  }

  void toggleShuffle() {
    _shuffle = !_shuffle;
    notifyListeners();
  }

  void cycleRepeat() {
    _repeat = LoopMode.values[(_repeat.index + 1) % LoopMode.values.length];
    notifyListeners();
  }

  /// Move a queued track. [newIndex] is the landing slot, already
  /// adjusted for the removal (the onReorderItem convention).
  void reorder(int oldIndex, int newIndex) {
    final item = queue.removeAt(oldIndex);
    queue.insert(newIndex, item);
    notifyListeners();
  }

  /// A play, noted in passing — best effort for the same reason as the
  /// checkpoint below.
  void _logPlay(int id) =>
      unawaited(_journal?.recordPlay(id).catchError((Object _) {}));

  /// Where we are, written down — at every pause and hand-over, so a
  /// book or a film could resume from it. Only the timed holders have a
  /// clock worth writing; pages will get their own progress shape later.
  /// Best effort: an item deleted out from under the needle has nowhere
  /// to write, and journaling must never take the deck down.
  void _checkpoint() {
    final id = switch (_opened) {
      final held? => held.metadata is VideoMetadata ? held.id : null,
      null => _current?.id,
    };
    if (id == null) return;
    unawaited(_journal?.setProgress(id, _position).catchError((Object _) {}));
  }

  /// Fire-and-forget on the engine — playback commands must never take
  /// the deck down, and the UI never waits on the backend.
  void _engineDo(Future<void> Function(AudioEngine engine) verb) {
    final engine = _engine;
    if (engine == null) return;
    unawaited(verb(engine).catchError((Object _) {}));
  }

  /// Points the engine at the current track: a load when it holds
  /// another file, a seek-and-verb when it already holds this one.
  void _engineSyncCurrent({required bool play}) {
    final item = _current;
    if (item == null || _engine == null) return;
    final at = _position;
    if (_loadedId != item.id) {
      _loadedId = item.id;
      _engineDo((e) => e.load(item.path, start: at, play: play));
    } else {
      _engineDo((e) async {
        await e.seek(at);
        play ? await e.play() : await e.pause();
      });
    }
  }

  void _startTicker() {
    _sinceTick.start();
    // With a real engine, the engine is the metronome for both timed
    // faces — the audio queue and the opened film. The timer only
    // serves the engineless mock.
    if (_engine != null &&
        (_opened == null || _opened!.metadata is VideoMetadata)) {
      _ticker?.cancel();
      _ticker = null;
      return;
    }
    _ticker ??= Timer.periodic(const Duration(milliseconds: 250), _onTick);
  }

  void _stopTicker() {
    _sinceTick
      ..stop()
      ..reset();
    _ticker?.cancel();
    _ticker = null;
  }

  void _onTick(Timer timer) {
    if (!_playing || !timed) return;
    // The engine keeps the timed clocks itself; a stale timer must not
    // second-guess it.
    if (_engine != null &&
        (_opened == null || _opened!.metadata is VideoMetadata)) {
      return;
    }
    _position += const Duration(milliseconds: 250);
    if (_position >= currentDuration) {
      if (_opened != null) {
        // A film ends where it ends; there is no queue behind it.
        _position = currentDuration;
        _playing = false;
        _stopTicker();
        _checkpoint();
      } else if (_repeat == LoopMode.one) {
        _position = Duration.zero;
      } else {
        _advance(wrap: _repeat == LoopMode.all);
      }
    }
    notifyListeners();
  }

  void _advance({required bool wrap}) {
    final index = currentIndex;
    if (index < 0 || queue.isEmpty) return;
    _checkpoint();
    if (_shuffle) {
      _current = queue[_randomOtherIndex()];
      _position = Duration.zero;
      _engineSyncCurrent(play: _playing);
      _logPlay(_current!.id);
    } else if (index + 1 < queue.length) {
      _current = queue[index + 1];
      _position = Duration.zero;
      _engineSyncCurrent(play: _playing);
      _logPlay(_current!.id);
    } else if (wrap) {
      _current = queue.first;
      _position = Duration.zero;
      _engineSyncCurrent(play: _playing);
      _logPlay(_current!.id);
    } else {
      _playing = false;
      _position = Duration.zero;
      _stopTicker();
      _engineDo((e) => e.pause());
    }
    notifyListeners();
  }

  int _randomOtherIndex() {
    if (queue.length < 2) return 0;
    final index = currentIndex;
    var pick = _random.nextInt(queue.length - 1);
    if (pick >= index) pick++;
    return pick;
  }

  @override
  void dispose() {
    _stopTicker();
    // A level still waiting on the debounce is written on the way out.
    if (_volumeSave case final pending? when pending.isActive) {
      pending.cancel();
      _onVolumeChanged?.call(_volume);
    }
    for (final sub in _engineSubs) {
      unawaited(sub.cancel());
    }
    _engineDo((e) => e.dispose());
    super.dispose();
  }
}
