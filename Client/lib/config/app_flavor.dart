class AppFlavor {
  static const String _rawFlavor = String.fromEnvironment(
    'APP_FLAVOR',
    defaultValue: 'prod',
  );

  static const String _defaultProdBaseUrl = String.fromEnvironment(
    'API_BASE_URL_PROD',
    defaultValue: 'http://100.67.33.52:8002',
  );
  static const String _defaultDevBaseUrl = String.fromEnvironment(
    'API_BASE_URL_DEV',
    defaultValue: 'http://100.67.33.52:8002',
  );

  static String get flavor => _rawFlavor.trim().toLowerCase();

  static bool get isDev => flavor == 'dev';

  static String get defaultBaseUrl {
    return isDev ? _defaultDevBaseUrl : _defaultProdBaseUrl;
  }
}
