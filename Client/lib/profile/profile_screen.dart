import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:myapp/auth/auth_provider.dart';
import 'package:myapp/services/api_service.dart';
import 'package:provider/provider.dart';

class ProfileScreen extends StatefulWidget {
  const ProfileScreen({super.key});

  @override
  State<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends State<ProfileScreen> {
  final ApiService _apiService = ApiService();
  _ProfileStats _stats = _ProfileStats.empty();
  bool _isLoadingStats = true;

  @override
  void initState() {
    super.initState();
    _loadStats();
  }

  Future<void> _loadStats() async {
    setState(() => _isLoadingStats = true);

    final authProvider = Provider.of<AuthProvider>(context, listen: false);
    final currentEmail = authProvider.user?.email;
    final response = await _apiService.checkChainSync('');

    if (!mounted) return;

    if (!response.ok || response.data == null || currentEmail == null) {
      setState(() {
        _stats = _ProfileStats.empty();
        _isLoadingStats = false;
      });
      return;
    }

    final Map<String, dynamic> data = response.data!;
    final List<dynamic> allBlocks =
        data['missing_blocks'] as List<dynamic>? ?? <dynamic>[];
    final List<dynamic> inventory =
        data['inventory'] as List<dynamic>? ?? <dynamic>[];

    final Set<String> categories = <String>{};
    for (final row in inventory) {
      if (row is! Map<String, dynamic>) continue;
      final category = (row['category'] ?? '').toString().trim();
      if (category.isNotEmpty) {
        categories.add(category);
      }
    }

    int userChanges = 0;
    int totalChanges = 0;
    int userAdditions = 0;
    int totalAdditions = 0;
    int userRemovals = 0;
    int totalRemovals = 0;

    for (final block in allBlocks) {
      if (block is! Map<String, dynamic>) continue;
      final authorEmail = (block['author_email'] ?? '').toString();
      final isMine = authorEmail == currentEmail;

      final rawChanges = block['changes'];
      if (rawChanges is! Map) continue;

      for (final entry in rawChanges.entries) {
        final delta = (entry.value as num?)?.toInt() ?? 0;
        if (delta == 0) continue;

        totalChanges += 1;
        if (isMine) userChanges += 1;

        if (delta > 0) {
          totalAdditions += 1;
          if (isMine) userAdditions += 1;
        } else {
          totalRemovals += 1;
          if (isMine) userRemovals += 1;
        }
      }
    }

    setState(() {
      _stats = _ProfileStats(
        totalCategories: categories.length,
        totalItems: inventory.length,
        userChanges: userChanges,
        totalChanges: totalChanges,
        userAdditions: userAdditions,
        totalAdditions: totalAdditions,
        userRemovals: userRemovals,
        totalRemovals: totalRemovals,
      );
      _isLoadingStats = false;
    });
  }

  Future<void> _showChangePasswordDialog(BuildContext context) async {
    final authProvider = Provider.of<AuthProvider>(context, listen: false);
    final email = authProvider.user?.email;

    if (email == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Utente non trovato. Effettua nuovamente il login.'),
          backgroundColor: Colors.red,
        ),
      );
      return;
    }

    return showDialog(
      context: context,
      builder: (context) => _ChangePasswordDialog(email: email),
    );
  }

  @override
  Widget build(BuildContext context) {
    final authProvider = Provider.of<AuthProvider>(context);
    final user = authProvider.user;
    final bool isAdmin = (user?.role.toLowerCase() ?? '') == 'admin';

    return Scaffold(
      appBar: AppBar(
        title: const Text(
          'Profilo',
          style: TextStyle(fontWeight: FontWeight.bold, fontSize: 32),
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.logout),
            tooltip: 'Logout',
            onPressed: () =>
                Provider.of<AuthProvider>(context, listen: false).logout(),
          ),
        ],
      ),
      body: user == null
          ? const Center(child: Text('Nessun utente loggato.'))
          : SingleChildScrollView(
              padding: const EdgeInsets.all(16.0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Dati utente',
                    style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 12),
                  _buildInfoCard(
                    child: Column(
                      children: [
                        _buildStatsRow(label: 'Nome', value: user.name),
                        const Divider(),
                        _buildStatsRow(label: 'Cognome', value: user.surname),
                        const Divider(),
                        _buildStatsRow(label: 'Email', value: user.email),
                        const Divider(),
                        _buildStatsRow(label: 'Ruolo', value: user.role),
                      ],
                    ),
                  ),
                  const SizedBox(height: 16),
                  _buildInfoCard(
                    child: SizedBox(
                      width: double.infinity,
                      child: ElevatedButton.icon(
                        icon: const Icon(Icons.lock_outline),
                        onPressed: () => _showChangePasswordDialog(context),
                        label: const Text('Cambia password'),
                      ),
                    ),
                  ),
                  if (isAdmin) ...[
                    const SizedBox(height: 12),
                    _buildInfoCard(
                      child: SizedBox(
                        width: double.infinity,
                        child: ElevatedButton.icon(
                          icon: const Icon(Icons.manage_accounts),
                          onPressed: () =>
                              context.push('/profile/users-management'),
                          label: const Text('Users Management'),
                        ),
                      ),
                    ),
                  ],
                  const SizedBox(height: 16),
                  _buildInfoCard(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            const Text(
                              'Statistiche',
                              style: TextStyle(
                                fontSize: 18,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                            IconButton(
                              tooltip: 'Aggiorna statistiche',
                              onPressed: _isLoadingStats ? null : _loadStats,
                              icon: const Icon(Icons.refresh),
                            ),
                          ],
                        ),
                        if (_isLoadingStats)
                          const Padding(
                            padding: EdgeInsets.symmetric(vertical: 8),
                            child: Center(child: CircularProgressIndicator()),
                          )
                        else
                          Column(
                            children: [
                              _buildDoubleStatRow(
                                leftLabel: 'Tot categorie',
                                leftValue: _stats.totalCategories.toString(),
                                rightLabel: 'Tot articoli',
                                rightValue: _stats.totalItems.toString(),
                              ),
                              const Divider(height: 16),
                              _buildDoubleStatRow(
                                leftLabel: 'Modifiche tue',
                                leftValue: _stats.userChanges.toString(),
                                rightLabel: 'Modifiche tot',
                                rightValue: _stats.totalChanges.toString(),
                              ),
                              const Divider(height: 16),
                              _buildDoubleStatRow(
                                leftLabel: 'Aggiunte tue',
                                leftValue: _stats.userAdditions.toString(),
                                rightLabel: 'Aggiunte tot',
                                rightValue: _stats.totalAdditions.toString(),
                              ),
                              const Divider(height: 16),
                              _buildDoubleStatRow(
                                leftLabel: 'Rimozioni tue',
                                leftValue: _stats.userRemovals.toString(),
                                rightLabel: 'Rimozioni tot',
                                rightValue: _stats.totalRemovals.toString(),
                              ),
                            ],
                          ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
    );
  }

  Widget _buildInfoCard({required Widget child}) {
    return Card(
      elevation: 2,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: Padding(padding: const EdgeInsets.all(16.0), child: child),
    );
  }

  Widget _buildStatsRow({required String label, required String value}) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8.0),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label, style: const TextStyle(fontSize: 16)),
          Text(
            value,
            style: const TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.bold,
              color: Colors.blueAccent,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildDoubleStatRow({
    required String leftLabel,
    required String leftValue,
    required String rightLabel,
    required String rightValue,
  }) {
    return Row(
      children: [
        Expanded(
          child: _buildStatColumn(label: leftLabel, value: leftValue),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: _buildStatColumn(label: rightLabel, value: rightValue),
        ),
      ],
    );
  }

  Widget _buildStatColumn({required String label, required String value}) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: const TextStyle(fontSize: 14, color: Colors.black54),
        ),
        const SizedBox(height: 2),
        Text(
          value,
          style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
        ),
      ],
    );
  }
}

