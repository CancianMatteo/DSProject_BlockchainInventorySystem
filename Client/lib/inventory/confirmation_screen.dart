import 'package:flutter/material.dart';
import 'package:distr_bis/models/inventory_item.dart';

class ConfirmationScreen extends StatefulWidget {
  final Map<String, int> quantityChanges;
  final List<InventoryItem> newItems;
  final List<InventoryItem> allInventoryItems;

  const ConfirmationScreen({
    super.key,
    required this.quantityChanges,
    required this.newItems,
    required this.allInventoryItems,
  });

  @override
  State<ConfirmationScreen> createState() => _ConfirmationScreenState();
}

class _ConfirmationScreenState extends State<ConfirmationScreen> {
  late List<Map<String, dynamic>> _summaryItems;

  @override
  void initState() {
    super.initState();
    _summaryItems = [];
    final newItemIds = widget.newItems.map((item) => item.id).toSet();

    // Build a unique summary keyed by item id to avoid duplicates.
    final Map<String, Map<String, dynamic>> uniqueItems = {};

    for (final item in widget.allInventoryItems) {
      final change = widget.quantityChanges[item.id] ?? 0;
      final isNew = newItemIds.contains(item.id);
      if (change != 0) {
        uniqueItems[item.id] = {'item': item, 'change': change, 'isNew': isNew};
      }
    }

    _summaryItems = uniqueItems.values.toList();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Changes summary'),
        centerTitle: true,
      ),
      body: Column(
        children: [
          Expanded(
            child: ListView.builder(
              padding: const EdgeInsets.all(16.0),
              itemCount: _summaryItems.length,
              itemBuilder: (context, index) {
                final summary = _summaryItems[index];
                final item = summary['item'] as InventoryItem;
                final change = summary['change'] as int;
                final isNew = summary['isNew'] as bool;

                final initialQuantity = item.quantity;
                final newQuantity = item.quantity + change;

                return Card(
                  margin: const EdgeInsets.only(bottom: 12.0),
                  elevation: 2,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 14.0,
                      vertical: 10.0,
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Expanded(
                              child: Text(
                                item.name,
                                style: const TextStyle(
                                  fontSize: 18,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                            ),
                            if (isNew)
                              const Text(
                                'NEW',
                                style: TextStyle(
                                  color: Colors.orange,
                                  fontWeight: FontWeight.w600,
                                  fontSize: 11,
                                ),
                              ),
                          ],
                        ),
                        Row(
                          crossAxisAlignment: CrossAxisAlignment.center,
                          children: [
                            Expanded(
                              child: Text(
                                [
                                  item.brand,
                                  item.itemType,
                                ].where((v) => v.trim().isNotEmpty).join(', '),
                                style: TextStyle(color: Colors.grey[600]),
                              ),
                            ),
                            if (!isNew)
                              Text(
                                '$initialQuantity',
                                style: const TextStyle(
                                  fontSize: 18,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                            if (!isNew)
                              const Icon(
                                Icons.arrow_forward,
                                color: Colors.grey,
                                size: 20,
                              ),
                            Text(
                              '$newQuantity',
                              style: TextStyle(
                                fontSize: 22,
                                fontWeight: FontWeight.bold,
                                color: isNew || change > 0
                                    ? Colors.green
                                    : Colors.red,
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                );
              },
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(16.0),
            child: Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: () => Navigator.of(
                      context,
                    ).pop(false), // Return a cancellation result.
                    style: OutlinedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(vertical: 16),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                    child: const Text('CANCEL'),
                  ),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: ElevatedButton(
                    onPressed: () => Navigator.of(context).pop(true),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.black,
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(vertical: 16),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                    child: const Text('CONFIRM'),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
