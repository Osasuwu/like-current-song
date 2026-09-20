import 'package:mocktail/mocktail.dart';
import 'package:like_spotify_mobile_app/domain/repositories/settings_repository.dart';
import 'package:like_spotify_mobile_app/domain/repositories/music_routing_repository.dart';
import 'package:like_spotify_mobile_app/domain/repositories/music_service_repository.dart';
import 'package:like_spotify_mobile_app/domain/repositories/platform_service_repository.dart';
import 'package:like_spotify_mobile_app/domain/repositories/like_count_repository.dart';
import 'package:like_spotify_mobile_app/data/spotify/spotify_client.dart';
import 'package:like_spotify_mobile_app/data/spotify/spotify_token_store.dart';
import 'package:like_spotify_mobile_app/data/spotify/spotify_playlist_service.dart';
import 'package:http/http.dart' as http;

class MockSettingsRepository extends Mock implements SettingsRepository {}

class MockMusicServiceRepository extends Mock
    implements MusicServiceRepository {}

class MockMusicRoutingRepository extends Mock
    implements MusicRoutingRepository {}

class MockPlatformServiceRepository extends Mock
    implements PlatformServiceRepository {}

class MockHttpClient extends Mock implements http.Client {}

class MockLikeCountRepository extends Mock implements LikeCountRepository {}

class MockSpotifyClient extends Mock implements SpotifyClient {}

class MockSpotifyTokenStore extends Mock implements SpotifyTokenStore {}

class MockSpotifyPlaylistService extends Mock
    implements SpotifyPlaylistService {}
