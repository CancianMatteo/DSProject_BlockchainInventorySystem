import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart' hide Block;
import 'package:myapp/models/block.dart';
import 'package:myapp/notifications/notification_provider.dart';
import 'package:myapp/services/api_service.dart';
import 'package:provider/provider.dart';

class ChainLogScreen extends StatefulWidget {
  const ChainLogScreen({super.key});

  @override
  State<ChainLogScreen> createState() => _ChainLogScreenState();
}

class _ChainLogScreenState extends State<ChainLogScreen> {
  String? _searchQuery;
  final TextEditingController _searchController = TextEditingController();
  final ApiService _apiService = ApiService();
  bool _isLoading = true;
  String? _error;
  List<Block> _blocks = [];

  @override
  void initState() {
    super.initState();
    _loadBlocks();
  }

  Future<void> _loadBlocks() async {
    setState(() {
      _isLoading = true;
      _error = null;
    });

    final response = await _apiService.checkChainSync('');
    if (!response.ok || response.data == null) {
      if (!mounted) return;
      setState(() {
        _isLoading = false;
        _error = response.errorMessage ?? 'Errore caricamento transazioni';
      });
      return;
    }

    final missing = response.data!['missing_blocks'] as List<dynamic>? ?? [];
    if (mounted) {
      context.read<NotificationProvider>().ingestChainData(response.data!);
    }
    final blocks =
        missing.whereType<Map<String, dynamic>>().map(Block.fromJson).toList()
          ..sort((a, b) => b.nBlock.compareTo(a.nBlock));

    if (!mounted) return;
    setState(() {
      _blocks = blocks;
      _isLoading = false;
    });
  }

  Future<void> _onTopRefresh() async {
    if (!ApiService.shouldRunTopChainRefresh()) {
      return;
    }
    await _loadBlocks();
  }

  Future<void> _showSearchDialog() async {
    _searchController.text = _searchQuery ?? '';
    return showDialog<void>(
      context: context,
      builder: (BuildContext context) {
        return AlertDialog(
          title: const Text('Cerca Transazione'),
          content: TextField(
            controller: _searchController,
            decoration: const InputDecoration(hintText: "Autore o oggetto..."),
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

  String _formatTimestamp(DateTime timestamp) {
    final now = DateTime.now();
    final difference = now.difference(timestamp);
    if (difference.inDays > 0) {
      return '${difference.inDays}g fa';
    }
    if (difference.inHours > 0) {
      return '${difference.inHours}h fa';
    }
    if (difference.inMinutes > 0) {
      return '${difference.inMinutes}min fa';
    }
    return 'Poco fa';
  }

  String _buildSummary(Block block) {
    if (block.changes.isEmpty) return 'Nessuna modifica';
    final parts = <String>[];
    block.changes.forEach((itemId, delta) {
      final item = block.itemCatalog[itemId] as Map<String, dynamic>?;
      final itemName = item?['itemName']?.toString() ?? itemId;
      final sign = delta >= 0 ? '+' : '';
      parts.add('$itemName: $sign$delta');
    });
    return parts.join(' • ');
  }

  @override
  Widget build(BuildContext context) {
    final filteredBlocks = _blocks.where((block) {
      if (_searchQuery == null || _searchQuery!.isEmpty) {
        return true;
      }
      final needle = _searchQuery!.toLowerCase();
      return block.authorEmail.toLowerCase().contains(needle) ||
          _buildSummary(block).toLowerCase().contains(needle);
    }).toList();

    return Scaffold(
      appBar: AppBar(
        title: const Text('Storico Transazioni'),
        centerTitle: true,
        actions: [
          IconButton(
            icon: const Icon(Icons.search),
            onPressed: _showSearchDialog,
            tooltip: 'Cerca',
          ),
        ],
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
          ? Center(
              child: Text(_error!, style: const TextStyle(color: Colors.red)),
            )
          : RefreshIndicator(
              onRefresh: _onTopRefresh,
              child: ListView.builder(
                physics: const AlwaysScrollableScrollPhysics(),
                itemCount: filteredBlocks.length,
                itemBuilder: (context, index) {
                  final block = filteredBlocks[index];
                  return Card(
                    margin: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 8,
                    ),
                    child: ListTile(
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 10,
                      ),
                      title: Text(
                        'Blocco #${block.nBlock}',
                        style: const TextStyle(
                          fontWeight: FontWeight.w700,
                          color: Colors.black,
                        ),
                      ),
                      subtitle: Text(
                        '${block.authorEmail} ● ${_formatTimestamp(block.datetime)}\n'
                        '${_buildSummary(block)}',
                        style: const TextStyle(
                          color: Colors.black,
                          fontWeight: FontWeight.normal,
                        ),
                      ),
                      isThreeLine: true,
                      onTap: () => GoRouter.of(
                        context,
                      ).go('/chain-log/${block.nBlock}', extra: block),
                    ),
                  );
                },
              ),
            ),
    );
  }
}
