import 'package:flutter/material.dart';
import 'package:distr_bis/auth/auth_provider.dart';
import 'package:distr_bis/services/api_service.dart';
import 'package:provider/provider.dart';

class UsersManagementScreen extends StatefulWidget {
  const UsersManagementScreen({super.key});

  @override
  State<UsersManagementScreen> createState() => _UsersManagementScreenState();
}

class _UsersManagementScreenState extends State<UsersManagementScreen> {
  final ApiService _apiService = ApiService();
  final _formKey = GlobalKey<FormState>();

  final _nameController = TextEditingController();
  final _surnameController = TextEditingController();
  final _emailController = TextEditingController();

  bool _loading = true;
  bool _creating = false;
  List<Map<String, dynamic>> _users = <Map<String, dynamic>>[];

  @override
  void initState() {
    super.initState();
    _loadUsers();
  }

  @override
  void dispose() {
    _nameController.dispose();
    _surnameController.dispose();
    _emailController.dispose();
    super.dispose();
  }

  String? get _adminToken => context.read<AuthProvider>().sessionToken;

  Future<void> _loadUsers() async {
    final adminToken = _adminToken;
    if (adminToken == null) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Invalid session. Please sign in again.'),
          backgroundColor: Colors.red,
        ),
      );
      setState(() => _loading = false);
      return;
    }

    setState(() => _loading = true);
    final response = await _apiService.listUsers(adminToken);
    if (!mounted) return;

    if (response.ok && response.data != null) {
      setState(() {
        _users = response.data!;
        _loading = false;
      });
      return;
    }

    setState(() => _loading = false);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          response.errorMessage ?? 'Failed to load users',
        ),
        backgroundColor: Colors.red,
      ),
    );
  }

  Future<void> _createUser() async {
    if (!_formKey.currentState!.validate()) return;

    final adminToken = _adminToken;
    if (adminToken == null) return;

    setState(() => _creating = true);

    final response = await _apiService.signupNewUser(
      adminToken,
      _nameController.text.trim(),
      _surnameController.text.trim(),
      _emailController.text.trim(),
    );

    if (!mounted) return;

    setState(() => _creating = false);

    if (!response.ok) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(response.errorMessage ?? 'Failed to create user'),
          backgroundColor: Colors.red,
        ),
      );
      return;
    }

    _nameController.clear();
    _surnameController.clear();
    _emailController.clear();
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('User created. A temporary password was sent by email.'),
        backgroundColor: Colors.green,
      ),
    );
    await _loadUsers();
  }

  Future<void> _reenableUser(Map<String, dynamic> user) async {
    final adminToken = _adminToken;
    if (adminToken == null) return;

    final email = user['email']?.toString() ?? '';
    final name = user['name']?.toString() ?? '';
    final surname = user['surname']?.toString() ?? '';

    final bool? confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Reactivate user'),
        content: Text('Reactivate $surname $name ($email)?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.of(context).pop(true),
            style: ElevatedButton.styleFrom(backgroundColor: Colors.green),
            child: const Text('Reactivate'),
          ),
        ],
      ),
    );

    if (confirmed != true) return;

    final response = await _apiService.reenableUser(adminToken, email);
    if (!mounted) return;

    if (!response.ok) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(response.errorMessage ?? 'Failed to reactivate user'),
          backgroundColor: Colors.red,
        ),
      );
      return;
    }

    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('User reactivated'),
        backgroundColor: Colors.green,
      ),
    );
    await _loadUsers();
  }

  Future<void> _disableUser(Map<String, dynamic> user) async {
    final adminToken = _adminToken;
    if (adminToken == null) return;

    final email = user['email']?.toString() ?? '';
    final name = user['name']?.toString() ?? '';
    final surname = user['surname']?.toString() ?? '';

    final bool? confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Disable user'),
        content: Text(
          'Disable $surname $name ($email)?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.of(context).pop(true),
            style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
            child: const Text('Disable'),
          ),
        ],
      ),
    );

    if (confirmed != true) return;

    final response = await _apiService.removeUser(adminToken, email);
    if (!mounted) return;

    if (!response.ok) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            response.errorMessage ?? 'Failed to disable user',
          ),
          backgroundColor: Colors.red,
        ),
      );
      return;
    }

    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('User disabled'),
        backgroundColor: Colors.green,
      ),
    );
    await _loadUsers();
  }

  @override
  Widget build(BuildContext context) {
    final auth = context.watch<AuthProvider>();
    final currentUserEmail = auth.user?.email;
    final isAdmin = (auth.user?.role.toLowerCase() ?? '') == 'admin';

    if (!isAdmin) {
      return Scaffold(
        appBar: AppBar(title: const Text('Users Management')),
        body: const Center(
          child: Text('Only administrators can access this page'),
        ),
      );
    }

    return Scaffold(
      appBar: AppBar(title: const Text('Users Management')),
      body: RefreshIndicator(
        onRefresh: _loadUsers,
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Card(
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
              ),
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Form(
                  key: _formKey,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'Create new user',
                        style: TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 12),
                      TextFormField(
                        controller: _nameController,
                        textInputAction: TextInputAction.next,
                        decoration: const InputDecoration(labelText: 'First name*'),
                        validator: (value) =>
                            value == null || value.trim().isEmpty
                            ? 'This field is required'
                            : null,
                      ),
                      const SizedBox(height: 10),
                      TextFormField(
                        controller: _surnameController,
                        textInputAction: TextInputAction.next,
                        decoration: const InputDecoration(
                          labelText: 'Last name*',
                        ),
                        validator: (value) =>
                            value == null || value.trim().isEmpty
                            ? 'This field is required'
                            : null,
                      ),
                      const SizedBox(height: 10),
                      TextFormField(
                        controller: _emailController,
                        textInputAction: TextInputAction.next,
                        keyboardType: TextInputType.emailAddress,
                        decoration: const InputDecoration(labelText: 'Email*'),
                        validator: (value) {
                          final raw = value?.trim() ?? '';
                          if (raw.isEmpty) return 'This field is required';
                          if (!raw.contains('@')) return 'Invalid email address';
                          return null;
                        },
                      ),
                      const SizedBox(height: 14),
                      SizedBox(
                        width: double.infinity,
                        child: ElevatedButton.icon(
                          onPressed: _creating ? null : _createUser,
                          icon: const Icon(Icons.person_add_alt_1),
                          label: _creating
                              ? const SizedBox(
                                  width: 18,
                                  height: 18,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                  ),
                                )
                              : const Text('Create user'),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            const SizedBox(height: 16),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Text(
                  'Users',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
                ),
                TextButton.icon(
                  onPressed: _loading ? null : _loadUsers,
                  icon: const Icon(Icons.refresh),
                  label: const Text('Refresh'),
                ),
              ],
            ),
            if (_loading)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 40),
                child: Center(child: CircularProgressIndicator()),
              )
            else if (_users.isEmpty)
              const Card(
                child: Padding(
                  padding: EdgeInsets.all(16),
                  child: Text('No users found'),
                ),
              )
            else
              ..._users.map((user) {
                final isActive = (user['is_active'] as bool?) ?? false;
                final isCurrentUser =
                    (user['email']?.toString() ?? '') ==
                    (currentUserEmail ?? '');
                final textColor = isActive ? Colors.black : Colors.grey;
                return Card(
                  child: ListTile(
                    title: Text(
                      '${user['surname'] ?? ''} ${user['name'] ?? ''}'.trim(),
                      style: TextStyle(color: textColor),
                    ),
                    subtitle: Text(
                      '${user['email'] ?? ''} - role: ${user['role'] ?? ''}',
                      style: TextStyle(color: textColor),
                    ),
                    trailing: !isCurrentUser
                        ? (isActive
                              ? TextButton.icon(
                                  onPressed: () => _disableUser(user),
                                  style: TextButton.styleFrom(
                                    foregroundColor: Colors.red,
                                  ),
                                  icon: const Icon(Icons.block),
                                  label: const Text('Disabilita'),
                                )
                              : TextButton.icon(
                                  onPressed: () => _reenableUser(user),
                                  style: TextButton.styleFrom(
                                    foregroundColor: Colors.green,
                                  ),
                                  icon: const Icon(Icons.replay_circle_filled),
                                  label: const Text('Riabilita'),
                                ))
                        : const Text(
                            'Current user',
                            style: TextStyle(color: Colors.black54),
                          ),
                  ),
                );
              }),
          ],
        ),
      ),
    );
  }
}
