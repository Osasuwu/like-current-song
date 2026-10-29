package com.osasuwu.like_spotify

/**
 * Whether Dart is listening on the event channel, for the whole process.
 * [MainActivity] sets it as Dart subscribes and clears it as Dart or the
 * activity goes. It lives here rather than on the activity so plain JUnit
 * tests can open the app (#268): the activity class cannot load off-device.
 */
object FlutterAttachment {
    @Volatile
    var attached: Boolean = false
}
