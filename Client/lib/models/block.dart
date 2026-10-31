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
  final String proposerId;
  final String? proposerSignature;
  final Map<String, dynamic> validatorSignatures;

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
    required this.proposerId,
    required this.proposerSignature,
    required this.validatorSignatures,
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
      proposerId: (json['proposer_id'] ?? json['author_email']).toString(),
      proposerSignature:
          (json['proposer_signature'] ?? json['author_sign'])?.toString(),
      validatorSignatures: Map<String, dynamic>.from(
        json['validator_signatures'] ?? <String, dynamic>{},
      ),
    );
  }
}
