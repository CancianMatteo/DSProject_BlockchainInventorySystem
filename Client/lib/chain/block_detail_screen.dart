import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart' hide Block;
import 'package:distr_bis/models/block.dart';

class BlockDetailScreen extends StatelessWidget {
  final String blockId;
  final Block? block;

  const BlockDetailScreen({super.key, required this.blockId, this.block});

  String _formatChanges(Block b) {
    if (b.changes.isEmpty) return 'Nessuna modifica';
    final lines = <String>[];
    b.changes.forEach((itemId, delta) {
      final item = b.itemCatalog[itemId] as Map<String, dynamic>?;
      final itemName = item?['itemName']?.toString() ?? itemId;
      final sign = delta >= 0 ? '+' : '';
      lines.add('$itemName: $sign$delta');
    });
    return lines.join('\n');
  }

  @override
  Widget build(BuildContext context) {
    final data = block;
    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () => context.pop(),
          tooltip: 'Torna allo storico',
        ),
        title: Text('Dettaglio Blocco #$blockId'),
      ),
      body: data == null
          ? const Center(
              child: Text(
                'Dettaglio non disponibile, apri dal log transazioni.',
              ),
            )
          : Padding(
              padding: const EdgeInsets.all(16.0),
              child: ListView(
                children: [
                  _buildDetailCard('Autore', data.authorEmail),
                  _buildDetailCard(
                    'Data e Ora',
                    data.datetime.toLocal().toString(),
                  ),
                  _buildDetailCard('Modifiche', _formatChanges(data)),
                  _buildDetailCard(
                    'Firma Autore',
                    data.authorSign ?? 'N/A',
                    isCode: true,
                  ),
                  _buildDetailCard(
                    'Firma Server',
                    data.serverSign,
                    isCode: true,
                  ),
                  _buildDetailCard('Hash Blocco', data.blockHash, isCode: true),
                  _buildDetailCard(
                    'Hash Blocco Precedente',
                    data.prevBlockHash ?? 'GENESIS',
                    isCode: true,
                  ),
                ],
              ),
            ),
    );
  }

  Widget _buildDetailCard(String title, String content, {bool isCode = false}) {
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              title,
              style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
            ),
            const SizedBox(height: 8),
            Text(
              content,
              style: isCode
                  ? const TextStyle(
                      fontFamily: 'monospace',
                      backgroundColor: Colors.black12,
                    )
                  : null,
            ),
          ],
        ),
      ),
    );
  }
}
