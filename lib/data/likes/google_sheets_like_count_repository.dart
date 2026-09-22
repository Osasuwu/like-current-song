import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../../domain/entities/app_log.dart';
import '../../domain/repositories/like_count_repository.dart';
import 'counter_sheet_schema.dart';
import 'like_counter_token_error.dart';
import 'native_like_count_repository.dart';
import 'sheets_api_error.dart';

/// A Sheets call the counter could not complete, in words a user can read.
///
/// The status code travels alongside the message rather than inside it, so
/// the log line can carry it as `httpCode` instead of spelling it out; and a
/// refusal Google explained — today only "the Sheets API is off" — arrives
/// here already turned into the sentence that names the fix.
class SheetsCallException implements Exception {
  const SheetsCallException(this.message, {this.statusCode});

  final String message;
  final int? statusCode;

  @override
  String toString() => message;
}

/// Tries the shared Google Sheet first, falls back to local SharedPreferences.
///
/// The sheet is the same one the desktop half writes: a `Likes` tab with one
/// header row and the columns `user_id | track_id | count | backfilled |
/// updated_at`. Row 1 is the header, so data starts at row 2.
///
/// The tab is read once and kept as an in-memory `(user_id, track_id) -> row`
/// map plus a count cache; after that a like is one targeted `values.update`
/// per cell, or a single `values.append` for a pair the sheet has not seen.
///
/// One pair, one row — the row *is* the counter, so a second row for a pair
/// splits its count in two for good (#193). Three rules keep that from
/// happening:
///
/// * Increments run one at a time ([_queue]). Two presses in flight together
///   would otherwise both read "no row yet" and both append.
/// * The cache is never trusted to say a pair is *absent*: a pair missing
///   from it means re-read the tab, and only append if it is still missing.
///   The background half (`LikeCounter.kt`) appends rows this instance can
///   never hear about, so the only safe answer is to look. It costs one extra
///   `values.get` on the append path, which is the first like of a track and
///   nothing else; every later like still updates two cells and reads nothing.
/// * When the tab already holds two rows for one pair — sheets that went
///   wrong before those rules existed — the **topmost** one wins, which is
///   the row `LikeCounter.findRow` picks too, so both halves add to the same
///   one. The extra rows are left exactly as they are; deleting a user's data
///   is not this counter's business. Their existence is reported once per
///   load on the Logs screen so it does not diverge silently.
class GoogleSheetsLikeCountRepository implements LikeCountRepository {
  GoogleSheetsLikeCountRepository({
    required this.readSpreadsheetId,
    required this.readAccessToken,
    required this.userIdGetter,
    required this.appendLog,
    LikeCountRepository localCounts = const NativeLikeCountRepository(),
    http.Client? httpClient,
  })  : _local = localCounts,
        _httpClient = httpClient ?? http.Client();

  /// The action type every counter line on the Logs screen carries.
  static const logActionType = 'like_count';

  static const _apiBase = 'https://sheets.googleapis.com/v4/spreadsheets';

  /// The tab, from the schema all three halves share.
  static const sheetName = CounterSheetSchema.likesTab;

  /// Same budget the counter has always had: a like must not hang on a sheet.
  static const _timeout = Duration(seconds: 5);

  /// The sheet to count in, read at increment time rather than held: the
  /// counter can be set up in *Connected services* without a restart, and with
  /// nothing configured every like simply stays local.
  final Future<String> Function() readSpreadsheetId;

  /// A Google access token good right now, or null when the counter is not
  /// signed in.
  final Future<String?> Function() readAccessToken;

  /// The music-service account id the rows are keyed by, null when there is
  /// none. Asynchronous because resolving it may mean asking the service, and
  /// something has to: a getter that only ever returned an id some *other*
  /// feature had already looked up left the sheet empty for everyone whose
  /// other features were switched off.
  final Future<String?> Function() userIdGetter;

