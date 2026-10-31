import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:cryptography/cryptography.dart';

class SignedTransaction {
  final Map<String, dynamic> transaction;

  const SignedTransaction(this.transaction);
}

class TransactionSigner {
  static final Ed25519 _algorithm = Ed25519();

  static Future<SignedTransaction> sign(
    Map<String, dynamic> transaction,
    String sessionToken,
  ) async {
    final seed = Uint8List.fromList(
      sha256.convert(utf8.encode(sessionToken)).bytes,
    );
    final keyPair = await _algorithm.newKeyPairFromSeed(seed);
    final publicKey = await keyPair.extractPublicKey();

    final unsigned = <String, dynamic>{
      for (final entry in transaction.entries)
        if (entry.key != 'flag') entry.key: entry.value,
      'client_public_key': base64Encode(publicKey.bytes),
    };
    final signature = await _algorithm.sign(
      utf8.encode(_canonicalJson(unsigned)),
      keyPair: keyPair,
    );

    return SignedTransaction({
      ...unsigned,
      if (transaction.containsKey('flag')) 'flag': transaction['flag'],
      'signature': base64Encode(signature.bytes),
    });
  }

  static String _canonicalJson(dynamic value) {
    return jsonEncode(_canonicalValue(value));
  }

  static dynamic _canonicalValue(dynamic value) {
    if (value is Map) {
      final keys = value.keys.map((key) => key.toString()).toList()..sort();
      return <String, dynamic>{
        for (final key in keys) key: _canonicalValue(value[key]),
      };
    }
    if (value is Iterable) {
      return value.map(_canonicalValue).toList();
    }
    return value;
  }
}
