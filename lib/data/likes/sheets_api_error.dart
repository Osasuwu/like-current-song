import 'dart:convert';

/// Where the Sheets API is switched on, for when Google named no URL of its
/// own. This is the API's page in the *library*: the credentials page, which
/// the README used to send people to, creates OAuth clients and cannot enable
/// anything.
const String sheetsApiLibraryUrl =
    'https://console.cloud.google.com/apis/library/sheets.googleapis.com';

/// Google's "you never switched this API on", read back into words.
///
/// A Cloud project with an OAuth client but the Sheets API off is the likely
/// first-run failure rather than an edge case (#165): the README suggests
/// reusing the *TVs and Limited Input devices* client made for YouTube Music,
/// and such a project has never had Sheets on. Google says so plainly in the
/// body — a reason, the project, and a one-click activation URL — and this
/// app used to show the status code and throw the rest away.
///
/// `like_spotify/extensions/google_sheets_storage/errors.py` is the desktop
/// twin of this class and reads the same two body shapes.
class SheetsApiDisabled {
  const SheetsApiDisabled({required this.activationUrl, this.project});

  /// The page that switches the API on — Google's own one-click link when the
  /// body carried it, otherwise [sheetsApiLibraryUrl].
  final String activationUrl;

  /// The Cloud project Google named, when it named one. Worth repeating: a
  /// developer usually has several, and only one of them is wrong.
  final String? project;

  /// Both spellings of "you never turned this API on": the `ErrorInfo` reason
  /// current APIs send, and the one the older error shape still uses.
  static const Set<String> _disabledReasons = <String>{
    'SERVICE_DISABLED',
    'accessNotConfigured',
  };

  /// The old shape carries no activation URL of its own; it puts one in the
  /// prose of `error.message`, so that is where we go looking for it.
  static final RegExp _urlInProse = RegExp(r'''https?://[^\s"'<>)\]]+''');

  /// Likewise the project: "...has not been used in project 123456 before...".
  static final RegExp _projectInProse =
      RegExp(r'\bproject\s+([A-Za-z0-9][\w.:-]*)');

  /// What to tell the user, in one sentence that ends in something to do.
  String get message {
    final where = project == null ? '' : ' ($project)';
    return 'The Google Sheets API is not enabled on your Google Cloud '
        'project$where. Enable it at $activationUrl, give Google a minute to '
        'catch up, then try again.';
  }

  /// Reads a refusal, or answers null when it is some other failure.
  ///
  /// Only a 403 is ever read this way — that is the status Google uses for a
  /// disabled service — and only when the body actually names the reason. A
  /// 403 for a revoked token, or one with nothing parseable in it, is left to
  /// the caller to report as it always did: guessing "the API is off" at
  /// someone whose API is on would be worse than a status code.
  static SheetsApiDisabled? read(int statusCode, String body) {
    if (statusCode != 403) return null;

    final Object? decoded;
    try {
      decoded = jsonDecode(body);
    } catch (_) {
      return null;
    }
    if (decoded is! Map<String, dynamic>) return null;
    final error = decoded['error'];
    if (error is! Map<String, dynamic>) return null;

    var disabled = false;
    String? activationUrl;
    String? project;

    // Current shape: a `google.rpc.ErrorInfo` among `error.details`, which
    // carries the activation URL and the project as `projects/123456`.
    final details = error['details'];
    if (details is List) {
      for (final detail in details) {
        if (detail is! Map<String, dynamic>) continue;
        if (!_disabledReasons.contains(detail['reason'])) continue;
        disabled = true;
        final metadata = detail['metadata'];
        if (metadata is! Map<String, dynamic>) continue;
        activationUrl ??= _nonEmpty(metadata['activationUrl']);
        final consumer = _nonEmpty(metadata['consumer']);
        if (consumer != null) {
          project ??= _nonEmpty(consumer.split('/').last);
        }
      }
    }

    // Older shape: `error.errors[0].reason == "accessNotConfigured"`, with
    // nothing beside it — whatever it can tell us is in the message.
    if (!disabled) {
      final errors = error['errors'];
      if (errors is List) {
        disabled = errors.any(
          (Object? old) =>
              old is Map<String, dynamic> &&
              _disabledReasons.contains(old['reason']),
        );
      }
    }
    if (!disabled) return null;

    final message = _nonEmpty(error['message']) ?? '';
    if (activationUrl == null) {
      final found = _urlInProse.firstMatch(message);
      if (found != null) {
        activationUrl = found.group(0)!.replaceAll(RegExp(r'[.,;]+$'), '');
      }
    }
    project ??= _projectInProse.firstMatch(message)?.group(1);

    return SheetsApiDisabled(
      activationUrl: activationUrl ?? sheetsApiLibraryUrl,
      project: project,
    );
  }

  static String? _nonEmpty(Object? value) {
    if (value is! String) return null;
    final trimmed = value.trim();
    return trimmed.isEmpty ? null : trimmed;
  }
}
