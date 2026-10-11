class AppConfig {
  const AppConfig._();

  static const supabaseUrl = String.fromEnvironment('SUPABASE_URL');
  static const supabasePublishableKey =
      String.fromEnvironment('SUPABASE_PUBLISHABLE_KEY');
  static const isSupabaseConfigured =
      supabaseUrl != '' && supabasePublishableKey != '';

  static String get leadEndpoint => supabaseUrl.isEmpty
      ? ''
      : '$supabaseUrl/functions/v1/receive-lead';
}