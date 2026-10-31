import 'package:flutter/material.dart';
import 'package:distr_bis/auth/auth_provider.dart';
import 'package:distr_bis/inventory/barcode_scanner_screen.dart';
import 'package:distr_bis/inventory/confirmation_screen.dart';
import 'package:distr_bis/inventory/widgets/category_filter_chip.dart';
import 'package:distr_bis/inventory/widgets/inventory_list_item.dart';
import 'package:distr_bis/models/inventory_item.dart';
import 'package:distr_bis/notifications/notification_provider.dart';
import 'package:distr_bis/services/api_service.dart';
import 'package:distr_bis/services/transaction_signer.dart';
import 'package:distr_bis/transactions/pending_transaction_cache.dart';
import 'package:provider/provider.dart';
import 'package:uuid/uuid.dart';

class InventoryScreen extends StatefulWidget {
  const InventoryScreen({super.key});

  @override
  State<InventoryScreen> createState() => _InventoryScreenState();
}

class _InventoryScreenState extends State<InventoryScreen> {
  bool _isLoading = true;
  String? _searchQuery;
  final TextEditingController _searchController = TextEditingController();
  String _selectedCategory = 'Tutti';
  String? _prevBlockHash;
  final _uuid = const Uuid();

  List<InventoryItem> _inventoryItems = [];
  final List<InventoryItem> _newItems = [];
  List<String> _categories = ['Tutti'];
  final Map<String, int> _quantityChanges = {};
  bool _isApplyButtonEnabled = false;

  @override
  void initState() {
    super.initState();
    _fetchInventory();
  }

