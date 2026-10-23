import 'package:flutter/foundation.dart';
import 'package:distr_bis/notifications/notification_model.dart';
import 'package:distr_bis/services/api_service.dart';

class NotificationProvider with ChangeNotifier {
  final ApiService _apiService = ApiService();
  final List<AppNotification> _notifications = [];
  bool _isLoading = false;

  List<AppNotification> get notifications => _notifications;
  bool get isLoading => _isLoading;

  bool get hasUnreadNotifications => _notifications.any((n) => !n.isRead);

  void ingestChainData(Map<String, dynamic> chainData) {
    final existingReadById = <String, bool>{
      for (final n in _notifications) n.id: n.isRead,
    };

    final List<dynamic> rawBlocks =
        chainData['missing_blocks'] as List<dynamic>? ?? <dynamic>[];
    final blocks = rawBlocks.whereType<Map<String, dynamic>>().toList()
      ..sort(
        (a, b) => ((a['n_block'] as num?)?.toInt() ?? 0).compareTo(
          (b['n_block'] as num?)?.toInt() ?? 0,
        ),
      );

    final inventoryQty = <String, int>{};
    final inventoryName = <String, String>{};
    final localNotifications = <AppNotification>[];

    for (final block in blocks) {
      final blockHash = (block['block_hash'] ?? '').toString();
      final blockNumber = (block['n_block'] as num?)?.toInt() ?? 0;
      final author = (block['author_email'] ?? 'unknown').toString();
      final when =
          DateTime.tryParse((block['datetime'] ?? '').toString()) ??
          DateTime.now();

      final Map<String, dynamic> changes = Map<String, dynamic>.from(
        block['changes'] ?? {},
      );
      final Map<String, dynamic> itemCatalog = Map<String, dynamic>.from(
        block['item_catalog'] ?? {},
      );

      for (final entry in changes.entries) {
        final itemId = entry.key;
        final delta = (entry.value as num?)?.toInt() ?? 0;
        if (delta == 0) continue;

        final item = itemCatalog[itemId] as Map<String, dynamic>?;
        final itemName = item?['itemName']?.toString() ?? itemId;
        final prevQty = inventoryQty[itemId] ?? 0;
        final nextQty = prevQty + delta;
        if (nextQty < 0) {
          continue;
        }
        inventoryQty[itemId] = nextQty;
        inventoryName[itemId] = itemName;

        final changeId = 'local-change-$blockHash-$itemId';
        final signedDelta = delta > 0 ? '+$delta' : '$delta';
        localNotifications.add(
          AppNotification(
            id: changeId,
            category: 'inventory',
            message: '$author $signedDelta $itemName',
            details: {
              'event': delta > 0 ? 'CHAIN_ITEM_ADDITION' : 'CHAIN_ITEM_REMOVAL',
              'author_email': author,
              'item_name': itemName,
              'delta': delta,
              'n_block': blockNumber,
              'block_hash': blockHash,
            },
            timestamp: when,
          ),
        );

        if (delta < 0 && nextQty < 3) {
          localNotifications.add(
            AppNotification(
              id: 'local-warning-$blockHash-$itemId',
              category: 'warning',
              message: 'Warning scarsita: $itemName (qty $nextQty)',
              details: {
                'event': 'LOW_STOCK_AFTER_DECREASE',
                'author_email': author,
                'item_name': inventoryName[itemId] ?? itemName,
                'quantity': nextQty,
                'delta': delta,
                'n_block': blockNumber,
                'block_hash': blockHash,
              },
              timestamp: when,
            ),
          );
        }
      }
    }

    final nonLocal = _notifications
        .where((n) => !n.id.startsWith('local-'))
        .toList();
    _notifications
      ..clear()
      ..addAll(nonLocal)
      ..addAll(localNotifications);

    for (final n in _notifications) {
      n.isRead = existingReadById[n.id] ?? false;
    }

    _notifications.sort((a, b) => b.timestamp.compareTo(a.timestamp));
    notifyListeners();
  }

  Future<void> fetchNotifications(String sessionToken) async {
    if (sessionToken.isEmpty) return;
    _isLoading = true;
    notifyListeners();

    final response = await _apiService.getNotifications(sessionToken);
    if (response.ok && response.data != null) {
      final existingReadById = <String, bool>{
        for (final n in _notifications) n.id: n.isRead,
      };

      final local = _notifications
          .where((n) => n.id.startsWith('local-'))
          .toList();
      final raw = response.data!['notifications'] as List<dynamic>? ?? [];
      final serverSecurity = raw
          .whereType<Map<String, dynamic>>()
          .map(AppNotification.fromServer)
          .where((n) => n.category.toLowerCase() == 'security')
          .toList();

      _notifications
        ..clear()
        ..addAll(local)
        ..addAll(serverSecurity)
        ..sort((a, b) => b.timestamp.compareTo(a.timestamp));

      for (final n in _notifications) {
        n.isRead = existingReadById[n.id] ?? false;
      }
    }

    _isLoading = false;
    notifyListeners();
  }

  void markAsRead(String id) {
    bool changed = false;
    for (final n in _notifications) {
      if (n.id == id && !n.isRead) {
        n.isRead = true;
        changed = true;
        break;
      }
    }
    if (!changed) return;
    notifyListeners();
  }

  void markAllAsRead() {
    bool changed = false;
    for (final n in _notifications) {
      if (!n.isRead) {
        n.isRead = true;
        changed = true;
      }
    }
    if (!changed) return;
    notifyListeners();
  }
}
