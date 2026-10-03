import 'package:flutter/material.dart';
import 'package:myapp/auth/auth_provider.dart';
import 'package:myapp/notifications/notification_provider.dart';
import 'package:myapp/services/api_service.dart';
import 'package:provider/provider.dart';
import 'package:timeago/timeago.dart' as timeago;

class NotificationsScreen extends StatefulWidget {
  const NotificationsScreen({super.key});

  @override
  State<NotificationsScreen> createState() => _NotificationsScreenState();
}

class _NotificationsScreenState extends State<NotificationsScreen> {
  final ApiService _apiService = ApiService();

  Future<void> _syncChainDataToNotifications() async {
    final chainResponse = await _apiService.checkChainSync('');
    if (chainResponse.ok && chainResponse.data != null && mounted) {
      context.read<NotificationProvider>().ingestChainData(chainResponse.data!);
    }
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      final token = context.read<AuthProvider>().sessionToken ?? '';
      await _syncChainDataToNotifications();
      if (!mounted) return;
      await context.read<NotificationProvider>().fetchNotifications(token);
    });
  }

  Future<void> _onTopRefresh(String token) async {
    if (ApiService.shouldRunTopChainRefresh()) {
      await _syncChainDataToNotifications();
    }
    await context.read<NotificationProvider>().fetchNotifications(token);
  }

  Color _categoryColor(String category) {
    switch (category.toLowerCase()) {
      case 'warning':
        return Colors.orange;
      case 'security':
        return Colors.red;
      case 'inventory':
        return Colors.blue;
      default:
        return Colors.grey;
    }
  }

  String _categoryLabel(String category) {
    switch (category.toLowerCase()) {
      case 'warning':
        return 'Warning';
      case 'security':
        return 'Security';
      case 'inventory':
        return 'Transazione';
      default:
        return category;
    }
  }

  String _buildSubtitle(Map<String, dynamic> details) {
    final event = details['event']?.toString() ?? '';
    if (event == 'CHAIN_ITEM_ADDITION' || event == 'CHAIN_ITEM_REMOVAL') {
      final author = details['author_email']?.toString() ?? 'utente';
      final item = details['item_name']?.toString() ?? 'item';
      final delta = details['delta']?.toString() ?? '?';
      final nBlock = details['n_block']?.toString() ?? '?';
      return '$author • $item ($delta) • Blocco #$nBlock';
    }
    if (event == 'LOW_STOCK_AFTER_DECREASE') {
      final item = details['item_name']?.toString() ?? 'item';
      final qty = details['quantity']?.toString() ?? '?';
      final nBlock = details['n_block']?.toString() ?? '?';
      return '$item sotto soglia (qty $qty) • Blocco #$nBlock';
    }
    if (event == 'OTP_RESET_EMAIL_SENT') {
      final target = details['target_email']?.toString() ?? 'email sconosciuta';
      return 'Inviata email OTP reset a $target';
    }
    return details.toString();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text(
          'Notifiche',
          style: TextStyle(fontWeight: FontWeight.bold, fontSize: 32),
        ),
        centerTitle: false,
        actions: [
          IconButton(
            icon: const Icon(Icons.done_all),
            onPressed: () {
              context.read<NotificationProvider>().markAllAsRead();
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(
                  content: Text(
                    'Tutte le notifiche sono state segnate come lette (grigie).',
                  ),
                  duration: Duration(seconds: 2),
                ),
              );
            },
            tooltip: 'Segna tutto come letto',
          ),
        ],
      ),
      body: Consumer<NotificationProvider>(
        builder: (context, provider, child) {
          final notifications = provider.notifications;
          final token = context.read<AuthProvider>().sessionToken ?? '';

          if (provider.isLoading) {
            return const Center(child: CircularProgressIndicator());
          }

          if (notifications.isEmpty) {
            return const Center(
              child: Text(
                'Nessuna notifica.',
                style: TextStyle(fontSize: 18, color: Colors.grey),
              ),
            );
          }

          return RefreshIndicator(
            onRefresh: () async {
              await _onTopRefresh(token);
            },
            child: ListView.separated(
              physics: const AlwaysScrollableScrollPhysics(),
              padding: const EdgeInsets.symmetric(vertical: 8.0),
              itemCount: notifications.length,
              separatorBuilder: (context, index) => const Divider(height: 1),
              itemBuilder: (context, index) {
                final notification = notifications[index];
                final categoryColor = _categoryColor(notification.category);
                final subtitle = _buildSubtitle(notification.details);
                final subtitleColor = notification.isRead
                    ? Colors.grey
                    : Colors.black87;
                final effectiveCategoryColor = notification.isRead
                    ? Colors.grey
                    : categoryColor;

                return ListTile(
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: 16.0,
                    vertical: 8.0,
                  ),
                  onTap: () {
                    context.read<NotificationProvider>().markAsRead(
                      notification.id,
                    );
                  },
                  subtitle: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const SizedBox(height: 4),
                      Wrap(
                        spacing: 8,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        children: [
                          Text(
                            _categoryLabel(notification.category),
                            style: TextStyle(
                              fontSize: 12,
                              color: effectiveCategoryColor,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                          Text(
                            subtitle,
                            style: TextStyle(color: subtitleColor),
                          ),
                        ],
                      ),
                      const SizedBox(height: 4),
                      Text(
                        timeago.format(notification.timestamp, locale: 'it'),
                        style: TextStyle(fontSize: 12, color: Colors.grey[500]),
                      ),
                    ],
                  ),
                  isThreeLine: true,
                );
              },
            ),
          );
        },
      ),
    );
  }
}