  Future<void> _fetchInventory({bool forceFullSync = false}) async {
    if (!mounted) return;
    setState(() {
      _isLoading = true;
    });

    try {
      final apiService = ApiService();
      final sessionToken = context.read<AuthProvider>().sessionToken;
      final pendingCache = context.read<PendingTransactionCache>();
      final response = await apiService.blockchainSync(
        forceFullSync ? '' : (_prevBlockHash ?? '0'),
      );

      if (response.ok) {
        final data = response.data!;
        if (sessionToken != null) {
          final transactionResponse = await apiService.getUserTransactions(
            sessionToken,
          );
          if (transactionResponse.ok && mounted) {
            pendingCache.reconcileRemoteTransactions(
              transactionResponse.data ?? <Map<String, dynamic>>[],
            );
          }
        }
        final List<dynamic> inventoryData = data['inventory'];
        setState(() {
          _inventoryItems = inventoryData
              .map((item) => InventoryItem.fromJson(item))
              .toList();
          _prevBlockHash = (data['last_hash']?.toString().isNotEmpty ?? false)
              ? data['last_hash'].toString()
              : '0';
          _categories = _extractCategories();
        });
        if (forceFullSync && mounted) {
          context.read<NotificationProvider>().ingestChainData(data);
        }
      } else {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              "Failed to load inventory: ${response.errorMessage}",
            ),
            backgroundColor: Colors.red,
          ),
        );
      }

      void applyPendingOverlay() {
        final itemsById = {for (final item in _inventoryItems) item.id: item};
        final deltas = <String, int>{};
        for (final pending
            in pendingCache.transactions) {
          final transaction = pending.transaction;
          final itemId = transaction['item_id']?.toString();
          final quantity = transaction['quantity'];
          if (itemId == null || quantity is! int) continue;
          deltas[itemId] = (deltas[itemId] ?? 0) + quantity;
          if (!itemsById.containsKey(itemId)) {
            final metadata = (transaction['item_catalog'] as Map?)?[itemId];
            if (metadata is Map) {
              itemsById[itemId] = InventoryItem(
                id: itemId,
                name: metadata['itemName']?.toString() ?? itemId,
                brand: metadata['brand']?.toString() ?? '',
                itemType: metadata['itemType']?.toString() ?? '',
                category: metadata['category']?.toString() ?? '',
                quantity: 0,
                barcode: metadata['barcode']?.toString(),
              );
            }
          }
        }
        _inventoryItems = itemsById.values.map((item) {
          final delta = deltas[item.id] ?? 0;
          return delta == 0
              ? item
              : InventoryItem(
                  id: item.id,
                  name: item.name,
                  brand: item.brand,
                  itemType: item.itemType,
                  category: item.category,
                  quantity: item.quantity + delta,
                  barcode: item.barcode,
                );
        }).toList();
      }

      applyPendingOverlay();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text("Unexpected error: $e"),
          backgroundColor: Colors.red,
        ),
      );
    } finally {
      if (mounted) {
        setState(() {
          _isLoading = false;
        });
      }
    }
  }

  Future<void> _onTopRefresh() async {
    if (!ApiService.shouldRunTopChainRefresh()) {
      return;
    }
    await _fetchInventory(forceFullSync: true);
  }

  List<String> _extractCategories() {
    final categories = _inventoryItems
        .map((item) => item.category)
        .toSet()
        .toList();
    categories.sort();
    return ['All', ...categories];
  }

  void _updateApplyButtonState() {
    setState(() {
      _isApplyButtonEnabled = _quantityChanges.values.any(
        (change) => change != 0,
      );
    });
  }

  Future<void> _showSearchDialog() async {
    _searchController.text = _searchQuery ?? '';
    return showDialog<void>(
      context: context,
      builder: (BuildContext context) {
        return AlertDialog(
          title: const Text('Search items'),
          content: TextField(
            controller: _searchController,
            decoration: const InputDecoration(
              hintText: "Item name...",
            ),
            autofocus: true,
          ),
          actions: <Widget>[
            TextButton(
              child: const Text('Cancel'),
              onPressed: () => Navigator.of(context).pop(),
            ),
            TextButton(
              child: const Text('Search'),
              onPressed: () {
                setState(() {
                  _searchQuery = _searchController.text.isEmpty
                      ? null
                      : _searchController.text;
                });
                Navigator.of(context).pop();
              },
            ),
          ],
        );
      },
    );
  }

  Future<void> _scanBarcode() async {
    final barcode = await Navigator.push<String>(
      context,
      MaterialPageRoute(builder: (context) => const BarcodeScannerScreen()),
    );

    if (!mounted || barcode == null || barcode.isEmpty) return;

    final itemIndex = _inventoryItems.indexWhere(
      (item) => item.barcode == barcode,
    );

    if (itemIndex >= 0) {
      _showQuickQuantityDialog(_inventoryItems[itemIndex]);
      return;
    }

    await _showAddItemDialog(initialBarcode: barcode);
  }

  Future<void> _showQuickQuantityDialog(InventoryItem item) async {
    final TextEditingController quantityController = TextEditingController();
    int currentChange = _quantityChanges[item.id] ?? 0;

    showDialog<void>(
      context: context,
      builder: (BuildContext context) {
        return AlertDialog(
          title: Text(item.name),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                [
                  item.brand,
                  item.itemType,
                ].where((v) => v.trim().isNotEmpty).join(', '),
              ),
              const SizedBox(height: 20),
              StatefulBuilder(
                builder: (context, setDialogState) {
                  quantityController.text = currentChange.toString();
                  return Row(
                    mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                    children: [
                      IconButton(
                        icon: const Icon(Icons.remove),
                        onPressed: () => setDialogState(() => currentChange--),
                      ),
                      Expanded(
                        child: TextField(
                          controller: quantityController,
                          keyboardType: TextInputType.number,
                          textAlign: TextAlign.center,
                          onChanged: (value) {
                            currentChange = int.tryParse(value) ?? 0;
                          },
                        ),
                      ),
                      IconButton(
                        icon: const Icon(Icons.add),
                        onPressed: () => setDialogState(() => currentChange++),
                      ),
                    ],
                  );
                },
              ),
            ],
          ),
          actions: <Widget>[
            TextButton(
              child: const Text('Cancel'),
              onPressed: () => Navigator.of(context).pop(),
            ),
            ElevatedButton(
              child: const Text('Confirm'),
              onPressed: () {
                _handleQuantityChanged(item.id, currentChange);
                Navigator.of(context).pop();
              },
            ),
          ],
        );
      },
    );
  }

  void _handleQuantityChanged(String itemId, int change) {
    setState(() {
      if (change == 0) {
        _quantityChanges.remove(itemId);
      } else {
        _quantityChanges[itemId] = change;
      }
    });
    _updateApplyButtonState();
  }

  void _applyChanges() async {
    if (!_isApplyButtonEnabled) return;

    final result = await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => ConfirmationScreen(
          quantityChanges: _quantityChanges,
          newItems: _newItems,
          allInventoryItems: _inventoryItems,
        ),
        fullscreenDialog: true,
      ),
    );

    if (result == true) {
      if (!mounted) return;
      final authProvider = Provider.of<AuthProvider>(context, listen: false);
      final sessionToken = authProvider.sessionToken ?? '';
      if (sessionToken.isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Invalid session. Please sign in again.'),
            backgroundColor: Colors.red,
          ),
        );
        return;
      }

      if (_quantityChanges.isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('There are no quantity changes to apply.'),
            backgroundColor: Colors.orange,
          ),
        );
        return;
      }

      var allFinalized = true;
      try {
        final apiService = ApiService();
        final transactionIds = <String>[];
        for (final entry in _quantityChanges.entries) {
          final change = entry.value;
          if (change == 0) continue;
          final item = _inventoryItems.firstWhere((i) => i.id == entry.key);
          final transactionId = _uuid.v4();
          final transaction = await TransactionSigner.sign({
            'flag': 'transaction',
            'client_ID': authProvider.user?.email ?? '',
            'item_id': item.id,
            'quantity': change,
            'location': 'warehouse-1',
            'timestamp': DateTime.now().toUtc().toIso8601String(),
            'trans_id': transactionId,
            'item_catalog': {
              item.id: {
                'itemName': item.name,
                'brand': item.brand,
                'itemType': item.itemType,
                'category': item.category,
                'barcode': item.barcode,
              },
            },
          }, sessionToken);
          final response = await apiService.addTransaction(
            sessionToken,
            transaction.transaction,
          );
          if (!response.ok) {
            throw Exception(response.errorMessage ?? 'Transaction rejected');
          }
          transactionIds.add(transactionId);
          if (mounted) {
            context.read<PendingTransactionCache>().add(
              transaction.transaction,
            );
          }
        }

        // Submit the complete batch before waiting for consensus so the
        // transaction threshold can be reached.
        for (final transactionId in transactionIds) {
          final finalized = await apiService.waitForTransactionFinalization(
            sessionToken,
            transactionId,
          );
          allFinalized = allFinalized && finalized;
          if (mounted && finalized) {
            context.read<PendingTransactionCache>().updateStatus(
              transactionId,
              'finalized',
            );
          }
        }

        if (!allFinalized && mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text(
                'Transactions accepted, but the block has not been confirmed yet.',
              ),
              backgroundColor: Colors.orange,
            ),
          );
        }
      } catch (e) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Failed to save changes: $e'),
            backgroundColor: Colors.red,
          ),
        );
        return;
      }

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            allFinalized
                ? 'Transactions confirmed in the block.'
                : 'Transactions added to the mempool.',
          ),
          backgroundColor: allFinalized ? Colors.green : Colors.orange,
        ),
      );
      if (allFinalized) {
        setState(() {
          _quantityChanges.clear();
          _newItems.clear();
          _isApplyButtonEnabled = false;
        });
        await _fetchInventory();
      }
    }
  }

  Future<void> _showAddItemDialog({String? initialBarcode}) async {
    final result = await showDialog<Map<String, String>>(
      context: context,
      builder: (context) => _AddItemDialog(
        currentCategories: _categories.where((c) => c != 'Tutti').toList(),
        initialBarcode: initialBarcode,
      ),
    );

    if (result != null) {
      setState(() {
        final newItem = InventoryItem(
          id: 'temp_${_uuid.v4()}',
          name: result['name']!,
          brand: result['brand']!,
          itemType: result['typeColor'] ?? '',
          category: result['category']!,
          quantity: 0,
          barcode: result['barcode'],
        );
        _newItems.add(newItem);
        _inventoryItems.add(newItem);
        _quantityChanges[newItem.id] = 1;
        _isApplyButtonEnabled = true;
        if (!_categories.contains(newItem.category)) {
          _categories = _extractCategories();
        }
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: _buildAppBar(),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : _buildInventoryContent(),
    );
  }

  AppBar _buildAppBar() {
    return AppBar(
      title: const Text(
        'Inventory',
        style: TextStyle(fontWeight: FontWeight.bold, fontSize: 32),
      ),
      actions: [
        IconButton(
          icon: const Icon(Icons.search),
          onPressed: _showSearchDialog,
          tooltip: 'Search',
        ),
        Padding(
          padding: const EdgeInsets.only(right: 16.0),
          child: ElevatedButton(
            onPressed: _isApplyButtonEnabled ? _applyChanges : null,
            style: ElevatedButton.styleFrom(
              backgroundColor: _isApplyButtonEnabled
                  ? Colors.black
                  : Colors.grey[300],
              foregroundColor: _isApplyButtonEnabled
                  ? Colors.white
                  : Colors.grey[600],
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(8),
              ),
            ),
            child: const Text('APPLY'),
          ),
        ),
      ],
    );
  }

  Widget _buildInventoryContent() {
    final filteredItems = _inventoryItems.where((item) {
      final bool categoryMatch =
          _selectedCategory == 'All' || item.category == _selectedCategory;
      final bool searchMatch =
          _searchQuery == null ||
          _searchQuery!.isEmpty ||
          item.name.toLowerCase().contains(_searchQuery!.toLowerCase());
      return categoryMatch && searchMatch;
    }).toList();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16.0, 8.0, 16.0, 8.0),
          child: Row(
            children: [
              Expanded(
                child: SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Row(
                    children: _categories
                        .map(
                          (category) => Padding(
                            padding: const EdgeInsets.only(right: 8.0),
                            child: CategoryFilterChip(
                              label: category,
                              isSelected: _selectedCategory == category,
                              onTap: () =>
                                  setState(() => _selectedCategory = category),
                            ),
                          ),
                        )
                        .toList(),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              IconButton(
                icon: const Icon(Icons.qr_code_scanner),
                onPressed: _scanBarcode,
                tooltip: 'Scan barcode',
              ),
            ],
          ),
        ),
        const Divider(thickness: 2, height: 1),
        Expanded(
          child: RefreshIndicator(
            onRefresh: _onTopRefresh,
            child: ListView.builder(
              physics: const AlwaysScrollableScrollPhysics(),
              padding: const EdgeInsets.only(bottom: 16),
              itemCount: filteredItems.length + 1,
              itemBuilder: (context, index) {
                if (index == filteredItems.length) {
                  return Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16.0,
                      vertical: 24.0,
                    ),
                    child: OutlinedButton.icon(
                      icon: const Icon(Icons.add),
                      label: const Text('Add new item'),
                      style: OutlinedButton.styleFrom(
                        padding: const EdgeInsets.symmetric(vertical: 16),
                        textStyle: const TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.bold,
                        ),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(8),
                        ),
                      ),
                      onPressed: _showAddItemDialog,
                    ),
                  );
                }

                final item = filteredItems[index];
                final itemId = item.id;
                final pendingChange = _quantityChanges[itemId] ?? 0;

                return InventoryListItem(
                  initialQuantity: item.quantity,
                  itemName: item.name,
                  itemSubtitle: [
                    item.brand,
                    item.itemType,
                  ].where((v) => v.trim().isNotEmpty).join(', '),
                  pendingChange: pendingChange,
                  onQuantityChanged: (change) =>
                      _handleQuantityChanged(itemId, change),
                );
              },
            ),
          ),
        ),
      ],
    );
  }
}

