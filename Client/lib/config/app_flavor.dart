class AppFlavor {
  static const String _rawFlavor = String.fromEnvironment(
    'APP_FLAVOR',
    defaultValue: 'prod',
  );

  static const String _defaultProdBaseUrl = String.fromEnvironment(
    'API_BASE_URL_PROD',
    defaultValue: 'http://bis.samuel-daros.it',
  );
  static const String _defaultDevBaseUrl = String.fromEnvironment(
    'API_BASE_URL_DEV',
    defaultValue: 'http://bis-dev.samuel-daros.it',
  );

  static String get flavor => _rawFlavor.trim().toLowerCase();

  static bool get isDev => flavor == 'dev';

  static String get defaultBaseUrl {
    return isDev ? _defaultDevBaseUrl : _defaultProdBaseUrl;
  }
}
