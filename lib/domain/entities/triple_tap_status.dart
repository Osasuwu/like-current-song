/// What stands in the way of the triple-tap like (#158), first obstacle
/// first. The native service decides it (`TripleTapStatus` in
/// `MediaKeyCapture.kt`); Flutter only shows it.
enum TripleTapStatus {
  off('off'),
  unavailable('unavailable'),
  notGranted('not_granted'),
  needsNotificationAccess('needs_notification_access'),
  listenerOff('listener_off'),
  slotTaken('slot_taken'),
  checking('checking'),
  noBluetoothOutput('no_bluetooth_output'),
  active('active');

  const TripleTapStatus(this.wire);

  /// The name it crosses the method channel as.
  final String wire;

  /// Reads the native answer. Anything this build does not know, null
  /// included, is [unavailable]: the screen then says the mode cannot run
  /// rather than claiming it can.
  static TripleTapStatus fromWire(Object? value) {
    for (final status in values) {
      if (status.wire == value) return status;
    }
    return unavailable;
  }

  /// The status line on the trigger config screen.
  String get label => switch (this) {
        off => 'Off.',
        unavailable => 'Not available on this Android build.',
        notGranted =>
          'Needs the one-time adb grant below before it can listen.',
        needsNotificationAccess =>
          'Needs notification access, so a like knows what is playing.',
        listenerOff =>
          'Starts with the media button listener; turn the listener on.',
        slotTaken =>
          'Another app is listening to media keys; close or disable it.',
        checking => 'Checking that no other app holds the media keys…',
        noBluetoothOutput =>
          'Ready. Waiting for Bluetooth earbuds or another Bluetooth output.',
        active => 'Active: a triple tap on the earbuds likes the track.',
      };
}
