import 'package:flutter_test/flutter_test.dart';
import 'package:like_spotify_mobile_app/domain/entities/device_sign_in.dart';

void main() {
  group('OAuthClientCredentials.isComplete', () {
    OAuthClientCredentials credentials(String id, String secret) =>
        OAuthClientCredentials(clientId: id, clientSecret: secret);

    test('both halves filled in', () {
      expect(credentials('id', 'secret').isComplete, isTrue);
    });

    test('an empty half is incomplete', () {
      expect(credentials('', 'secret').isComplete, isFalse);
      expect(credentials('id', '').isComplete, isFalse);
      expect(credentials('', '').isComplete, isFalse);
    });

    test('whitespace is not a value', () {
      // Pasting from the Google console can leave a stray space or newline.
      expect(credentials('  ', 'secret').isComplete, isFalse);
      expect(credentials('id', '\n').isComplete, isFalse);
      expect(credentials(' \t ', ' \n ').isComplete, isFalse);
    });

    test('surrounding whitespace does not make a real value empty', () {
      expect(credentials('  id  ', ' secret\n').isComplete, isTrue);
    });
  });

  group('DeviceSignInException', () {
    test('carries the failure and shows the message as-is', () {
      const exception = DeviceSignInException(
        DeviceSignInFailure.denied,
        'You declined the sign-in on the other screen.',
      );

      expect(exception.failure, DeviceSignInFailure.denied);
      expect(exception.message, 'You declined the sign-in on the other screen.');
      // The UI prints the exception directly, so toString is the message.
      expect('$exception', 'You declined the sign-in on the other screen.');
    });

    test('is an Exception', () {
      const exception =
          DeviceSignInException(DeviceSignInFailure.network, 'Offline.');
      expect(exception, isA<Exception>());
    });
  });
}
