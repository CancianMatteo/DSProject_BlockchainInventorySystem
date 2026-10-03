import 'dart:convert';
import 'package:flutter/services.dart';
import 'package:http/http.dart';
import 'package:web3dart/web3dart.dart';

class BlockchainService {
  final String _rpcUrl = 'HTTP://127.0.0.1:7545'; // Ganache

  late Web3Client _client;
  late DeployedContract _contract;
  late Credentials _credentials;
  late EthereumAddress _contractAddress;
  late ContractFunction _addAsset;
  late ContractFunction _getAssets;

  BlockchainService() {
    _client = Web3Client(_rpcUrl, Client());
  }

  Future<void> _loadContract() async {
    final abiString = await rootBundle.loadString(
      'assets/contracts/Inventory.json',
    );
    final abiJson = jsonDecode(abiString);
    _contractAddress = EthereumAddress.fromHex(
      abiJson['networks']['5777']['address'],
    );
    _contract = DeployedContract(
      ContractAbi.fromJson(jsonEncode(abiJson['abi']), 'Inventory'),
      _contractAddress,
    );

    _addAsset = _contract.function('addAsset');
    _getAssets = _contract.function('getAssets');
  }

  Future<String> addAsset(String name, String category, int quantity) async {
    await _loadContract();
    final result = await _client.sendTransaction(
      _credentials,
      Transaction.callContract(
        contract: _contract,
        function: _addAsset,
        parameters: [name, category, BigInt.from(quantity)],
      ),
      chainId: 1337, // Ganache chain ID
    );
    return result;
  }

  Future<List<dynamic>> getAssets() async {
    await _loadContract();
    final result = await _client.call(
      contract: _contract,
      function: _getAssets,
      params: [],
    );
    return result[0];
  }
}
