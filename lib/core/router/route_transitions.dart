import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

/// The app's page transition (ZoroX v4): every full-screen navigation
/// glides in with the same slide + fade instead of snapping open. The
/// report was the Settings gear ("jhatak se nahi, thoda majese khulna
/// chaiye"), and the same motion is used for detail, the player and the
/// rest, so the app feels of a piece.
///
/// 300 ms, easeInOut: quick, smooth, not slow. The incoming page slides
/// in from a little to the right (8% of the width) while fading in;
/// popping reverses it. A small slide, not the platform default's
/// full-width one: it reads as a glide rather than a shove.
///
/// Used by the pushed routes' buildPage overrides (see app_router.dart).
/// Branch switches (tabs, the Settings gear) are a different mechanism —
/// the shell swaps branch Navigators instantly, so they get the same
/// motion from the shell itself (see AppScaffold).
Page<void> smoothPage({
  required LocalKey key,
  required Widget child,
}) {
  return CustomTransitionPage<void>(
    key: key,
    child: child,
    transitionDuration: const Duration(milliseconds: 300),
    reverseTransitionDuration: const Duration(milliseconds: 300),
    transitionsBuilder: (context, animation, secondaryAnimation, child) {
      final curved = CurvedAnimation(
        parent: animation,
        curve: Curves.easeInOut,
      );
      return SlideTransition(
        position:
            Tween<Offset>(
              begin: const Offset(0.08, 0),
              end: Offset.zero,
            ).animate(curved),
        child: FadeTransition(opacity: curved, child: child),
      );
    },
  );
}