class _ProfileStats {
  final int totalCategories;
  final int totalItems;
  final int userChanges;
  final int totalChanges;
  final int userAdditions;
  final int totalAdditions;
  final int userRemovals;
  final int totalRemovals;

  const _ProfileStats({
    required this.totalCategories,
    required this.totalItems,
    required this.userChanges,
    required this.totalChanges,
    required this.userAdditions,
    required this.totalAdditions,
    required this.userRemovals,
    required this.totalRemovals,
  });

  factory _ProfileStats.empty() {
    return const _ProfileStats(
      totalCategories: 0,
      totalItems: 0,
      userChanges: 0,
      totalChanges: 0,
      userAdditions: 0,
      totalAdditions: 0,
      userRemovals: 0,
      totalRemovals: 0,
    );
  }
}

class _ChangePasswordDialog extends StatefulWidget {
  final String email;

  const _ChangePasswordDialog({required this.email});

  @override
  State<_ChangePasswordDialog> createState() => _ChangePasswordDialogState();
}

class _ChangePasswordDialogState extends State<_ChangePasswordDialog> {
  final _formKey = GlobalKey<FormState>();
  final _oldPasswordController = TextEditingController();
  final _newPasswordController = TextEditingController();
  final _confirmPasswordController = TextEditingController();
  bool _isLoading = false;

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) {
      return;
    }

    setState(() => _isLoading = true);

    final apiService = ApiService();
    final response = await apiService.changePassword(
      widget.email,
      _oldPasswordController.text,
      _newPasswordController.text,
    );

    if (!mounted) return;

    setState(() => _isLoading = false);

    if (response.ok) {
      Navigator.of(context).pop();
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Password modificata con successo!'),
          backgroundColor: Colors.green,
        ),
      );
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Errore: ${response.errorMessage}'),
          backgroundColor: Colors.red,
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Cambia Password'),
      content: Form(
        key: _formKey,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextFormField(
                controller: _oldPasswordController,
                decoration: const InputDecoration(
                  labelText: 'Vecchia Password',
                ),
                obscureText: true,
                validator: (value) => value == null || value.isEmpty
                    ? 'Campo obbligatorio'
                    : null,
              ),
              const SizedBox(height: 16),
              TextFormField(
                controller: _newPasswordController,
                decoration: const InputDecoration(labelText: 'Nuova Password'),
                obscureText: true,
                validator: (value) {
                  if (value == null || value.isEmpty) {
                    return 'Campo obbligatorio';
                  }
                  if (value.length < 8) {
                    return 'La password deve contenere almeno 8 caratteri';
                  }
                  return null;
                },
              ),
              const SizedBox(height: 16),
              TextFormField(
                controller: _confirmPasswordController,
                decoration: const InputDecoration(
                  labelText: 'Conferma Nuova Password',
                ),
                obscureText: true,
                validator: (value) {
                  if (value != _newPasswordController.text) {
                    return 'Le password non coincidono';
                  }
                  return null;
                },
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _isLoading ? null : () => Navigator.of(context).pop(),
          child: const Text('Annulla'),
        ),
        ElevatedButton(
          onPressed: _isLoading ? null : _submit,
          child: _isLoading
              ? const SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Text('Conferma'),
        ),
      ],
    );
  }
}