  /// Where a like that could not be counted on the sheet goes — in practice
  /// `SettingsRepository.appendLog`, which feeds the Logs screen.
  ///
  /// One method rather than the whole repository: counting a like has no
  /// business loading trigger configs or pending likes, and the narrow seam
  /// is the same shape as the three getters above. It is required because
  /// the bug this fixes was precisely a counter wired up with nowhere to
  /// report to (#170).
  final Future<void> Function(AppLog log) appendLog;

  /// Where a like goes when the sheet is off, unreachable, or simply not the
  /// place a given number lives — the artist counts and the cooldown stamps
  /// never go to the sheet at all. Injectable so a test can watch it; in the
  /// app it is always the native store the foreground service shares.
  final LikeCountRepository _local;

  final http.Client _httpClient;

  /// The spreadsheet [_rows] and [_counts] were built from; a different id
  /// means a different sheet, so the cache is dropped.
  String? _loadedFor;
  Map<String, int>? _rows;
  Map<String, int> _counts = <String, int>{};

  /// Pairs already reported as duplicated on this sheet, so the Logs screen
  /// gets one line per pair rather than one per like.
  final Set<String> _reportedDuplicates = <String>{};

  /// The tail of the chain every remote increment is linked onto: the sheet
  /// round trip is read-then-write, and two of them interleaved both see a
  /// pair with no row and both append it (#193).
  Future<void> _queue = Future<void>.value();

  /// [wasAlreadyLiked] marks a song the service already had liked before this
  /// press. On the sheet's first sight of the pair that seeds the count at 2
  /// and flags `backfilled`, exactly as the desktop half does; afterwards it
  /// makes no difference. The parameter is optional, so callers holding a
  /// plain [LikeCountRepository] need not know about it.
  @override
  Future<int> incrementTrackLikeCount(
    String trackId, {
    bool wasAlreadyLiked = false,
  }) async {
    final count = await _serialized(
      () => _remoteIncrement(trackId, wasAlreadyLiked),
    );
    if (count != null) return count;
    return _local.incrementTrackLikeCount(trackId);
  }

  /// Runs [action] after every increment already queued on this repository.
  ///
  /// A sheet increment is read-then-write, and nothing outside this process
  /// locks the tab; two presses overlapping would each read "this pair has no
  /// row" and each append one, splitting the count across two rows for good
  /// (#193). One at a time is the whole fix: presses arrive seconds apart in
  /// practice, and each one is two small calls.
  Future<T> _serialized<T>(Future<T> Function() action) {
    final result = _queue.then((_) => action());
    // The next caller waits for this one to finish, not to *succeed* — and it
    // must never inherit its error, which belongs to the caller above.
    _queue = result.then<void>((_) {}, onError: (Object _) {});
    return result;
  }

