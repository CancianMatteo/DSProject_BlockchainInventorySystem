import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';
import 'package:distr_bis/config/app_flavor.dart';
import 'package:distr_bis/models/api_response.dart';

class ApiService {
  static DateTime? _lastChainTopRefreshAt;
  static const Duration _chainTopRefreshCooldown = Duration(seconds: 30);

  static final String _configuredBaseUrl = _resolveConfiguredBaseUrl();
  static const String _configuredAppToken = String.fromEnvironment(
    'APP_CLIENT_TOKEN',
    defaultValue: '8uvF+PFoF0+rJKCOGVSKo2F0MY4f9dmAgOBfLycxt5E=',
  );
  static const bool _allowSelfSignedTlsInDebug = bool.fromEnvironment(
    'ALLOW_SELF_SIGNED_TLS',
    defaultValue: false,
  );

  static String _resolveConfiguredBaseUrl() {
    const override = String.fromEnvironment('API_BASE_URL', defaultValue: '');
    if (override.trim().isNotEmpty) {
      return override;
    }
    return AppFlavor.defaultBaseUrl;
  }

  late final String _baseUrl = _resolveBaseUrl(_configuredBaseUrl);
  late final Uri _baseUri = Uri.parse(_baseUrl);
  late final http.Client _httpClient = _buildHttpClient();
  final String _appToken = _configuredAppToken;

  static String _resolveBaseUrl(String rawUrl) {
    var normalized = rawUrl.trim();
    while (normalized.endsWith('/')) {
      normalized = normalized.substring(0, normalized.length - 1);
    }
    final uri = Uri.parse(normalized);

    if (uri.scheme.isEmpty || uri.host.isEmpty) {
      throw ArgumentError('API_BASE_URL non valido: "$rawUrl"');
    }

    return normalized;
  }

  http.Client _buildHttpClient() {
    if (kDebugMode &&
        _allowSelfSignedTlsInDebug &&
        _baseUri.scheme == 'https') {
      final ioHttpClient = HttpClient();
      ioHttpClient.badCertificateCallback = (cert, host, port) {
        // Restrict certificate bypass to the configured API host in debug mode.
        return host == _baseUri.host;
      };
      return IOClient(ioHttpClient);
    }

    return http.Client();
  }

  Uri _buildUri(String path) => Uri.parse('$_baseUrl$path');

  static bool shouldRunTopChainRefresh() {
    final now = DateTime.now();
    final last = _lastChainTopRefreshAt;
    if (last != null && now.difference(last) < _chainTopRefreshCooldown) {
      return false;
    }
    _lastChainTopRefreshAt = now;
    return true;
  }

  Map<String, String> get _headers => {
    'Content-Type': 'application/json',
    'X-App-Token': _appToken,
  };

  String _extractErrorMessage(Map<String, dynamic> body) {
    final Map<String, dynamic>? error = body['error'] as Map<String, dynamic>?;
    final String message = error?['message']?.toString() ?? 'Errore del server';
    final Map<String, dynamic>? details =
        error?['details'] as Map<String, dynamic>?;
    final String? reason = details?['reason']?.toString();

    if (reason != null && reason.trim().isNotEmpty) {
      return '$message ($reason)';
    }
    return message;
  }

  Future<ApiResponse<Map<String, dynamic>>> login(
    String email,
    String password,
  ) async {
    try {
      final response = await _httpClient.post(
        _buildUri('/api/v1/auth/login'),
        headers: _headers,
        body: jsonEncode({'email': email, 'pwd': password}),
      );

      Map<String, dynamic> body = {};
      try {
        body = jsonDecode(response.body) as Map<String, dynamic>;
      } catch (_) {
        body = {};
      }

      if (response.statusCode >= 200 && response.statusCode < 300) {
        return ApiResponse.fromJson(
          body,
          (data) => (data as Map).cast<String, dynamic>(),
        );
      } else if (response.statusCode == 401) {
        final Map<String, dynamic>? error =
            body['error'] as Map<String, dynamic>?;
        final String? code = error?['code']?.toString();
        final String message =
            error?['message']?.toString() ?? 'Accesso non autorizzato';

        if (code == 'INVALID_CREDENTIALS') {
          return ApiResponse.error('Credenziali errate');
        }
        if (code == 'APP_AUTH_REQUIRED') {
          return ApiResponse.error('Token applicazione non valido o mancante');
        }
        return ApiResponse.error('Accesso rifiutato: $message');
      } else {
        final String message =
            body['error']?['message']?.toString() ??
            'Errore del server: ${response.statusCode}';
        return ApiResponse.error(message);
      }
    } on SocketException {
      return ApiResponse.error(
        'Server di autenticazione non raggiungibile al $_baseUrl',
      );
    } catch (e) {
      return ApiResponse.error('Si è verificato un errore imprevisto: $e');
    }
  }