class _AddItemDialog extends StatefulWidget {
  final List<String> currentCategories;
  final String? initialBarcode;

  const _AddItemDialog({required this.currentCategories, this.initialBarcode});

  @override
  State<_AddItemDialog> createState() => _AddItemDialogState();
}

class _AddItemDialogState extends State<_AddItemDialog> {
  final _formKey = GlobalKey<FormState>();
  final _nameController = TextEditingController();
  final _brandController = TextEditingController();
  final _typeController = TextEditingController();
  final _barcodeController = TextEditingController();
  final _newCategoryController = TextEditingController();

  String? _selectedCategoryValue;
  bool _showNewCategoryField = false;

  Future<void> _scanBarcodeIntoField() async {
    final barcode = await Navigator.push<String>(
      context,
      MaterialPageRoute(builder: (context) => const BarcodeScannerScreen()),
    );

    if (!mounted || barcode == null || barcode.isEmpty) return;

    setState(() {
      _barcodeController.text = barcode;
    });
  }

  @override
  void initState() {
    super.initState();
    _barcodeController.text = widget.initialBarcode ?? '';
    if (widget.currentCategories.isNotEmpty) {
      _selectedCategoryValue = widget.currentCategories.first;
    }
  }

  @override
  Widget build(BuildContext context) {
    const String addNewCategoryValue = '__ADD_NEW__';

    return AlertDialog(
      title: const Text('Add new item'),
      content: Form(
        key: _formKey,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextFormField(
                controller: _nameController,
                decoration: const InputDecoration(labelText: 'Item name*'),
                validator: (value) =>
                    value == null || value.isEmpty ? 'Enter a name' : null,
              ),
              TextFormField(
                controller: _brandController,
                decoration: const InputDecoration(labelText: 'Brand*'),
                validator: (value) => value == null || value.isEmpty
                    ? 'Enter a brand'
                    : null,
              ),
              TextFormField(
                controller: _typeController,
                decoration: const InputDecoration(labelText: 'Type/color'),
              ),
              TextFormField(
                controller: _barcodeController,
                keyboardType: TextInputType.number,
                decoration: InputDecoration(
                  labelText: 'Barcode (ID)',
                  suffixIcon: IconButton(
                    icon: const Icon(Icons.qr_code_scanner),
                    tooltip: 'Scan barcode/QR code',
                    onPressed: _scanBarcodeIntoField,
                  ),
                ),
              ),
              DropdownButtonFormField<String>(
                initialValue: _selectedCategoryValue,
                decoration: const InputDecoration(labelText: 'Category*'),
                items: [
                  ...widget.currentCategories.map(
                    (c) => DropdownMenuItem(value: c, child: Text(c)),
                  ),
                  const DropdownMenuItem(
                    value: addNewCategoryValue,
                    child: Text('+ Nuova Categoria'),
                  ),
                ],
                onChanged: (value) {
                  setState(() {
                    _selectedCategoryValue = value;
                    _showNewCategoryField = value == addNewCategoryValue;
                  });
                },
                validator: (value) =>
                    value == null ? 'Select a category' : null,
              ),
              if (_showNewCategoryField)
                TextFormField(
                  controller: _newCategoryController,
                  decoration: const InputDecoration(
                    labelText: 'New category name',
                  ),
                  validator: (value) =>
                      _showNewCategoryField && (value == null || value.isEmpty)
                      ? 'Enter the new category name'
                      : null,
                ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        ElevatedButton(
          onPressed: () {
            if (_formKey.currentState!.validate()) {
              String finalCategory;
              if (_showNewCategoryField) {
                finalCategory = _newCategoryController.text;
              } else {
                finalCategory = _selectedCategoryValue!;
              }

              Navigator.of(context).pop({
                'name': _nameController.text,
                'brand': _brandController.text,
                'typeColor': _typeController.text,
                'barcode': _barcodeController.text,
                'category': finalCategory,
              });
            }
          },
          child: const Text('Create'),
        ),
      ],
    );
  }
}
