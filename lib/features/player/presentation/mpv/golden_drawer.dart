/// The right-side sliding drawer shell for the golden player.
///
/// One shell for every drawer — Episodes, Subtitle Style, Audio, Sources —
/// so they all slide and dismiss the same way: a dark panel (#141210)
/// sliding in from the right, the video still visible on the left,
/// subtitles still readable while it is open. 280 ms, ease-out.
///
/// The dim behind the panel is NOT part of this shell: it is
/// [GoldenDrawerScrim], rendered as a sibling by the controls, so it can
/// fade in place while only the panel slides. The scrim used to live
/// inside this shell, and the slide that carried the panel carried the
/// scrim with it — a dark veil sweeping right-to-left across the video
/// every time a drawer opened.
library;

import 'package:flutter/material.dart';

import 'golden_player_theme.dart';

/// The dim behind a golden drawer: full-screen, tap-to-dismiss, fixed.
///
/// Fades only — it never slides. The controls animate it with a
/// [FadeTransition] while the panel gets the [SlideTransition]; a scrim
/// that moved with the panel read as a dark curtain sweeping the video.
///
/// It must NOT use [Positioned.fill]: it is a child of the [FadeTransition]
/// inside the scrim's [AnimatedSwitcher], not a direct child of a [Stack],
/// and a [Positioned] anywhere else throws "Incorrect use of
/// ParentDataWidget" on mount — in a release build that aborts every frame
/// and freezes the whole app the moment a drawer opens, while mpv's audio
/// keeps playing (v20+2 drawer-open freeze, 2026-11-14). The [Container]
/// sizes itself to the screen instead: the switcher hands it the screen's
/// loose constraints, and `double.infinity` fills them.
class GoldenDrawerScrim extends StatelessWidget {
  const GoldenDrawerScrim({required this.onClose, super.key});

  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onClose,
      child: Container(
        width: double.infinity,
        height: double.infinity,
        color: Colors.black.withValues(alpha: 0.45),
      ),
    );
  }
}

/// A drawer panel that slides in from the right edge.
///
/// [child] is the drawer's content (its own header included). The panel is
/// [width] wide, at most 85 % of the screen. The scrim is a sibling
/// ([GoldenDrawerScrim]), not part of this widget.
class GoldenDrawer extends StatelessWidget {
  const GoldenDrawer({
    required this.title,
    required this.onClose,
    required this.child,
    this.width = 400,
    super.key,
  });

  final String title;
  final VoidCallback onClose;
  final Widget child;

  /// The panel's width, capped at 85 % of the screen by the caller.
  final double width;

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: Alignment.centerRight,
      child: Container(
        width: width,
        height: double.infinity,
        decoration: const BoxDecoration(
          color: GoldenPlayerColors.backgroundSecondary,
          border: Border(
            left: GoldenPlayerColors.drawerBorder,
          ),
          borderRadius: BorderRadius.only(
            topLeft: Radius.circular(GoldenPlayerRadii.drawer),
            bottomLeft: Radius.circular(GoldenPlayerRadii.drawer),
          ),
        ),
        child: SafeArea(
          left: false,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              _DrawerHeader(title: title, onClose: onClose),
              const Divider(
                height: 1,
                color: GoldenPlayerColors.divider,
              ),
              Expanded(child: child),
            ],
          ),
        ),
      ),
    );
  }
}

class _DrawerHeader extends StatelessWidget {
  const _DrawerHeader({required this.title, required this.onClose});

  final String title;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 10, 8, 10),
      child: Row(
        children: <Widget>[
          Expanded(
            child: Text(
              title,
              style: const TextStyle(
                color: GoldenPlayerColors.textPrimary,
                fontSize: 17,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          GoldenIconButton(
            icon: Icons.close_rounded,
            onPressed: onClose,
            tooltip: 'Close',
            size: 36,
            iconSize: 20,
          ),
        ],
      ),
    );
  }
}
