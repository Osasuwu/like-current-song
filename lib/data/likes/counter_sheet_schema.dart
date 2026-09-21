/// The shape of the shared counter spreadsheet, in one place.
///
/// Three halves write this same sheet — this file, the native counter
/// (`android/.../CounterSheetSchema.kt`) and the desktop storage extension
/// (`like_spotify/extensions/google_sheets_storage/schema.py`). Until the app
/// created the sheet itself a drift between them only cost a confusing bug
/// report; now the app types the header, so a drift means one half appends
/// rows another half will never find. `tests/test_counter_schema_parity.py`
/// fails the build if the three stop agreeing.
///
/// The `ArtistTracks` tab is desktop-only, but the phone creates it all the
/// same: the same spreadsheet is meant to serve both.
abstract final class CounterSheetSchema {
  /// The title a freshly created spreadsheet gets in the user's Drive.
  static const String spreadsheetTitle = 'Like Current Song counters';

  /// The tab the per-track counts live on.
  static const String likesTab = 'Likes';

  /// Row 1 of [likesTab]. Data starts at row 2.
  static const List<String> likesHeader = <String>[
    'user_id',
    'track_id',
    'count',
    'backfilled',
    'updated_at',
  ];

  /// The tab the desktop half records (user, artist, track) triples on.
  static const String artistTracksTab = 'ArtistTracks';

  /// Row 1 of [artistTracksTab].
  static const List<String> artistTracksHeader = <String>[
    'user_id',
    'artist_id',
    'track_id',
    'created_at',
  ];

  /// The A1 column letter [header] keeps [column] in — so that reordering the
  /// header moves the writes with it instead of silently writing the wrong
  /// cell.
  static String columnOf(List<String> header, String column) {
    final index = header.indexOf(column);
    if (index < 0 || index > 25) {
      throw ArgumentError.value(column, 'column', 'not an A1 column of $header');
    }
    return String.fromCharCode(0x41 + index);
  }

  /// `count` on the [likesTab].
  static final String countColumn = columnOf(likesHeader, 'count');

  /// `updated_at` on the [likesTab].
  static final String updatedAtColumn = columnOf(likesHeader, 'updated_at');
}
