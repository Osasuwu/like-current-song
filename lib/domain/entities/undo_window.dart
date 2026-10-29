/// The last like, while it can still be undone (#268).
///
/// The native undo journal decides this; Flutter only mirrors it, so the
/// in-app Undo button offers exactly what the gesture and the notification
/// action would undo.
class UndoWindow {
  const UndoWindow({required this.pressId, required this.closesAt});

  /// The journal's id for the like the window belongs to.
  final String pressId;

  /// The last moment the like can be undone (inclusive).
  final DateTime closesAt;

  /// Reads the window as the platform channel carries it: `pressId` and
  /// `closesAt` in epoch milliseconds. Anything else, null included, means
  /// no window is open.
  static UndoWindow? fromChannel(Object? value) {
    if (value is! Map) return null;
    final pressId = value['pressId'];
    final closesAt = value['closesAt'];
    if (pressId is! String || pressId.isEmpty || closesAt is! int) return null;
    return UndoWindow(
      pressId: pressId,
      closesAt: DateTime.fromMillisecondsSinceEpoch(closesAt),
    );
  }

  @override
  bool operator ==(Object other) =>
      other is UndoWindow &&
      other.pressId == pressId &&
      other.closesAt == closesAt;

  @override
  int get hashCode => Object.hash(pressId, closesAt);

  @override
  String toString() => 'UndoWindow($pressId, closes $closesAt)';
}

/// What a tap on the in-app Undo button came to, as the native side decided.
enum UndoTapResult {
  /// The undo of that like started.
  undo,

  /// An undo of that like was already under way: nothing more happens.
  alreadyUndoing,

  /// The window had passed or a newer like took it over: nothing undone.
  tooLate,
}