  Future<int?> _remoteIncrement(String trackId, bool wasAlreadyLiked) async {
    final String spreadsheetId;
    try {
      spreadsheetId = await readSpreadsheetId();
    } catch (error) {
      await _reportFallback(
        trackId,
        'The counter spreadsheet could not be read: $error',
      );
      return null;
    }
    // Nothing configured is not a failure — the counter is simply off, and a
    // log line per like would be noise for everyone who never wanted one.
    if (spreadsheetId.isEmpty) return null;

    final String? userId;
    try {
      userId = await userIdGetter();
    } catch (error) {
      await _reportFallback(
        trackId,
        'The account the shared count is keyed by could not be resolved: '
        '$error',
      );
      return null;
    }
    if (userId == null) {
      await _reportFallback(
        trackId,
        'The music service is not signed in, so the shared count has no row '
        'to add to. Reconnect it under Connected services.',
      );
      return null;
    }

    final String? token;
    try {
      token = await readAccessToken();
    } on LikeCounterTokenRefused catch (error) {
      // Google answered, and said why: pass its words on rather than the
      // "sign in again" advice that only fits a revoked sign-in (#200).
      await _reportFallback(trackId, error.message, httpCode: error.statusCode);
      return null;
    } catch (error) {
      await _reportFallback(
        trackId,
        "The counter's Google sign-in could not be read: $error",
      );
      return null;
    }
    if (token == null || token.isEmpty) {
      await _reportFallback(
        trackId,
        'The counter is not signed in to Google. Sign in under Connected '
        'services → Shared like counter.',
      );
      return null;
    }

    try {
      final key = _key(userId, trackId);
      final now = _nowIso();

      // A read this call made is as fresh as the sheet gets; a cache left
      // over from an earlier like is not.
      final wasCached = _rows != null && _loadedFor == spreadsheetId;
      var rows = await _ensureLoaded(spreadsheetId, token);
      var row = rows[key];

      // The cache may say a pair is on the sheet, but it can never be trusted
      // to say one is *not*: the background half appends rows straight to the
      // tab, and this instance has no way to hear about them (#193). So a
      // miss means look again before appending — one extra read on the first
      // like of a track, against a wrong row that never merges back.
      if (row == null && wasCached) {
        _invalidate();
        rows = await _ensureLoaded(spreadsheetId, token);
        row = rows[key];
      }

      if (row != null) {
        final newCount = (_counts[key] ?? 0) + 1;
        // Targeted update; `backfilled` is left as it was.
        await _update(
          spreadsheetId,
          token,
          '$sheetName!${CounterSheetSchema.countColumn}$row',
          <Object>[newCount],
        );
        // The count is on the sheet now, so the press has been counted even
        // if the timestamp write fails; a stale `updated_at` is not worth
        // reporting a local number the sheet disagrees with.
        try {
          await _update(
            spreadsheetId,
            token,
            '$sheetName!${CounterSheetSchema.updatedAtColumn}$row',
            <Object>[now],
          );
        } catch (error) {
          debugPrint('Like counter timestamp not written: $error');
        }
        _counts[key] = newCount;
        return newCount;
      }

      final newCount = wasAlreadyLiked ? 2 : 1;
      final appendedRow = await _append(spreadsheetId, token, <Object>[
        userId,
        trackId,
        newCount,
        wasAlreadyLiked ? 'TRUE' : 'FALSE',
        now,
      ]);
      // A range that could not be read is no row at all, so it is not cached:
      // the next like re-reads the tab, finds the row this call really did
      // append, and adds to it — rather than writing to `C0` and, worse,
      // believing the pair is absent all over again.
      if (appendedRow > 0) {
        rows[key] = appendedRow;
        _counts[key] = newCount;
      }
      return newCount;
    } catch (error) {
      // Anything unexpected and the cache may no longer match the sheet, so
      // throw it away and count locally for this press.
      _invalidate();
      await _reportFallback(
        trackId,
        error is SheetsCallException
            ? error.message
            : 'The sheet could not be written: $error',
        httpCode: error is SheetsCallException ? error.statusCode : null,
      );
      return null;
    }
  }

  /// The one trace a user has of a counter that is not counting.
  ///
  /// `debugPrint` used to be it, and logcat is not somewhere a release build
  /// can be read from — so a sheet that had never once been written looked
  /// exactly like one that was working, the local tally rising all the while
  /// (#170). The Logs screen is where every other step of the like reports,
  /// so the counter reports there too.
  ///
  /// The like has already succeeded and the local tally stands in by the time
  /// this runs, so nothing here may throw: a log line must never cost a like.
  Future<void> _reportFallback(
    String trackId,
    String reason, {
    int? httpCode,
  }) async {
    final message = 'Like counted on this device only. $reason';
    debugPrint(message);
    try {
      await appendLog(AppLog(
        at: DateTime.now().toUtc(),
        actionType: logActionType,
        targetId: trackId,
        result: LogResult.failure,
        httpCode: httpCode,
        message: message,
      ));
    } catch (error) {
      debugPrint('Like counter failure could not be logged: $error');
    }
  }

