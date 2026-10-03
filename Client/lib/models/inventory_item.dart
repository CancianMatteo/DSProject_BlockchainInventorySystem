class InventoryItem {
  String id;
  String name;
  String brand;
  String itemType;
  String category;
  int quantity;
  String? barcode;

  InventoryItem({
    required this.id,
    required this.name,
    required this.brand,
    required this.itemType,
    required this.category,
    required this.quantity,
    this.barcode,
  });

  factory InventoryItem.fromJson(Map<String, dynamic> json) {
    return InventoryItem(
      id: (json['id'] ?? '').toString(),
      name: (json['itemName'] ?? '').toString(),
      brand: (json['brand'] ?? '').toString(),
      itemType: (json['itemType'] ?? '').toString(),
      category: (json['category'] ?? '').toString(),
      quantity: (json['quantity'] as num?)?.toInt() ?? 0,
      barcode: json['barcode']?.toString(),
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'itemName': name,
      'brand': brand,
      'itemType': itemType,
      'category': category,
      'quantity': quantity,
      'barcode': barcode,
    };
  }
}
