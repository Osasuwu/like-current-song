import 'dart:convert';

import 'package:http/http.dart' as http;

import 'counter_sheet_schema.dart';
import 'sheets_api_error.dart';

/// A spreadsheet the app just made in the user's Drive.
class CreatedCounterSpreadsheet {
  const CreatedCounterSpreadsheet({required this.spreadsheetId, this.url});

  /// The id to store through the usual save path.
  final String spreadsheetId;

  /// Where the user can open it, when Google said. Never needed to count.
  final String? url;
}

/// Creation failed in a way worth showing the user.
class CounterSpreadsheetException implements Exception {
  const CounterSpreadsheetException(this.message, {this.activationUrl});

  final String message;

  /// A page in the Google Cloud console that fixes this, when the failure has
  /// one — today only a project whose Sheets API is off. [message] names it
  /// too; this carries it separately so the screen can offer a button rather
  /// than a URL to copy out by hand.
  final String? activationUrl;

  @override
  String toString() => message;
}

/// Creates the shared counter spreadsheet so nobody has to build one by hand.
///
/// One `POST /v4/spreadsheets` makes the file, both tabs and both header rows
/// in a single call — there is no half-made state to clean up if it fails.
/// The scope this needs, `spreadsheets`, is the one the counter sign-in has
/// always asked for (`GoogleScopes.spreadsheets`), so an account that is
/// already signed in can do this without consenting to anything new.
///
/// Whether one is already configured is the caller's business: this class
/// makes a spreadsheet every time it is asked to.
class CounterSpreadsheetCreator {
  CounterSpreadsheetCreator({
    required this.readAccessToken,
    http.Client? httpClient,
  }) : _httpClient = httpClient ?? http.Client();

  static const String _createUrl = 'https://sheets.googleapis.com/v4/spreadsheets';

  /// Longer than a like's budget: the user asked for this and is watching.
  static const Duration _timeout = Duration(seconds: 15);

  /// A Google access token good right now, or null when the counter is not
  /// signed in.
  final Future<String?> Function() readAccessToken;

  final http.Client _httpClient;

  /// The body of the create call: the title, both tabs, both header rows.
  static Map<String, dynamic> requestBody() => <String, dynamic>{
        'properties': <String, dynamic>{
          'title': CounterSheetSchema.spreadsheetTitle,
        },
        'sheets': <Map<String, dynamic>>[
          _tab(CounterSheetSchema.likesTab, CounterSheetSchema.likesHeader),
          _tab(
            CounterSheetSchema.artistTracksTab,
            CounterSheetSchema.artistTracksHeader,
          ),
        ],
      };

  static Map<String, dynamic> _tab(String title, List<String> header) =>
      <String, dynamic>{
        'properties': <String, dynamic>{'title': title},
        'data': <Map<String, dynamic>>[
          <String, dynamic>{
            'startRow': 0,
            'startColumn': 0,
            'rowData': <Map<String, dynamic>>[
              <String, dynamic>{
                'values': <Map<String, dynamic>>[
                  for (final cell in header)
                    <String, dynamic>{
                      'userEnteredValue': <String, dynamic>{'stringValue': cell},
                    },
                ],
              },
            ],
          },
        ],
      };

  /// Makes the spreadsheet and answers its id.
  ///
  /// Throws [CounterSpreadsheetException] when the counter is not signed in,
  /// when Google refuses, or when the reply carries no id.
  Future<CreatedCounterSpreadsheet> create() async {
    final String? token;
    try {
      token = await readAccessToken();
    } catch (error) {
      throw CounterSpreadsheetException(
        'Could not reach the Google account for the counter: $error',
      );
    }
    if (token == null || token.isEmpty) {
      throw const CounterSpreadsheetException(
        'Sign in to Google for the like counter first.',
      );
    }

    final http.Response response;
    try {
      response = await _httpClient
          .post(
            Uri.parse(_createUrl),
            headers: <String, String>{
              'Authorization': 'Bearer $token',
              'Content-Type': 'application/json',
            },
            body: jsonEncode(requestBody()),
          )
          .timeout(_timeout);
    } catch (error) {
      throw CounterSpreadsheetException(
        'Could not create the spreadsheet: $error',
      );
    }

    if (response.statusCode < 200 || response.statusCode > 299) {
      // A project that never had the Sheets API switched on refuses every
      // create with a 403, and Google's body says so and links the page that
      // turns it on. Quoting the status code and the raw JSON instead left
      // the user to work that out for themselves (#165).
      final disabled =
          SheetsApiDisabled.read(response.statusCode, response.body);
      if (disabled != null) {
        throw CounterSpreadsheetException(
          disabled.message,
          activationUrl: disabled.activationUrl,
        );
      }
      throw CounterSpreadsheetException(
        'Google refused to create the spreadsheet '
        '(${response.statusCode}). ${response.body}'.trim(),
      );
    }

    final decoded = jsonDecode(response.body);
    final id = decoded is Map<String, dynamic> ? decoded['spreadsheetId'] : null;
    if (id is! String || id.isEmpty) {
      throw const CounterSpreadsheetException(
        'Google created the spreadsheet but did not say which one.',
      );
    }
    final url = decoded is Map<String, dynamic> ? decoded['spreadsheetUrl'] : null;
    return CreatedCounterSpreadsheet(
      spreadsheetId: id,
      url: url is String && url.isNotEmpty ? url : null,
    );
  }
}
