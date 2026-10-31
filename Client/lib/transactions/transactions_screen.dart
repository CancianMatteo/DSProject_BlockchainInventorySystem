import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';
import 'package:distr_bis/auth/auth_provider.dart';
import 'package:distr_bis/services/api_service.dart';
import 'package:distr_bis/transactions/pending_transaction_cache.dart';

class TransactionsScreen extends StatefulWidget {
  const TransactionsScreen({super.key});

  @override
  State<TransactionsScreen> createState() => _TransactionsScreenState();
}

class _TransactionsScreenState extends State<TransactionsScreen> {
  static final DateFormat _dateFormat = DateFormat('dd/MM/yyyy • HH:mm');
  final ApiService _apiService = ApiService();
  bool _loading = true;
  String? _error;
  List<Map<String, dynamic>> _transactions = [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final token = context.read<AuthProvider>().sessionToken;
    if (token == null) return;
    final response = await _apiService.getUserTransactions(token);
    if (!mounted) return;
    setState(() {
      _loading = false;
      _error = response.ok ? null : response.errorMessage;
      _transactions = response.data ?? [];
    });
  }

  Map<String, dynamic> _itemDetails(Map<String, dynamic> transaction) {
    final catalog = transaction['item_catalog'];
    final itemId = transaction['item_id']?.toString();
    final details = catalog is Map && itemId != null ? catalog[itemId] : null;
    return details is Map ? Map<String, dynamic>.from(details) : {};
  }

  String _itemName(Map<String, dynamic> transaction) {
    final details = _itemDetails(transaction);
    return details['itemName']?.toString() ??
        transaction['item_id']?.toString() ??
        'Articolo';
  }

  String _formatDate(String? rawTimestamp) {
    if (rawTimestamp == null) return 'Data non disponibile';
    final parsed = DateTime.tryParse(rawTimestamp)?.toLocal();
    return parsed == null ? 'Data non disponibile' : _dateFormat.format(parsed);
  }

  ({String label, Color color, IconData icon}) _statusStyle(String? status) {
    switch (status) {
      case 'finalized':
        return (
          label: 'Confermata',
          color: Colors.green,
          icon: Icons.check_circle_outline,
        );
      case 'pending':
        return (
          label: 'In attesa',
          color: Colors.orange,
          icon: Icons.hourglass_empty,
        );
      case 'failed':
      case 'rejected':
        return (
          label: 'Rifiutata',
          color: Colors.red,
          icon: Icons.error_outline,
        );
      default:
        return (
          label: 'Stato sconosciuto',
          color: Colors.grey,
          icon: Icons.help_outline,
        );
    }
  }

  Widget _transactionCard(Map<String, dynamic> transaction) {
    final quantity = (transaction['quantity'] as num?)?.toInt() ?? 0;
    final status = _statusStyle(transaction['status']?.toString());
    final quantityColor = quantity >= 0 ? Colors.green[700] : Colors.red[700];
    final quantityText = quantity >= 0 ? '+$quantity' : '$quantity';

    return Card(
      elevation: 1,
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 7),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                CircleAvatar(
                  backgroundColor: status.color.withAlpha(25),
                  foregroundColor: status.color,
                  child: const Icon(Icons.inventory_2_outlined),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    _itemName(transaction),
                    style: const TextStyle(
                      fontSize: 17,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                Chip(
                  avatar: Icon(status.icon, size: 16, color: status.color),
                  label: Text(status.label),
                  labelStyle: TextStyle(
                    color: status.color,
                    fontWeight: FontWeight.w600,
                  ),
                  backgroundColor: status.color.withAlpha(20),
                  side: BorderSide.none,
                  visualDensity: VisualDensity.compact,
                ),
              ],
            ),
            const SizedBox(height: 14),
            Wrap(
              spacing: 20,
              runSpacing: 10,
              children: [
                _detail(
                  Icons.business_outlined,
                  'Marca',
                  _itemDetails(transaction)['brand']?.toString() ??
                      'Non specificata',
                ),
                _detail(
                  Icons.numbers,
                  'Quantità',
                  quantityText,
                  valueColor: quantityColor,
                ),
                _detail(
                  Icons.schedule_outlined,
                  'Data',
                  _formatDate(transaction['timestamp']?.toString()),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _detail(
    IconData icon,
    String label,
    String value, {
    Color? valueColor,
  }) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 18, color: Colors.blueGrey),
        const SizedBox(width: 6),
        Text('$label: ', style: const TextStyle(color: Colors.blueGrey)),
        Text(
          value,
          style: TextStyle(fontWeight: FontWeight.w600, color: valueColor),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final pending = context.watch<PendingTransactionCache>().transactions;
    final rows = [
      ...pending.map((entry) => {...entry.transaction, 'status': entry.status}),
      ..._transactions.where(
        (remote) =>
            !pending.any((local) => local.transId == remote['trans_id']),
      ),
    ];
    return Scaffold(
      appBar: AppBar(title: const Text('Transazioni')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
          ? Center(child: Text(_error!))
          : RefreshIndicator(
              onRefresh: _load,
              child: rows.isEmpty
                  ? ListView(
                      children: const [
                        SizedBox(height: 240),
                        Center(child: Text('Nessuna transazione')),
                      ],
                    )
                  : ListView.builder(
                      physics: const AlwaysScrollableScrollPhysics(),
                      itemCount: rows.length,
                      itemBuilder: (context, index) {
                        return _transactionCard(rows[index]);
                      },
                    ),
            ),
    );
  }
}
