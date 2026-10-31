import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

class BarcodeScannerScreen extends StatefulWidget {
  const BarcodeScannerScreen({super.key});

  @override
  State<BarcodeScannerScreen> createState() => _BarcodeScannerScreenState();
}

class _BarcodeScannerScreenState extends State<BarcodeScannerScreen> {
  final MobileScannerController _controller = MobileScannerController(
    detectionSpeed: DetectionSpeed.noDuplicates,
  );
  bool _didReturnResult = false;

  Future<void> _handleDetection(BarcodeCapture capture) async {
    if (_didReturnResult) return;

    final String rawValue = capture.barcodes
        .map((barcode) => barcode.rawValue?.trim())
        .whereType<String>()
        .firstWhere((value) => value.isNotEmpty, orElse: () => '');

    if (rawValue.isEmpty) return;

    _didReturnResult = true;

    // Stop camera stream before returning to avoid repeated callbacks.
    try {
      await _controller.stop();
    } catch (_) {
      // Ignore controller stop errors and still return the scanned code.
    }

    if (!mounted) return;

    // Avoid navigator re-entrancy assert (_debugLocked) in fast callbacks.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final navigator = Navigator.of(context);
      if (navigator.canPop()) {
        navigator.pop(rawValue);
      }
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Scan barcode')),
      body: MobileScanner(controller: _controller, onDetect: _handleDetection),
    );
  }
}
