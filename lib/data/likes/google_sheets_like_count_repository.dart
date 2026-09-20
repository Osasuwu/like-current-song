import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../../domain/repositories/like_count_repository.dart';
import 'shared_prefs_like_count_repository.dart';

/// Tries the shared Google Sheet first, falls back to local SharedPreferences.
///
/// The sheet is the same one the desktop half writes: a `Likes` tab with one
/// header row and the columns `user_id | track_id | count | backfilled |
/// updated_at`. Row 1 is the header, so data starts at row 2.
///
/// The tab is read once and kept as an in-memory `(user_id, track_id) -> row`
/// map plus a count cache; after that a like is one targeted `values.update`
/// per cell, or a single `values.append` for a pair the sheet has not seen.
class GoogleSheetsLikeCountRepository implements LikeCountRepository {
  GoogleSheetsLikeCountRepository({
    required this.readSpreadsheetId,
    required this.readAccessToken,
    required this.userIdGetter,
    http.Client? httpClient,
  }) : _httpClient = httpClient ?? http.Client();

  static const _apiBase = 'https://sheets.googleapis.com/v4/spreadsheets';

  /// The tab, matching the desktop half's default.
  static const sheetName = 'Likes';

  /// Same budget the counter has always had: a like must not hang on a sheet.
  static const _timeout = Duration(seconds: 5);

  /// The sheet to count in, read at increment time rather than held: the
  /// counter can be set up in *Connected services* without a restart, and with
  /// nothing configured every like simply stays local.
  final Future<String> Function() readSpreadsheetId;

  /// A Google access token good right now, or null when the counter is not
  /// signed in.
  final Future<String?> Function() readAccessToken;

  final String? Function() userIdGetter;

  final SharedPrefsLikeCountRepository _local = SharedPrefsLikeCountRepository();
  final http.Client _httpClient;

  /// The spreadsheet [_rows] and [_counts] were built from; a different id
  /// means a different sheet, so the cache is dropped.
  String? _loadedFor;
  Map<String, int>? _rows;
  Map<String, int> _counts = <String, int>{};

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
    final count = await _remoteIncrement(trackId, wasAlreadyLiked);
    if (count != null) return count;
    return _local.incrementTrackLikeCount(trackId);
  }

  Future<int?> _remoteIncrement(String trackId, bool wasAlreadyLiked) async {
    final String spreadsheetId;
    try {
      spreadsheetId = await readSpreadsheetId();
    } catch (error) {
      debugPrint('Like counter sheet unreadable, counting locally: $error');
      return null;
    }
    if (spreadsheetId.isEmpty) return null;

    final userId = userIdGetter();
    if (userId == null) return null;

    final String? token;
    try {
      token = await readAccessToken();
    } catch (error) {
      debugPrint('Like counter token unavailable, counting locally: $error');
      return null;
    }
    if (token == null || token.isEmpty) return null;

    try {
      final rows = await _ensureLoaded(spreadsheetId, token);
      final key = _key(userId, trackId);
      final now = _nowIso();
      final row = rows[key];

      if (row != null) {
        final newCount = (_counts[key] ?? 0) + 1;
        // Targeted update; column D (`backfilled`) is left as it was.
        await _update(
          spreadsheetId,
          token,
          '$sheetName!C$row',
          <Object>[newCount],
        );
        // The count is on the sheet now, so the press has been counted even
        // if the timestamp write fails; a stale `updated_at` is not worth
        // reporting a local number the sheet disagrees with.
        try {
          await _update(spreadsheetId, token, '$sheetName!E$row', <Object>[now]);
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
      rows[key] = appendedRow;
      _counts[key] = newCount;
      return newCount;
    } catch (error) {
      // Anything unexpected and the cache may no longer match the sheet, so
      // throw it away and count locally for this press.
      debugPrint('Like counter sheet write failed, counting locally: $error');
      _invalidate();
      return null;
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
      throw http.ClientException(
        'sheets get ${response.statusCode}: ${response.body}',
      );
    }

    final decoded = jsonDecode(response.body);
    final values = decoded is Map<String, dynamic> ? decoded['values'] : null;
    final rows = <String, int>{};
    final counts = <String, int>{};
    if (values is List) {
      // Row 1 is the header; data starts at row 2.
      for (var offset = 1; offset < values.length; offset++) {
        final row = values[offset];
        if (row is! List || row.length < 3) continue;
        final key = _key('${row[0]}', '${row[1]}');
        rows[key] = offset + 1;
        counts[key] = int.tryParse('${row[2]}') ?? 0;
      }
    }
    _loadedFor = spreadsheetId;
    _rows = rows;
    _counts = counts;
    return rows;
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
      throw http.ClientException(
        'sheets update ${response.statusCode}: ${response.body}',
      );
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
      throw http.ClientException(
        'sheets append ${response.statusCode}: ${response.body}',
      );
    }
    final decoded = jsonDecode(response.body);
    final updates = decoded is Map<String, dynamic> ? decoded['updates'] : null;
    final range = updates is Map<String, dynamic> ? updates['updatedRange'] : null;
    return rowFromA1Range(range is String ? range : '');
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