  /// The `(user_id, track_id) -> row` map, read from the sheet on first use.
  Future<Map<String, int>> _ensureLoaded(
    String spreadsheetId,
    String token,
  ) async {
    final cached = _rows;
    if (cached != null && _loadedFor == spreadsheetId) return cached;

    final response = await _httpClient
        .get(
          Uri.parse('$_apiBase/$spreadsheetId/values/$sheetName'),
          headers: _headers(token),
        )
        .timeout(_timeout);
    if (response.statusCode < 200 || response.statusCode > 299) {
      throw _failure('get', response);
    }

    final decoded = jsonDecode(response.body);
    final values = decoded is Map<String, dynamic> ? decoded['values'] : null;
    final rows = <String, int>{};
    final counts = <String, int>{};
    final duplicates = <String, ({int at, String trackId})>{};
    if (values is List) {
      // Row 1 is the header; data starts at row 2.
      for (var offset = 1; offset < values.length; offset++) {
        final row = values[offset];
        if (row is! List || row.length < 3) continue;
        final key = _key('${row[0]}', '${row[1]}');
        // The topmost row for a pair wins, and the ones below it are left
        // alone. `LikeCounter.findRow` returns its first match too, so both
        // halves keep adding to the same row of a sheet that already has
        // duplicates on it — which is what stops the two counts drifting
        // further apart (#193). Merging them is the user's call: this counter
        // does not get to delete rows off their sheet.
        if (rows.containsKey(key)) {
          duplicates.putIfAbsent(
            key,
            () => (at: offset + 1, trackId: '${row[1]}'),
          );
          continue;
        }
        rows[key] = offset + 1;
        counts[key] = int.tryParse('${row[2]}') ?? 0;
      }
    }
    _loadedFor = spreadsheetId;
    _rows = rows;
    _counts = counts;
    for (final entry in duplicates.entries) {
      await _reportDuplicate(
        entry.key,
        entry.value.trackId,
        rows[entry.key]!,
        entry.value.at,
      );
    }
    return rows;
  }

  /// Says, once per pair, that the sheet holds more than one row for it.
  ///
  /// A duplicate is permanent damage to a count and nothing else would ever
  /// mention it — the counter would just keep adding to one of the two rows
  /// and showing a number lower than the likes (#193). It cannot be repaired
  /// from here without deleting a row of someone's spreadsheet, so it is
  /// named instead, with the rows to merge.
  Future<void> _reportDuplicate(
    String key,
    String trackId,
    int kept,
    int extra,
  ) async {
    if (!_reportedDuplicates.add(key)) return;
    final message =
        'The shared counter sheet has more than one row for this track '
        '(rows $kept and $extra). Counting on row $kept; add the counts up '
        'and delete the spare row to see the real total.';
    debugPrint(message);
    try {
      await appendLog(AppLog(
        at: DateTime.now().toUtc(),
        actionType: logActionType,
        targetId: trackId,
        result: LogResult.info,
        message: message,
      ));
    } catch (error) {
      debugPrint('Duplicate counter row could not be logged: $error');
    }
  }

  void _invalidate() {
    _loadedFor = null;
    _rows = null;
    _counts = <String, int>{};
  }

  Future<void> _update(
    String spreadsheetId,
    String token,
    String range,
    List<Object> values,
  ) async {
    final response = await _httpClient
        .put(
          Uri.parse(
            '$_apiBase/$spreadsheetId/values/${Uri.encodeComponent(range)}'
            '?valueInputOption=RAW',
          ),
          headers: _headers(token),
          body: jsonEncode(<String, dynamic>{
            'values': <List<Object>>[values],
          }),
        )
        .timeout(_timeout);
    if (response.statusCode < 200 || response.statusCode > 299) {
      throw _failure('update', response);
    }
  }

