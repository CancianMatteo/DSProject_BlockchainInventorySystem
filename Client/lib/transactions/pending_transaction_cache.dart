import 'package:flutter/foundation.dart';

class PendingTransaction {
  final String transId;
  final Map<String, dynamic> transaction;
  String status;

  PendingTransaction({
    required this.transId,
    required this.transaction,
    this.status = 'pending',
  });
}

class PendingTransactionCache extends ChangeNotifier {
  final Map<String, PendingTransaction> _transactions = {};

  List<PendingTransaction> get transactions =>
      List.unmodifiable(_transactions.values);

  void add(Map<String, dynamic> transaction) {
    final transId = transaction['trans_id']?.toString();
    if (transId == null || transId.isEmpty) return;
    _transactions[transId] = PendingTransaction(
      transId: transId,
      transaction: Map<String, dynamic>.from(transaction),
    );
    notifyListeners();
  }

  void updateStatus(String transId, String status) {
    final transaction = _transactions[transId];
    if (transaction == null) return;
    transaction.status = status;
    if (status == 'finalized' || status == 'rejected') {
      _transactions.remove(transId);
    }
    notifyListeners();
  }

  void reconcileRemoteTransactions(List<Map<String, dynamic>> remote) {
    var changed = false;
    for (final transaction in remote) {
      final transId = transaction['trans_id']?.toString();
      if (transId == null) continue;
      final status = transaction['status']?.toString() ?? 'pending';
      final cached = _transactions[transId];
      if (cached == null) continue;
      if (status == 'finalized' || status == 'rejected') {
        _transactions.remove(transId);
        changed = true;
      } else if (cached.status != status) {
        cached.status = status;
        changed = true;
      }
    }
    if (changed) notifyListeners();
  }
}
