import 'dart:math' as math;

import 'package:flutter/scheduler.dart' show Ticker;
import 'package:tomeui/tomeui.dart';

import '../model/settings.dart';

/// The deck's display glass: near-black whatever the theme, because it's a
/// piece of hardware, not a page. Content inside speaks in the accent
/// swatch — the LCD's phosphor.
class LcdPanel extends StatelessWidget {
  const LcdPanel({required this.child, super.key});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final theme = ThemeProvider.maybeOf(context) ?? const Theme();
    final palette = theme.palette;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: palette.neutral.s1000,
        borderRadius: theme.radii.small,
        border: Border.all(color: palette.neutral.s700.withValues(alpha: 0.6)),
      ),
      child: Padding(
        padding: EdgeInsets.all(theme.space.x4),
        child: DefaultTextStyle.merge(
          style: theme.typography.code.copyWith(color: palette.accent.s400),
          child: child,
        ),
      ),
    );
  }
}

/// The big elapsed-time readout, counted in phosphor.
class LcdClock extends StatelessWidget {
  const LcdClock(this.text, {super.key});

  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = ThemeProvider.maybeOf(context) ?? const Theme();
    return Text(
      text,
      style: theme.typography.code.copyWith(
        color: theme.palette.accent.s400,
        fontSize: 44,
        fontWeight: FontWeight.w600,
        letterSpacing: 2,
        height: 1,
        fontFeatures: const [FontFeature.tabularFigures()],
      ),
    );
  }
}

/// The visualization: what dances on the glass while the music plays.
///
/// [VisualizerMode.spectrum] is columns of LED blocks with peak caps that
/// fall the way they did in 1998; [VisualizerMode.scope] is the
/// oscilloscope line; [VisualizerMode.off] rests the glass. No FFT behind
/// any of it yet — the motion is a deterministic noise field seeded by the
/// track, so the same song always moves the same way. Custom-drawn modes
/// come later; this widget is where they'll plug in.
class Visualizer extends StatefulWidget {
  const Visualizer({
    required this.mode,
    required this.active,
    this.seed = 0,
    this.height = 72,
    this.bands = 44,
    super.key,
  });

  final VisualizerMode mode;

  /// Whether the music is playing. Idle, the motion settles to the
  /// baseline and the peaks drain down.
  final bool active;

  /// Something stable per track, so each song has its own motion.
  final int seed;

  final double height;
  final int bands;

  @override
  State<Visualizer> createState() => _VisualizerState();
}

class _VisualizerState extends State<Visualizer>
    with SingleTickerProviderStateMixin {
  late final Ticker _ticker;
  final _time = ValueNotifier<double>(0);
  late List<double> _peaks;
  double _lastSeconds = 0;

  /// 0 → flat, 1 → dancing; eased toward [Visualizer.active] every frame
  /// so pause is a settle, not a cut.
  double _energy = 0;

  @override
  void initState() {
    super.initState();
    _peaks = List.filled(widget.bands, 0);
    _ticker = createTicker(_onTick)..start();
  }

  @override
  void didUpdateWidget(Visualizer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.bands != oldWidget.bands) {
      _peaks = List.filled(widget.bands, 0);
    }
  }

  void _onTick(Duration elapsed) {
    final seconds = elapsed.inMicroseconds / Duration.microsecondsPerSecond;
    final dt = (seconds - _lastSeconds).clamp(0.0, 0.1);
    _lastSeconds = seconds;

    final target = widget.active && widget.mode != VisualizerMode.off
        ? 1.0
        : 0.0;
    _energy += (target - _energy) * math.min(1, dt * 6);

    for (var i = 0; i < widget.bands; i++) {
      final level = _bandLevel(i, seconds) * _energy;
      // Peaks catch the bar instantly and fall on their own clock.
      _peaks[i] = math.max(level, _peaks[i] - dt * 0.35);
    }

    _time.value = seconds;
  }

  /// A hand-mixed noise field: a few incommensurate sines per band, shaped
  /// by an envelope that piles energy into the low end like a real mix.
  double _bandLevel(int band, double t) {
    final f = band / (widget.bands - 1);
    final envelope = 0.35 + 0.65 * math.exp(-math.pow(f - 0.18, 2) * 5.5);
    final s = widget.seed * 0.7;
    final wave =
        0.5 +
        0.28 * math.sin(t * (2.1 + band * 0.31) + s + band) +
        0.16 * math.sin(t * (5.3 + band * 0.13) + s * 1.7) +
        0.06 * math.sin(t * 13.7 + band * 2.9);
    final beat = 0.75 + 0.25 * math.sin(t * 4.4 + s);
    return (wave * beat * envelope).clamp(0.0, 1.0);
  }

  /// The scope trace at horizontal position [x] (0–1): the same voice the
  /// bars dance to, heard as a waveform.
  double _sample(double x, double t) {
    final s = widget.seed * 0.7;
    return 0.55 * math.sin(x * 9.4 + t * 5.1 + s) +
        0.30 * math.sin(x * 23.7 - t * 8.3 + s * 1.7) +
        0.15 * math.sin(x * 41.3 + t * 2.9);
  }

  @override
  void dispose() {
    _ticker.dispose();
    _time.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = ThemeProvider.maybeOf(context) ?? const Theme();
    final palette = theme.palette;
    return SizedBox(
      height: widget.height,
      width: double.infinity,
      child: CustomPaint(
        painter: _VisualizerPainter(
          time: _time,
          mode: widget.mode,
          levels: () => [
            for (var i = 0; i < widget.bands; i++)
              _bandLevel(i, _time.value) * _energy,
          ],
          peaks: () => _peaks,
          sample: _sample,
          energy: () => _energy,
          low: palette.accent.s600,
          high: palette.accent.s300,
          hot: palette.primary.s400,
          off: palette.accent.s400.withValues(alpha: 0.10),
        ),
      ),
    );
  }
}