  Future<ApiResponse<void>> forgotPassword(String email) async {
    final response = await _httpClient.post(
      _buildUri('/api/v1/auth/forgot_pwd'),
      headers: _headers,
      body: jsonEncode({'email': email}),
    );
    final Map<String, dynamic> body =
        jsonDecode(response.body) as Map<String, dynamic>;
    if (response.statusCode >= 200 && response.statusCode < 300) {
      return ApiResponse.fromJson(body, (_) {});
    }
    return ApiResponse.error(_extractErrorMessage(body));
  }

  Future<ApiResponse<void>> resetPassword(
    String email,
    String otp,
    String newPassword,
  ) async {
    final response = await _httpClient.post(
      _buildUri('/api/v1/auth/reset_login_with_otp'),
      headers: _headers,
      body: jsonEncode({'email': email, 'otp': otp, 'new_pwd': newPassword}),
    );
    final Map<String, dynamic> body =
        jsonDecode(response.body) as Map<String, dynamic>;
    if (response.statusCode >= 200 && response.statusCode < 300) {
      return ApiResponse.fromJson(body, (_) {});
    }
    return ApiResponse.error(_extractErrorMessage(body));
  }

  Future<ApiResponse<void>> signupNewUser(
    String adminToken,
    String newName,
    String newSurname,
    String newEmail, {
    String newRole = 'user',
  }) async {
    final response = await _httpClient.post(
      _buildUri('/api/v1/users/signup_new_user'),
      headers: _headers,
      body: jsonEncode({
        'admin_token': adminToken,
        'new_name': newName,
        'new_surname': newSurname,
        'new_email': newEmail,
        'new_role': newRole,
      }),
    );
    final Map<String, dynamic> body =
        jsonDecode(response.body) as Map<String, dynamic>;
    if (response.statusCode >= 200 && response.statusCode < 300) {
      return ApiResponse.fromJson(body, (_) {});
    }
    return ApiResponse.error(_extractErrorMessage(body));
  }

  Future<ApiResponse<List<Map<String, dynamic>>>> listUsers(
    String adminToken,
  ) async {
    final response = await _httpClient.post(
      _buildUri('/api/v1/users/list_users'),
      headers: _headers,
      body: jsonEncode({'admin_token': adminToken}),
    );

    return ApiResponse.fromJson(jsonDecode(response.body), (data) {
      final List<dynamic> rawUsers =
          (data as Map<String, dynamic>)['users'] as List<dynamic>? ??
          <dynamic>[];
      return rawUsers
          .map((user) => Map<String, dynamic>.from(user as Map))
          .toList();
    });
  }

  Future<ApiResponse<void>> removeUser(String adminToken, String email) async {
    final response = await _httpClient.post(
      _buildUri('/api/v1/users/remove_user'),
      headers: _headers,
      body: jsonEncode({'admin_token': adminToken, 'email': email}),
    );
    return ApiResponse.fromJson(jsonDecode(response.body), (_) {});
  }

  Future<ApiResponse<void>> reenableUser(
    String adminToken,
    String email,
  ) async {
    final response = await _httpClient.post(
      _buildUri('/api/v1/users/reenable_user'),
      headers: _headers,
      body: jsonEncode({'admin_token': adminToken, 'email': email}),
    );
    return ApiResponse.fromJson(jsonDecode(response.body), (_) {});
  }

  Future<ApiResponse<void>> changePassword(
    String email,
    String oldPassword,
    String newPassword,
  ) async {
    final response = await _httpClient.post(
      _buildUri('/api/v1/users/change_user_pwd'),
      headers: _headers,
      body: jsonEncode({
        'email': email,
        'old_pwd': oldPassword,
        'new_pwd': newPassword,
      }),
    );
    return ApiResponse.fromJson(jsonDecode(response.body), (_) {});
  }