  /// Appends one row and answers the 1-based row it landed on.
  Future<int> _append(
    String spreadsheetId,
    String token,
    List<Object> row,
  ) async {
    final response = await _httpClient
        .post(
          Uri.parse(
            '$_apiBase/$spreadsheetId/values/$sheetName:append'
            '?valueInputOption=RAW&insertDataOption=INSERT_ROWS',
          ),
          headers: _headers(token),
          body: jsonEncode(<String, dynamic>{
            'values': <List<Object>>[row],
          }),
        )
        .timeout(_timeout);
    if (response.statusCode < 200 || response.statusCode > 299) {
      throw _failure('append', response);
    }
    final decoded = jsonDecode(response.body);
    final updates = decoded is Map<String, dynamic> ? decoded['updates'] : null;
    final range = updates is Map<String, dynamic> ? updates['updatedRange'] : null;
    return rowFromA1Range(range is String ? range : '');
  }

  /// What to say when a Sheets call is refused.
  ///
  /// A project that never had the Sheets API switched on says so in the body,
  /// and a counter set up by pasting an id never calls the creator that would
  /// catch that at setup time — so without this, the only trace is a status
  /// code and a wall of JSON in the log (#165). That sentence names the fix,
  /// which is what tells a user reading the Logs screen that this failure is
  /// theirs to clear rather than a blip to ignore (#170).
  static SheetsCallException _failure(String call, http.Response response) {
    final disabled = SheetsApiDisabled.read(response.statusCode, response.body);
    if (disabled != null) {
      return SheetsCallException(
        disabled.message,
        statusCode: response.statusCode,
      );
    }
    return SheetsCallException(
      'The sheet refused a $call (${response.statusCode}): ${response.body}',
      statusCode: response.statusCode,
    );
  }

  Map<String, String> _headers(String token) => <String, String>{
        'Authorization': 'Bearer $token',
        'Content-Type': 'application/json',
      };

  /// The row number in an A1 range such as `Likes!A7:E7` → 7. Zero when the
  /// range cannot be read, which only costs the cached row until the next
  /// reload.
  @visibleForTesting
  static int rowFromA1Range(String range) {
    final digits = RegExp(r'\d+').allMatches(range).toList();
    if (digits.isEmpty) return 0;
    return int.tryParse(digits.last.group(0)!) ?? 0;
  }

  /// The desktop half writes `2026-09-20T12:34:56Z`; match it exactly.
  static String _nowIso() {
    final now = DateTime.now().toUtc();
    String two(int value) => value.toString().padLeft(2, '0');
    return '${now.year.toString().padLeft(4, '0')}-${two(now.month)}-'
        '${two(now.day)}T${two(now.hour)}:${two(now.minute)}:${two(now.second)}Z';
  }

  static String _key(String userId, String trackId) => '$userId\u0000$trackId';

  // ── Everything else stays on this device ───────────────────────────────
  //
  // Only track likes are shared. Artist counts, timestamps and the bulk
  // loads back the local UI, which has never had a remote source.

  @override
  Future<int> getTrackLikeCount(String trackId) =>
      _local.getTrackLikeCount(trackId);

  @override
  Future<int> incrementArtistLikeCount(String artistId) =>
      _local.incrementArtistLikeCount(artistId);

  @override
  Future<int> getArtistLikeCount(String artistId) =>
      _local.getArtistLikeCount(artistId);

  @override
  Future<Map<String, int>> loadAllTrackLikeCounts() =>
      _local.loadAllTrackLikeCounts();

  @override
  Future<Map<String, int>> loadAllArtistLikeCounts() =>
      _local.loadAllArtistLikeCounts();

  @override
  Future<DateTime?> getLastLikedAt(String trackId) =>
      _local.getLastLikedAt(trackId);

  @override
  Future<void> recordLikedAt(String trackId, DateTime at) =>
      _local.recordLikedAt(trackId, at);
}
