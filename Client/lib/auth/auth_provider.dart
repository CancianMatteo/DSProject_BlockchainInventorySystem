import 'package:flutter/material.dart';
import 'package:myapp/models/user.dart';
import 'package:myapp/services/api_service.dart';

class AuthProvider with ChangeNotifier {
  final ApiService _apiService = ApiService();
  bool _isAuthenticated = false;
  User? _user;
  String? _sessionToken;

  bool get isAuthenticated => _isAuthenticated;
  User? get user => _user;
  String? get sessionToken => _sessionToken;

  Future<void> login(String email, String password) async {
    final response = await _apiService.login(email, password);

    if (response.ok && response.data != null) {
      _isAuthenticated = true;
      _user = User.fromJson(response.data!['user']);
      _sessionToken = response.data!['session_token'];
      notifyListeners();
    } else {
      _isAuthenticated = false;
      _user = null;
      _sessionToken = null;
      notifyListeners();
      throw Exception(response.errorMessage ?? 'Login failed');
    }
  }

  void logout() {
    _isAuthenticated = false;
    _user = null;
    _sessionToken = null;
    notifyListeners();
  }
}
