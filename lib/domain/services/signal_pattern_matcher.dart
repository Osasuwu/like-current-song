import '../entities/trigger_config.dart';

class SignalPatternMatcher {
  final List<_StampedEvent> _events = <_StampedEvent>[];
  DateTime? _lastTriggerAt;

  bool onEvent({required String event, required TriggerConfig config}) {
    final now = DateTime.now().toUtc();
    if (event != 'play' && event != 'pause') {
      return false;
    }

    // An empty pattern means "no trigger configured", not "trigger on
    // everything": without this guard the empty tail below would equal the
    // empty pattern and every play or pause would fire. The Kotlin twin,
    // MediaEventPatternDetector, guards it in the same place.
    final pattern = config.events;
    if (pattern.isEmpty) {
      return false;
    }

    _events.add(_StampedEvent(event, now));
    _events.removeWhere(
      (e) => now.difference(e.at).inMilliseconds > config.windowMs,
    );

    if (_lastTriggerAt != null &&
        now.difference(_lastTriggerAt!).inMilliseconds < config.debounceMs) {
      return false;
    }

    if (_events.length < pattern.length) {
      return false;
    }

    final tail = _events.skip(_events.length - pattern.length).map((e) => e.value);
    if (_iterableEquals(tail, pattern)) {
      _lastTriggerAt = now;
      _events.clear();
      return true;
    }

    return false;
  }

  bool _iterableEquals(Iterable<String> a, Iterable<String> b) {
    final listA = a.toList(growable: false);
    final listB = b.toList(growable: false);
    if (listA.length != listB.length) {
      return false;
    }
    for (var i = 0; i < listA.length; i++) {
      if (listA[i] != listB[i]) {
        return false;
      }
    }
    return true;
  }
}

class _StampedEvent {
  final String value;
  final DateTime at;

  _StampedEvent(this.value, this.at);
}