  Future<ApiResponse<Map<String, dynamic>>> blockchainSync(
    String clientBlockHash,
  ) async {
    try {
      final response = await _httpClient.post(
        _buildUri('/api/v1/chain/blockchain_sync'),
        headers: _headers,
        body: jsonEncode({'client_block_hash': clientBlockHash}),
      );

      Map<String, dynamic> body = {};
      try {
        body = jsonDecode(response.body) as Map<String, dynamic>;
      } catch (_) {
        body = {};
      }

      if (response.statusCode >= 200 && response.statusCode < 300) {
        return ApiResponse.fromJson(
          body,
          (data) => (data as Map).cast<String, dynamic>(),
        );
      }

      final String message =
          body['error']?['message']?.toString() ??
          'Errore del server: ${response.statusCode}';
      return ApiResponse.error(message);
    } on SocketException {
      return ApiResponse.error(
        'Server blockchain non raggiungibile al $_baseUrl',
      );
    } catch (e) {
      return ApiResponse.error('Si è verificato un errore imprevisto: $e');
    }
  }

  Future<ApiResponse<Map<String, dynamic>>> getChainHistory({
    int limit = 50,
    int? beforeNBlock,
  }) async {
    try {
      final uri = _buildUri('/api/v1/chain/history').replace(
        queryParameters: {
          'limit': '$limit',
          if (beforeNBlock != null) 'before_n_block': '$beforeNBlock',
        },
      );
      final response = await _httpClient.get(uri, headers: _headers);

      Map<String, dynamic> body = {};
      try {
        body = jsonDecode(response.body) as Map<String, dynamic>;
      } catch (_) {
        body = {};
      }

      if (response.statusCode >= 200 && response.statusCode < 300) {
        return ApiResponse.fromJson(
          body,
          (data) => (data as Map).cast<String, dynamic>(),
        );
      }

      return ApiResponse.error(
        body['error']?['message']?.toString() ??
            'Errore del server: ${response.statusCode}',
      );
    } on SocketException {
      return ApiResponse.error(
        'Server blockchain non raggiungibile al $_baseUrl',
      );
    } catch (e) {
      return ApiResponse.error('Si è verificato un errore imprevisto: $e');
    }
  }

  Future<ApiResponse<Map<String, dynamic>>> addTransaction(
    String sessionToken,
    Map<String, dynamic> transaction,
  ) async {
    try {
      final response = await _httpClient.post(
        _buildUri('/api/v1/chain/add_transaction'),
        headers: _headers,
        body: jsonEncode({
          'session_token': sessionToken,
          'transaction': transaction,
        }),
      );

      Map<String, dynamic> body = {};
      try {
        body = jsonDecode(response.body) as Map<String, dynamic>;
      } catch (_) {
        body = {};
      }

      if (response.statusCode >= 200 && response.statusCode < 300) {
        return ApiResponse.fromJson(
          body,
          (data) => (data as Map).cast<String, dynamic>(),
        );
      }

      final String message =
          body['error']?['message']?.toString() ??
          'Errore del server: ${response.statusCode}';
      return ApiResponse.error(message);
    } on SocketException {
      return ApiResponse.error(
        'Server blockchain non raggiungibile al $_baseUrl',
      );
    } catch (e) {
      return ApiResponse.error('Si è verificato un errore imprevisto: $e');
    }
  }

  Future<ApiResponse<Map<String, dynamic>>> getTransactionStatus(
    String sessionToken,
    String transactionId,
  ) async {
    try {
      final response = await _httpClient.post(
        _buildUri('/api/v1/chain/transaction_status'),
        headers: _headers,
        body: jsonEncode({
          'session_token': sessionToken,
          'tx_id': transactionId,
        }),
      );

      Map<String, dynamic> body = {};
      try {
        body = jsonDecode(response.body) as Map<String, dynamic>;
      } catch (_) {
        body = {};
      }

      if (response.statusCode >= 200 && response.statusCode < 300) {
        return ApiResponse.fromJson(
          body,
          (data) => (data as Map).cast<String, dynamic>(),
        );
      }

      return ApiResponse.error(
        _extractErrorMessage(body).isNotEmpty
            ? _extractErrorMessage(body)
            : 'Errore del server: ${response.statusCode}',
      );
    } on SocketException {
      return ApiResponse.error(
        'Server blockchain non raggiungibile al $_baseUrl',
      );
    } catch (e) {
      return ApiResponse.error('Si è verificato un errore imprevisto: $e');
    }
  }

  Future<bool> waitForTransactionFinalization(
    String sessionToken,
    String transactionId, {
    Duration timeout = const Duration(seconds: 30),
    Duration pollInterval = const Duration(seconds: 1),
  }) async {
    final deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      final response = await getTransactionStatus(sessionToken, transactionId);
      if (!response.ok) return false;
      final status = response.data?['status']?.toString();
      if (status == 'finalized') return true;
      if (status == 'unknown') return false;
      await Future<void>.delayed(pollInterval);
    }
    return false;
  }
}
