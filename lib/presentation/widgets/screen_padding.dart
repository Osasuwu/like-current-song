import 'package:flutter/material.dart';

/// Padding for a scrolling screen body that keeps its last row clear of the
/// Android navigation bar.
///
/// Flutter draws edge-to-edge on Android 15+, so a `Scaffold` body runs all
/// the way under the gesture pill / button bar and whatever sits at the bottom
/// of it ends up half hidden. A fixed body can be wrapped in a [SafeArea]; a
/// scroll view should not be, because that shortens the viewport instead of
/// letting the content scroll past the bar. It adds the inset to its own
/// padding instead, which is what this returns.
///
/// [MediaQuery.paddingOf] rather than `viewPaddingOf`: it drops to zero once
/// the keyboard covers the navigation bar, and by then the `Scaffold` has
/// already shortened the body by the keyboard inset — adding the bar's height
/// on top of that would leave a gap above the keyboard.
EdgeInsets scrollBodyPadding(
  BuildContext context, {
  EdgeInsets base = const EdgeInsets.all(16),
}) =>
    base + EdgeInsets.only(bottom: MediaQuery.paddingOf(context).bottom);
