class Notification {
  final int id;
  final String category;
  final String message;
  final Map<String, dynamic> details;
  final DateTime createdAt;

  Notification({
    required this.id,
    required this.category,
    required this.message,
    required this.details,
    required this.createdAt,
  });

  factory Notification.fromJson(Map<String, dynamic> json) {
    return Notification(
      id: json['id'],
      category: json['category'],
      message: json['message'],
      details: json['details'],
      createdAt: DateTime.parse(json['created_at']),
    );
  }
}
