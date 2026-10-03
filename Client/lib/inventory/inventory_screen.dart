import 'package:flutter/material.dart';
import 'package:myapp/auth/auth_provider.dart';
import 'package:myapp/inventory/barcode_scanner_screen.dart';
import 'package:myapp/inventory/confirmation_screen.dart';
import 'package:myapp/inventory/widgets/category_filter_chip.dart';
import 'package:myapp/inventory/widgets/inventory_list_item.dart';
import 'package:myapp/models/api_response.dart' show ApiResponse;
import 'package:myapp/models/inventory_item.dart';
import 'package:myapp/notifications/notification_provider.dart';
import 'package:myapp/services/api_service.dart';
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
      final response = await apiService.checkChainSync(
        forceFullSync ? '' : (_prevBlockHash ?? '0'),
      );

      if (response.ok) {
        final data = response.data!;
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
              "Errore durante il caricamento dell'inventario: ${response.errorMessage}",
            ),
            backgroundColor: Colors.red,
          ),
        );
      }
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text("Errore imprevisto: $e"),
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
    return ['Tutti', ...categories];
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
          title: const Text('Cerca Articolo'),
          content: TextField(
            controller: _searchController,
            decoration: const InputDecoration(
              hintText: "Nome dell'articolo...",
            ),
            autofocus: true,
          ),
          actions: <Widget>[
            TextButton(
              child: const Text('Annulla'),
              onPressed: () => Navigator.of(context).pop(),
            ),
            TextButton(
              child: const Text('Cerca'),
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
              child: const Text('Annulla'),
              onPressed: () => Navigator.of(context).pop(),
            ),
            ElevatedButton(
              child: const Text('Conferma'),
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
      const authorSign = 'signature'; // TODO: Implement cryptographic signature

      if (sessionToken.isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Sessione non valida: effettua di nuovo il login'),
            backgroundColor: Colors.red,
          ),
        );
        return;
      }

      final Map<String, int> changes = {};
      _quantityChanges.forEach((itemId, change) {
        if (change != 0) {
          changes[itemId] = change;
        }
      });

      final Map<String, Map<String, String?>> itemCatalog = {};
      for (final entry in changes.entries) {
        final itemId = entry.key;
        try {
          final item = _inventoryItems.firstWhere((i) => i.id == itemId);
          itemCatalog[itemId] = {
            'itemName': item.name,
            'brand': item.brand,
            'itemType': item.itemType,
            'category': item.category,
            'barcode': item.barcode,
          };
        } catch (_) {
          // Ignore dangling changes for unknown ids.
        }
      }

      if (changes.isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Nessuna variazione di quantita da applicare.'),
            backgroundColor: Colors.orange,
          ),
        );
        return;
      }

      ApiResponse<Map<String, dynamic>> response;
      try {
        final apiService = ApiService();
        response = await apiService.addBlock(
          sessionToken,
          (_prevBlockHash?.isNotEmpty ?? false) ? _prevBlockHash! : '',
          changes,
          itemCatalog,
          authorSign,
        );
      } catch (e) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Errore durante il salvataggio: $e'),
            backgroundColor: Colors.red,
          ),
        );
        return;
      }

      if (!mounted) return;

      if (response.ok) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Modifiche applicate con successo!'),
            backgroundColor: Colors.green,
          ),
        );
        setState(() {
          _quantityChanges.clear();
          _newItems.clear();
          _isApplyButtonEnabled = false;
        });
        _fetchInventory();
      } else {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              "Errore durante l'applicazione delle modifiche: ${response.errorMessage}",
            ),
            backgroundColor: Colors.red,
          ),
        );
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
        if (!_categories.contains(newItem.category)) {
          _categories = _extractCategories();
        }
      });
      _updateApplyButtonState();
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
        'Inventario',
        style: TextStyle(fontWeight: FontWeight.bold, fontSize: 32),
      ),
      actions: [
        IconButton(
          icon: const Icon(Icons.search),
          onPressed: _showSearchDialog,
          tooltip: 'Cerca',
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
            child: const Text('APPLICA'),
          ),
        ),
      ],
    );
  }

  Widget _buildInventoryContent() {
    final filteredItems = _inventoryItems.where((item) {
      final bool categoryMatch =
          _selectedCategory == 'Tutti' || item.category == _selectedCategory;
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
                tooltip: 'Scannerizza',
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
                      label: const Text('Aggiungi Nuovo Elemento'),
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
      title: const Text('Aggiungi Nuovo Articolo'),
      content: Form(
        key: _formKey,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextFormField(
                controller: _nameController,
                decoration: const InputDecoration(labelText: 'Nome Oggetto*'),
                validator: (value) =>
                    value == null || value.isEmpty ? 'Inserisci un nome' : null,
              ),
              TextFormField(
                controller: _brandController,
                decoration: const InputDecoration(labelText: 'Marca*'),
                validator: (value) => value == null || value.isEmpty
                    ? 'Inserisci una marca'
                    : null,
              ),
              TextFormField(
                controller: _typeController,
                decoration: const InputDecoration(labelText: 'Tipo/Colore'),
              ),
              TextFormField(
                controller: _barcodeController,
                keyboardType: TextInputType.number,
                decoration: InputDecoration(
                  labelText: 'Barcode(ID)',
                  suffixIcon: IconButton(
                    icon: const Icon(Icons.qr_code_scanner),
                    tooltip: 'Scansiona barcode/QR',
                    onPressed: _scanBarcodeIntoField,
                  ),
                ),
              ),
              DropdownButtonFormField<String>(
                initialValue: _selectedCategoryValue,
                decoration: const InputDecoration(labelText: 'Categoria*'),
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
                    value == null ? 'Seleziona una categoria' : null,
              ),
              if (_showNewCategoryField)
                TextFormField(
                  controller: _newCategoryController,
                  decoration: const InputDecoration(
                    labelText: 'Nome Nuova Categoria',
                  ),
                  validator: (value) =>
                      _showNewCategoryField && (value == null || value.isEmpty)
                      ? 'Inserisci il nome della nuova categoria'
                      : null,
                ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Annulla'),
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
          child: const Text('Crea'),
        ),
      ],
    );
  }
}
