import 'package:tomeui/tomeui.dart';

/// The proportions of a standing book: two wide to three tall. Spines on
/// the reading shelves — books, comics — wear it; everything else stays
/// square.
const double bookAspect = 2 / 3;

/// The proportions of a one-sheet: 27 by 40, the poster every cinema
/// lobby hangs. The films shelf wears it so a poster shows whole instead
/// of cropped to a sleeve.
const double posterAspect = 27 / 40;

/// The one grid every shelf agrees on: cells up to 200 wide — a tile at
/// the cell's width and [tileAspect] proportions, then two caption lines
/// — with the theme's x5 gaps both ways. Albums, artists, series, films,
/// or photographs, the crate keeps a single rhythm; the printed shelves
/// pass [bookAspect] and only stand taller.
SliverGridDelegateWithMaxCrossAxisExtent shelfGridDelegate(
  Theme theme, {
  double tileAspect = 1,
}) => SliverGridDelegateWithMaxCrossAxisExtent(
  maxCrossAxisExtent: 200,
  // The caption block (gap, title, byline) measures ~59 under the
  // widest cell; 62 keeps a breath of headroom so tiles never clip
  // mid-resize, when cells pass through their widest.
  mainAxisExtent: 200 / tileAspect + 62,
  crossAxisSpacing: theme.space.x5,
  mainAxisSpacing: theme.space.x5,
);
