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

  String _displayNode(String nodeId) {
    final normalized = nodeId.replaceAll('_', '-');
    final match = RegExp(r'^node-([a-z])$').firstMatch(normalized);
    return match == null
        ? normalized
        : 'node-${match.group(1)!.toUpperCase()}';
  }

  String _formatValidatorSignatures(Block b) {
    if (b.validatorSignatures.isEmpty) return 'Nessuna firma disponibile';
    final lines = <String>[];
    final raw = b.validatorSignatures['commit'];
    if (raw is! Map) return 'Nessuna firma disponibile';
    for (final entry in raw.entries) {
      lines.add('COMMIT ${_displayNode(entry.key.toString())}: ${entry.value}');
    }
    return lines.isEmpty ? 'Nessuna firma disponibile' : lines.join('\n');
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
                  _buildDetailCard('Autore', _displayNode(data.proposerId)),
                  _buildDetailCard(
                    'Data e Ora',
                    data.datetime.toLocal().toString(),
                  ),
                  _buildDetailCard('Modifiche', _formatChanges(data)),
                  _buildDetailCard(
                    'Firma Autore (proposer)',
                    data.proposerSignature ?? 'N/A',
                    isCode: true,
                  ),
                  _buildDetailCard(
                    'Firma validatori',
                    _formatValidatorSignatures(data),
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
