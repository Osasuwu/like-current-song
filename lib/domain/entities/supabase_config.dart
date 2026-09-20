/// The Supabase project behind the shared like counter.
///
/// Both halves come from the user (*Connected services* → *Shared like
/// counter*); with either one missing the counter stays on this device, which
/// is what [isConfigured] gates.
class SupabaseConfig {
  const SupabaseConfig({required this.url, required this.anonKey});

  /// No project: like counts stay local.
  static const empty = SupabaseConfig(url: '', anonKey: '');

  /// The project URL, e.g. `https://abcdefgh.supabase.co`.
  final String url;

  /// The project's anon (publishable) key.
  final String anonKey;

  bool get isConfigured => url.isNotEmpty && anonKey.isNotEmpty;

  @override
  bool operator ==(Object other) =>
      other is SupabaseConfig && other.url == url && other.anonKey == anonKey;

  @override
  int get hashCode => Object.hash(url, anonKey);

  @override
  String toString() =>
      'SupabaseConfig(url: $url, anonKey: ${anonKey.isEmpty ? '' : '***'})';
}
