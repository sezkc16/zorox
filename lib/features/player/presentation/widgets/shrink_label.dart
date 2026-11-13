import 'package:flutter/material.dart';

/// A label that shrinks its font to fit the available width, down to a
/// readable minimum, and only then ellipsises.
///
/// Source labels are long plugin names ("4KHDHub · HubCloud Other Mommy
/// (2160p WEB-DL ...") in a narrow strip beside the quality / server /
/// size chips, so a fixed 14pt ellipsises after a few characters
/// ("4KHDHub · H..."). Shrinking first shows far more of the name; the
/// minimum keeps it readable — a name that still does not fit at the
/// minimum truncates, but with far more of it visible than before.
///
/// Used by the pre-play source list (single line) and the Sources drawer
/// (two lines). The chips keep their place in both; this only takes the
/// width the row leaves the label.
class ShrinkLabel extends StatelessWidget {
  const ShrinkLabel(
    this.text, {
    super.key,
    required this.style,
    this.maxLines = 1,
    this.minFontSize = 10.0,
  });

  final String text;
  final TextStyle style;
  final int maxLines;

  /// The smallest the font goes, in points. Below this the text would be
  /// there but not readable, which is no better than truncating it.
  final double minFontSize;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final maxWidth = constraints.maxWidth;
        final baseSize = style.fontSize ?? 14.0;
        // Unbounded width: nothing to shrink against.
        if (maxWidth.isInfinite) {
          return Text(
            text,
            maxLines: maxLines,
            overflow: TextOverflow.ellipsis,
            style: style,
          );
        }
        final direction = Directionality.of(context);
        // The largest size in [minFontSize, baseSize] at which the text
        // fits in [maxLines], stepping down half a point at a time.
        var size = baseSize;
        while (size > minFontSize) {
          final painter = TextPainter(
            text: TextSpan(
              text: text,
              style: style.copyWith(fontSize: size),
            ),
            maxLines: maxLines,
            textDirection: direction,
          )..layout(maxWidth: maxWidth);
          final fits = !painter.didExceedMaxLines;
          painter.dispose();
          if (fits) break;
          size -= 0.5;
        }
        size = size.clamp(minFontSize, baseSize);
        return Text(
          text,
          maxLines: maxLines,
          overflow: TextOverflow.ellipsis,
          style: style.copyWith(fontSize: size),
        );
      },
    );
  }
}
