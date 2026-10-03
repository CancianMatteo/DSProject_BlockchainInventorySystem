import 'package:flutter/material.dart';

class InventoryListItem extends StatefulWidget {
  final int initialQuantity;
  final String itemName;
  final String itemSubtitle;
  final Function(int) onQuantityChanged;
  final int pendingChange;

  const InventoryListItem({
    super.key,
    required this.initialQuantity,
    required this.itemName,
    required this.itemSubtitle,
    required this.onQuantityChanged,
    this.pendingChange = 0,
  });

  @override
  State<InventoryListItem> createState() => _InventoryListItemState();
}

class _InventoryListItemState extends State<InventoryListItem> {
  late int _quantityChange;

  @override
  void initState() {
    super.initState();
    _quantityChange = widget.pendingChange;
  }

  @override
  void didUpdateWidget(covariant InventoryListItem oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.pendingChange != oldWidget.pendingChange) {
      setState(() {
        _quantityChange = widget.pendingChange;
      });
    }
  }

  void _increment() {
    setState(() {
      _quantityChange++;
      widget.onQuantityChanged(_quantityChange);
    });
  }

  void _decrement() {
    setState(() {
      _quantityChange--;
      widget.onQuantityChanged(_quantityChange);
    });
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 8.0),
      child: Row(
        children: [
          // Quantity
          Container(
            width: 40,
            alignment: Alignment.center,
            child: Text(
              widget.initialQuantity.toString(),
              style: TextStyle(
                fontSize: 24,
                fontWeight: FontWeight.bold,
                color: widget.initialQuantity == 0
                    ? Colors.red
                    : (widget.initialQuantity < 5
                          ? Colors.orange
                          : Colors.green),
              ),
            ),
          ),
          const SizedBox(width: 16),
          // Item Name and Type
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  widget.itemName,
                  style: const TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.normal,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  widget.itemSubtitle,
                  style: const TextStyle(fontSize: 16, color: Colors.black54),
                ),
              ],
            ),
          ),
          // Spacer to push controls to the right
          const Spacer(),
          // Quantity Change Controls
          SizedBox(
            width: 50,
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                // Up Arrow
                InkWell(
                  onTap: _increment,
                  child: const Icon(Icons.arrow_drop_up, size: 30),
                ),
                // Pending Change Indicator
                if (_quantityChange != 0)
                  Text(
                    _quantityChange > 0
                        ? '+$_quantityChange'
                        : _quantityChange.toString(),
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.bold,
                      color: _quantityChange > 0 ? Colors.green : Colors.red,
                    ),
                  ),
                // Down Arrow
                InkWell(
                  onTap: _decrement,
                  child: const Icon(Icons.arrow_drop_down, size: 30),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
