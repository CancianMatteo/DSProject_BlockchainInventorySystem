class Block {
  final int nBlock;
  final String? prevBlockHash;
  final String blockHash;
  final DateTime datetime;
  final Map<String, int> changes;
  final Map<String, dynamic> itemCatalog;
  final String authorEmail;
  final String? authorSign;
  final String serverSign;

  Block({
    required this.nBlock,
    required this.prevBlockHash,
    required this.blockHash,
    required this.datetime,
    required this.changes,
    required this.itemCatalog,
    required this.authorEmail,
    required this.authorSign,
    required this.serverSign,
  });

  factory Block.fromJson(Map<String, dynamic> json) {
    return Block(
      nBlock: (json['n_block'] as num).toInt(),
      prevBlockHash: json['prev_block_hash']?.toString(),
      blockHash: json['block_hash'].toString(),
      datetime: DateTime.parse(json['datetime']),
      changes: (json['changes'] as Map<String, dynamic>).map(
        (key, value) => MapEntry(key, (value as num).toInt()),
      ),
      itemCatalog: Map<String, dynamic>.from(json['item_catalog'] ?? {}),
      authorEmail: json['author_email'].toString(),
      authorSign: json['author_sign']?.toString(),
      serverSign: json['server_sign'].toString(),
    );
  }
}
