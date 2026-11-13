/// The right-side sliding drawer shell for the golden player.
///
/// One shell for every drawer — Episodes, Subtitle Style, Audio, Sources —
/// so they all slide, fade and dismiss the same way: a dark panel
/// (#141210) sliding in from the right over a tap-to-dismiss scrim, the
/// video still visible on the left, subtitles still readable while it is
/// open. 280 ms, ease-out.
library;

import 'package:flutter/material.dart';

import 'golden_player_theme.dart';

/// A drawer panel that slides in from the right edge.
///
/// [child] is the drawer's content (its own header included). The panel is
/// [width] wide, at most 85 % of the screen, and sits above [scrim] — a
/// tap on the scrim calls [onClose].
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
    return Stack(
      fit: StackFit.expand,
      children: <Widget>[
        // Scrim: tap anywhere off the panel to close it.
        Positioned.fill(
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: onClose,
            child: Container(color: Colors.black.withValues(alpha: 0.45)),
          ),
        ),
        // The panel.
        Align(
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
        ),
      ],
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
