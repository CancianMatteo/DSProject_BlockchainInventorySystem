class AppNotification {
  final String id;
  final String category;
  final String message;
  final Map<String, dynamic> details;
  final DateTime timestamp;
  bool isRead;

  AppNotification({
    required this.id,
    required this.category,
    required this.message,
    required this.details,
    required this.timestamp,
    this.isRead = false,
  });

  factory AppNotification.fromServer(Map<String, dynamic> json) {
    return AppNotification(
      id: json['id'].toString(),
      category: (json['category'] ?? 'info').toString(),
      message: (json['message'] ?? '').toString(),
      details: Map<String, dynamic>.from(json['details'] ?? {}),
      timestamp:
          DateTime.tryParse((json['created_at'] ?? '').toString()) ??
          DateTime.now(),
      isRead: false,
    );
  }
}