class _VisualizerPainter extends CustomPainter {
  _VisualizerPainter({
    required this.time,
    required this.mode,
    required this.levels,
    required this.peaks,
    required this.sample,
    required this.energy,
    required this.low,
    required this.high,
    required this.hot,
    required this.off,
  }) : super(repaint: time);

  final ValueNotifier<double> time;
  final VisualizerMode mode;
  final List<double> Function() levels;
  final List<double> Function() peaks;
  final double Function(double x, double t) sample;
  final double Function() energy;

  /// Phosphor: [low] at the bottom of a column, [high] toward the top,
  /// [hot] for the topmost blocks of a tall bar and the peak caps, [off]
  /// for the unlit grid behind everything.
  final Color low;
  final Color high;
  final Color hot;
  final Color off;

  static const _blockHeight = 3.0;
  static const _blockGap = 1.0;

  @override
  void paint(Canvas canvas, Size size) {
    switch (mode) {
      case VisualizerMode.spectrum:
        _paintSpectrum(canvas, size);
      case VisualizerMode.scope:
        _paintScope(canvas, size);
      case VisualizerMode.off:
        _paintRestingLine(canvas, size);
    }
  }

  void _paintSpectrum(Canvas canvas, Size size) {
    final bars = levels();
    final caps = peaks();
    final bands = bars.length;
    if (bands == 0) return;

    final slot = size.width / bands;
    final barWidth = slot * 0.72;
    final rows = math.max(
      1,
      (size.height / (_blockHeight + _blockGap)).floor(),
    );
    final paint = Paint();

    for (var i = 0; i < bands; i++) {
      final x = i * slot + (slot - barWidth) / 2;
      final lit = (bars[i] * rows).round();
      for (var row = 0; row < rows; row++) {
        final f = row / rows;
        final y = size.height - (row + 1) * (_blockHeight + _blockGap);
        if (row < lit) {
          paint.color = f > 0.8 ? hot : Color.lerp(low, high, f / 0.8)!;
        } else {
          paint.color = off;
        }
        canvas.drawRect(Rect.fromLTWH(x, y, barWidth, _blockHeight), paint);
      }

      final capRow = (caps[i] * rows).round();
      if (capRow > 0) {
        final y = size.height - (capRow + 1) * (_blockHeight + _blockGap);
        paint.color = hot;
        canvas.drawRect(Rect.fromLTWH(x, y, barWidth, _blockHeight), paint);
      }
    }
  }

  void _paintScope(Canvas canvas, Size size) {
    final t = time.value;
    final amp = energy();
    final mid = size.height / 2;
    final sweep = size.height * 0.42;

    final path = Path()..moveTo(0, mid - sample(0, t) * sweep * amp);
    const samples = 160;
    for (var i = 1; i <= samples; i++) {
      final x = i / samples;
      path.lineTo(x * size.width, mid - sample(x, t) * sweep * amp);
    }

    // The trace, twice: a wide translucent pass for the glow, a thin one
    // for the beam.
    canvas.drawPath(
      path,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 5
        ..strokeJoin = StrokeJoin.round
        ..color = low.withValues(alpha: 0.30),
    );
    canvas.drawPath(
      path,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.6
        ..strokeJoin = StrokeJoin.round
        ..color = high,
    );
  }

  /// Off: the beam idles as one dim line across the glass.
  void _paintRestingLine(Canvas canvas, Size size) {
    final mid = size.height / 2;
    canvas.drawLine(
      Offset(0, mid),
      Offset(size.width, mid),
      Paint()
        ..strokeWidth = 1
        ..color = off,
    );
  }

  @override
  bool shouldRepaint(_VisualizerPainter oldDelegate) =>
      mode != oldDelegate.mode ||
      low != oldDelegate.low ||
      high != oldDelegate.high ||
      hot != oldDelegate.hot ||
      off != oldDelegate.off;
}
