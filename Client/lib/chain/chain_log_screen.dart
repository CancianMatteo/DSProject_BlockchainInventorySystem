import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart' hide Block;
import 'package:distr_bis/models/block.dart';
import 'package:distr_bis/services/api_service.dart';

class ChainLogScreen extends StatefulWidget {
  const ChainLogScreen({super.key});

  @override
  State<ChainLogScreen> createState() => _ChainLogScreenState();
}

class _ChainLogScreenState extends State<ChainLogScreen> {
  static const int _pageSize = 50;

  String? _searchQuery;
  final TextEditingController _searchController = TextEditingController();
  final ScrollController _scrollController = ScrollController();
  final ApiService _apiService = ApiService();
  bool _isLoading = false;
  bool _isLoadingMore = false;
  bool _hasMore = true;
  int? _nextBeforeNBlock;
  String? _error;
  String? _loadMoreError;
  List<Block> _blocks = [];

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_loadMoreWhenNearEnd);
    _loadBlocks();
  }

  @override
  void dispose() {
    _scrollController
      ..removeListener(_loadMoreWhenNearEnd)
      ..dispose();
    _searchController.dispose();
    super.dispose();
  }

  void _loadMoreWhenNearEnd() {
    if (!_scrollController.hasClients) return;
    if (_scrollController.position.extentAfter < 300) {
      _loadBlocks();
    }
  }

  Future<void> _loadBlocks({bool reset = false}) async {
    if (_isLoading || _isLoadingMore || (!reset && !_hasMore)) return;
    final isFirstPage = reset || _blocks.isEmpty;
    final beforeNBlock = reset ? null : _nextBeforeNBlock;
    if (!reset && !isFirstPage && beforeNBlock == null) return;

    setState(() {
      if (isFirstPage) {
        _isLoading = true;
        _error = null;
      } else {
        _isLoadingMore = true;
        _loadMoreError = null;
      }
      if (reset) {
        _hasMore = true;
        _nextBeforeNBlock = null;
      }
    });

    final response = await _apiService.getChainHistory(
      limit: _pageSize,
      beforeNBlock: beforeNBlock,
    );
    if (!response.ok || response.data == null) {
      if (!mounted) return;
      setState(() {
        final message =
            response.errorMessage ?? 'Failed to load transactions';
        if (isFirstPage) {
          _isLoading = false;
          _error = message;
        } else {
          _isLoadingMore = false;
          _loadMoreError = message;
        }
      });
      return;
    }

    final data = response.data!;
    final rawBlocks = data['blocks'] as List<dynamic>? ?? [];
    final blocks = rawBlocks
        .whereType<Map<String, dynamic>>()
        .map(Block.fromJson)
        .toList();

    if (!mounted) return;
    setState(() {
      if (isFirstPage) {
        _blocks = blocks;
      } else {
        _blocks.addAll(blocks);
      }
      _hasMore = data['has_more'] == true;
      _nextBeforeNBlock = (data['next_before_n_block'] as num?)?.toInt();
      _isLoading = false;
      _isLoadingMore = false;
      _loadMoreError = null;
    });
  }

  Future<void> _onTopRefresh() async {
    if (!ApiService.shouldRunTopChainRefresh()) {
      return;
    }
    await _loadBlocks(reset: true);
  }

  Future<void> _showSearchDialog() async {
    _searchController.text = _searchQuery ?? '';
    return showDialog<void>(
      context: context,
      builder: (BuildContext context) {
        return AlertDialog(
          title: const Text('Search transactions'),
          content: TextField(
            controller: _searchController,
            decoration: const InputDecoration(hintText: "Author or item..."),
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

  String _formatTimestamp(DateTime timestamp) {
    final now = DateTime.now();
    final difference = now.difference(timestamp);
    if (difference.inDays > 0) {
      return '${difference.inDays}d ago';
    }
    if (difference.inHours > 0) {
      return '${difference.inHours}h ago';
    }
    if (difference.inMinutes > 0) {
      return '${difference.inMinutes}m ago';
    }
    return 'Just now';
  }

  String _buildSummary(Block block) {
    if (block.changes.isEmpty) return 'No changes';
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
        title: const Text('Blockchain'),
        centerTitle: true,
        actions: [
          IconButton(
            icon: const Icon(Icons.search),
            onPressed: _showSearchDialog,
            tooltip: 'Search',
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
                itemCount:
                    filteredBlocks.length +
                    (_hasMore || _isLoadingMore || _loadMoreError != null
                        ? 1
                        : 0),
                itemBuilder: (context, index) {
                  if (index >= filteredBlocks.length) {
                    if (_loadMoreError != null) {
                      return TextButton(
                        onPressed: _loadBlocks,
                        child: Text('Retry: $_loadMoreError'),
                      );
                    }
                    if (_isLoadingMore) {
                      return const Padding(
                        padding: EdgeInsets.all(16),
                        child: Center(child: CircularProgressIndicator()),
                      );
                    }
                    return _hasMore
                        ? TextButton(
                            onPressed: _loadBlocks,
                            child: const Text('Load previous blocks'),
                          )
                        : const SizedBox.shrink();
                  }
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
                        'Block #${block.nBlock}',
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
                      ).go('/blockchain/${block.nBlock}', extra: block),
                    ),
                  );
                },
                controller: _scrollController,
              ),
            ),
    );
  }
}
