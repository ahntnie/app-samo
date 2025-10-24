import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:uuid/uuid.dart';
import 'dart:math' as math;
import 'dart:developer' as developer;
import '../../notification_service.dart';
import '../../text_scanner_screen.dart';

class ThousandsFormatterLocal extends TextInputFormatter {
  @override
  TextEditingValue formatEditUpdate(TextEditingValue oldValue, TextEditingValue newValue) {
    String newText = newValue.text.replaceAll('.', '').replaceAll(',', '');
    if (newText.isEmpty) return newValue;
    final intValue = int.tryParse(newText);
    if (intValue == null) return newValue;
    final formatted = NumberFormat('#,###', 'vi_VN').format(intValue).replaceAll(',', '.');
    return TextEditingValue(
      text: formatted,
      selection: TextSelection.collapsed(offset: formatted.length),
    );
  }
}

String formatNumberLocal(num value) {
  return NumberFormat('#,###', 'vi_VN').format(value).replaceAll(',', '.');
}

// Constants for IMEI handling
const int maxImeiQuantity = 100000;
const int displayImeiLimit = 100;
const int maxBatchSize = 1000;

class TransferReceiveForm extends StatefulWidget {
  final SupabaseClient tenantClient;

  const TransferReceiveForm({super.key, required this.tenantClient});

  @override
  State<TransferReceiveForm> createState() => _TransferReceiveFormState();
}

class _TransferReceiveFormState extends State<TransferReceiveForm> {
  final uuid = const Uuid();

  String? warehouseId;
  String? productId;
  String? imei = '';
  String? note;
  String? transportFee;
  int quantity = 0;
  Map<String, String> warehouseMap = {};
  Map<String, String> productMap = {};
  List<String> imeiSuggestions = [];
  List<String> imeiList = [];
  bool isLoading = true;
  bool isSubmitting = false;
  String? imeiError;
  String? feeError;

  final TextEditingController imeiController = TextEditingController();
  final TextEditingController feeController = TextEditingController();
  final TextEditingController quantityController = TextEditingController();
  final TextEditingController productController = TextEditingController();
  final TextEditingController warehouseController = TextEditingController();
  final FocusNode imeiFocusNode = FocusNode();

  @override
  void initState() {
    super.initState();
    _loadInitialData();
    imeiController.text = imei ?? '';
    feeController.text = transportFee ?? '';
    quantityController.text = quantity.toString();
  }

  @override
  void dispose() {
    imeiController.dispose();
    feeController.dispose();
    quantityController.dispose();
    productController.dispose();
    warehouseController.dispose();
    imeiFocusNode.dispose();
    super.dispose();
  }

  Future<void> _loadInitialData() async {
    setState(() {
      isLoading = true;
    });

    try {
      await Future.wait([
        _fetchWarehouses(),
        _fetchProducts(),
      ]);
    } catch (e) {
      developer.log('Error loading initial data: $e', level: 1000);
      _showErrorSnackBar('Lỗi khi tải dữ liệu ban đầu: $e');
    } finally {
      if (mounted) {
        setState(() {
          isLoading = false;
        });
      }
    }
  }

  Future<void> _fetchWarehouses() async {
    try {
      final stopwatch = Stopwatch()..start();
      final response = await widget.tenantClient.from('warehouses').select('id, name');
      if (mounted) {
        setState(() {
          warehouseMap = {
            for (var e in response) e['id'].toString(): e['name'] as String,
          };
        });
      }
      developer.log('Danh sách kho đã được tải: $warehouseMap, thời gian: ${stopwatch.elapsedMilliseconds}ms');
      stopwatch.stop();
    } catch (e) {
      developer.log('Lỗi khi tải danh sách kho: $e', level: 1000);
      throw Exception('Lỗi khi tải danh sách kho: $e');
    }
  }

  Future<void> _fetchProducts() async {
    try {
      final stopwatch = Stopwatch()..start();
      final response = await widget.tenantClient.from('products_name').select('id, products');
      if (mounted) {
        setState(() {
          productMap = {
            for (var e in response) e['id'].toString(): e['products'] as String,
          };
        });
      }
      developer.log('Danh sách sản phẩm đã được tải: $productMap, thời gian: ${stopwatch.elapsedMilliseconds}ms');
      stopwatch.stop();
    } catch (e) {
      developer.log('Lỗi khi tải danh sách sản phẩm: $e', level: 1000);
      throw Exception('Lỗi khi tải danh sách sản phẩm: $e');
    }
  }

  Future<void> _fetchImeiSuggestions(String query) async {
    if (productId == null) {
      setState(() {
        imeiSuggestions = [];
      });
      return;
    }

    try {
      final response = await widget.tenantClient
          .from('products')
          .select('imei')
          .eq('product_id', productId!)
          .eq('status', 'đang vận chuyển')
          .ilike('imei', '%$query%')
          .limit(10);

      final filteredImeis = response
          .map((e) => e['imei'] as String?)
          .whereType<String>()
          .where((imei) => !imeiList.contains(imei))
          .toList()
        ..sort();

      if (mounted) {
        setState(() {
          imeiSuggestions = filteredImeis;
        });
      }
    } catch (e) {
      developer.log('Lỗi khi tải gợi ý IMEI: $e', level: 1000);
      if (mounted) {
        setState(() {
          imeiSuggestions = [];
        });
      }
    }
  }

  String? _checkDuplicateImeis(String input) {
    final trimmedInput = input.trim();
    if (imeiList.contains(trimmedInput)) {
      return 'IMEI "$trimmedInput" đã được nhập!';
    }
    return null;
  }

  Future<String?> _checkInventoryStatus(String input) async {
    if (productId == null) return 'Vui lòng chọn sản phẩm!';
    if (input.trim().isEmpty) return null;

    try {
      final productResponse = await widget.tenantClient
          .from('products')
          .select('status, product_id')
          .eq('imei', input.trim())
          .eq('product_id', productId!)
          .maybeSingle();

      if (productResponse == null || productResponse['status'] != 'đang vận chuyển') {
        final productName = productMap[productId] ?? 'Không xác định';
        return 'IMEI "$input" không tồn tại, không thuộc sản phẩm "$productName", hoặc không ở trạng thái đang vận chuyển!';
      }
      return null;
    } catch (e) {
      developer.log('Lỗi khi kiểm tra trạng thái tồn kho cho IMEI "$input": $e', level: 1000);
      return 'Lỗi khi kiểm tra IMEI "$input": $e';
    }
  }

  Future<Map<String, dynamic>> _calculateTransportFee(String transporter, num amountInVND) async {
    if (transporter.isEmpty || amountInVND <= 0) {
      developer.log('Dữ liệu không hợp lệ: transporter="$transporter", amountInVND=$amountInVND', level: 700);
      return {'fee': 0.0, 'error': 'Không tìm thấy đơn vị vận chuyển hoặc giá vốn không hợp lệ'};
    }

    final normalizedTransporter = transporter.trim();
    developer.log('Đơn vị vận chuyển chuẩn hóa: "$normalizedTransporter"');

    final normalizedAmountInVND = amountInVND.toDouble();
    developer.log('Giá vốn chuẩn hóa: $normalizedAmountInVND');

    try {
      developer.log('Đang lấy bảng giá cước cho đơn vị vận chuyển: "$normalizedTransporter"');
      final response = await widget.tenantClient
          .from('shipping_rates')
          .select('cost, min_value, max_value')
          .eq('transporter', normalizedTransporter);

      if (response.isEmpty) {
        developer.log('Không tìm thấy bảng giá cước cho đơn vị vận chuyển: "$normalizedTransporter"', level: 700);
        return {'fee': 0.0, 'error': 'Không tìm thấy ngưỡng cước cho đơn vị vận chuyển "$normalizedTransporter"'};
      }

      double fee = 0.0;
      for (var rate in response) {
        final minValue = (rate['min_value'] as num).toDouble();
        final maxValue = (rate['max_value'] as num).toDouble();
        final cost = (rate['cost'] as num).toDouble();

        developer.log('Kiểm tra ngưỡng: min_value=$minValue, max_value=$maxValue, cost=$cost');
        if (normalizedAmountInVND >= minValue && normalizedAmountInVND <= maxValue) {
          fee = cost;
          developer.log('Tìm thấy ngưỡng phù hợp: fee=$fee');
          break;
        }
      }

      return {'fee': fee, 'error': null};
    } catch (e) {
      developer.log('Lỗi khi tính cước vận chuyển: $e', level: 1000);
      return {'fee': 0.0, 'error': 'Lỗi khi tính cước vận chuyển: $e'};
    }
  }

  Future<Map<String, dynamic>> _calculateTransportFeeFromImeis(List<String> imeis) async {
    double totalFee = 0.0;
    final feesPerProduct = <String, double>{};
    String? errorMessage;

    const batchSize = maxBatchSize;
    final batches = <List<String>>[];
    for (var i = 0; i < imeis.length; i += batchSize) {
      batches.add(imeis.sublist(i, i + batchSize > imeis.length ? imeis.length : i + batchSize));
    }

    developer.log('Đang lấy dữ liệu sản phẩm cho ${imeis.length} IMEI, chia thành ${batches.length} batch');
    final stopwatch = Stopwatch()..start();
    final productDataMap = <String, Map<String, dynamic>>{};

    try {
      for (var batch in batches) {
        final batchStopwatch = Stopwatch()..start();
        final batchData = await widget.tenantClient
            .from('products')
            .select('imei, transporter, cost_price, warehouse_name, warehouse_id, status')
            .inFilter('imei', batch);
        for (var data in batchData) {
          productDataMap[data['imei'] as String] = data;
        }
        developer.log('Lấy dữ liệu batch (${batch.length} IMEI), thời gian: ${batchStopwatch.elapsedMilliseconds}ms');
        batchStopwatch.stop();
      }
    } catch (e) {
      developer.log('Lỗi khi lấy dữ liệu sản phẩm trong _calculateTransportFeeFromImeis: $e', level: 1000);
      throw Exception('Lỗi khi lấy dữ liệu sản phẩm: $e');
    }

    for (var code in imeis) {
      developer.log('Đang tính cước cho IMEI: $code');
      final productData = productDataMap[code];

      if (productData != null) {
        final transporter = productData['transporter'] as String?;
        final costPrice = (productData['cost_price'] as num?) ?? 0;

        developer.log('Dữ liệu sản phẩm cho IMEI $code: transporter="$transporter", cost_price=$costPrice');

        final feeResult = await _calculateTransportFee(transporter ?? '', costPrice);
        final fee = (feeResult['fee'] is num) ? (feeResult['fee'] as num).toDouble() : 0.0;
        final error = feeResult['error'] as String?;

        if (error != null && errorMessage == null) {
          errorMessage = error;
        }

        feesPerProduct[code] = fee;
        totalFee += fee;
        developer.log('Cước cho IMEI $code: $fee');
      } else {
        developer.log('Không tìm thấy sản phẩm cho IMEI: $code', level: 700);
        errorMessage ??= 'Không tìm thấy sản phẩm với IMEI $code';
        feesPerProduct[code] = 0.0; // Gán giá trị mặc định nếu không tìm thấy
      }
    }
    developer.log('Tổng cước vận chuyển đã tính: $totalFee, thời gian: ${stopwatch.elapsedMilliseconds}ms');
    stopwatch.stop();
    return {
      'totalFee': totalFee,
      'feesPerProduct': feesPerProduct,
      'error': errorMessage,
    };
  }

  Future<Map<String, dynamic>> _createSnapshot(String ticketId, List<Map<String, dynamic>> transporterOrders, List<Map<String, dynamic>> productsData, List<Map<String, dynamic>> transporterData) async {
    final snapshotData = <String, dynamic>{};

    snapshotData['products'] = productsData ?? [];
    snapshotData['transporters'] = transporterData ?? [];
    snapshotData['transporter_orders'] = transporterOrders ?? [];

    return snapshotData;
  }

  // Hàm phát âm thanh beep
  void _playBeepSound() {
    SystemSound.play(SystemSoundType.click);
  }

  Future<void> _scanQRCode() async {
    try {
      final scannedData = await Navigator.push(
        context,
        MaterialPageRoute(builder: (context) => QRCodeScannerScreen()),
      );

      if (scannedData != null && scannedData is String && mounted) {
        // Phát âm thanh beep khi quét thành công
        _playBeepSound();
        
        setState(() {
          imei = scannedData;
          imeiController.text = scannedData;
          imeiError = _checkDuplicateImeis(scannedData);
        });

        if (imeiError == null) {
          final error = await _checkInventoryStatus(scannedData);
          if (mounted) {
            setState(() {
              imeiError = error;
            });
            if (error == null) {
              setState(() {
                imeiList.insert(0, scannedData.trim());
                imei = '';
                imeiController.text = '';
                imeiError = null;
                imeiFocusNode.unfocus();
              });
            }
          }
        }
      }
    } catch (e) {
      developer.log('Lỗi khi quét QR code: $e', level: 1000);
      _showErrorSnackBar('Lỗi khi quét QR code: $e');
    }
  }

  Future<void> _scanText() async {
    try {
      final scannedData = await Navigator.push<String?>(
        context,
        MaterialPageRoute(builder: (context) => const TextScannerScreen()),
      );

      if (scannedData != null && mounted) {
        // Phát âm thanh beep khi quét thành công
        _playBeepSound();
        
        setState(() {
          imei = scannedData;
          imeiController.text = scannedData;
          imeiError = _checkDuplicateImeis(scannedData);
        });

        if (imeiError == null) {
          final error = await _checkInventoryStatus(scannedData);
          if (mounted) {
            setState(() {
              imeiError = error;
            });
            if (error == null) {
              setState(() {
                imeiList.insert(0, scannedData.trim());
                imei = '';
                imeiController.text = '';
                imeiError = null;
                imeiFocusNode.unfocus();
              });
            }
          }
        }
      }
    } catch (e) {
      developer.log('Lỗi khi quét text: $e', level: 1000);
      _showErrorSnackBar('Lỗi khi quét text: $e');
    }
  }

  Future<List<String>> _generateRandomImeis(int quantity, String productId) async {
    final stopwatch = Stopwatch()..start();
    try {
      final response = await widget.tenantClient
          .from('products')
          .select('imei')
          .eq('status', 'đang vận chuyển')
          .eq('product_id', productId);

      final availableImeis = response
          .map((e) => e['imei'] as String)
          .toList()
        ..shuffle();

      if (availableImeis.length < quantity) {
        throw Exception('Không đủ sản phẩm đang vận chuyển để tạo phiếu với số lượng $quantity');
      }

      final result = availableImeis.take(quantity).toList();
      developer.log('Tạo danh sách IMEI ngẫu nhiên ($quantity), thời gian: ${stopwatch.elapsedMilliseconds}ms');
      stopwatch.stop();
      return result;
    } catch (e) {
      developer.log('Lỗi khi tạo danh sách IMEI ngẫu nhiên: $e', level: 1000);
      throw Exception('Lỗi khi tạo danh sách IMEI: $e');
    }
  }

  void showConfirmDialog() async {
    if (isSubmitting) return;

    List<String> errors = [];

    if (warehouseId == null) {
      errors.add('Vui lòng chọn kho nhập!');
    }

    if (productId == null) {
      errors.add('Vui lòng chọn sản phẩm!');
    }

    List<String> imeis = imeiList;
    double transportFeeValue = 0;
    Map<String, double> feesPerProduct = {};
    String? feeErrorMessage;

    if (imeis.isNotEmpty) {
      // Nếu đã nhập IMEI thủ công, lấy cước vận chuyển từ ô nhập nếu có
      final enteredFee = double.tryParse(feeController.text.replaceAll('.', '')) ?? 0;
      if (enteredFee > 0) {
        if (enteredFee < 0) {
          errors.add('Cước vận chuyển không được âm!');
        } else {
          transportFeeValue = enteredFee;
          feesPerProduct = { for (var imei in imeis) imei: transportFeeValue / imeis.length };
        }
      } else {
        // Nếu không nhập cước thủ công, tính tự động
        try {
          final feeData = await _calculateTransportFeeFromImeis(imeis);
          transportFeeValue = feeData['totalFee'] as double;
          feesPerProduct = feeData['feesPerProduct'] as Map<String, double>;
          feeErrorMessage = feeData['error'] as String?;
        } catch (e) {
          errors.add('Lỗi khi tính cước vận chuyển: $e');
        }
      }
    } else {
      final enteredQuantity = int.tryParse(quantityController.text) ?? 0;
      final enteredFee = double.tryParse(feeController.text.replaceAll('.', '')) ?? 0;

      if (enteredQuantity <= 0) {
        errors.add('Vui lòng nhập số lượng lớn hơn 0!');
      }

      if (enteredFee <= 0) {
        errors.add('Vui lòng nhập cước vận chuyển lớn hơn 0!');
      }

      if (enteredFee < 0) {
        errors.add('Cước vận chuyển không được âm!');
      }

      if (errors.isEmpty && productId != null) {
        // Sử dụng IMEI đã tự động lấy từ imeiList nếu có
        if (imeiList.isNotEmpty && imeiList.length == enteredQuantity) {
          imeis = List.from(imeiList);
          transportFeeValue = enteredFee;
          feesPerProduct = { for (var imei in imeis) imei: transportFeeValue / imeis.length };
        } else {
          // Nếu chưa có IMEI hoặc số lượng không khớp, tạo mới
          try {
            imeis = await _generateRandomImeis(enteredQuantity, productId!);
            transportFeeValue = enteredFee;
            feesPerProduct = { for (var imei in imeis) imei: transportFeeValue / imeis.length };
          } catch (e) {
            errors.add('$e');
            imeis = [];
            transportFeeValue = 0;
          }
        }
      } else {
        imeis = [];
        transportFeeValue = 0;
      }
    }

    if (imeis.isEmpty) {
      errors.add('Vui lòng nhập ít nhất 1 IMEI hoặc chọn số lượng để tạo phiếu nhập kho');
    }

    if (imeis.length > maxImeiQuantity) {
      errors.add('Số lượng IMEI (${formatNumberLocal(imeis.length)}) vượt quá giới hạn (${formatNumberLocal(maxImeiQuantity)}). Vui lòng chia thành nhiều phiếu.');
    }

    if (imeiError != null) {
      errors.add(imeiError!);
    }

    if (errors.isNotEmpty) {
      _showErrorSnackBar(errors.join('\n'));
      return;
    }

    final productName = productId != null ? productMap[productId] ?? 'Không xác định' : 'Không xác định';
    final warehouseName = warehouseId != null ? warehouseMap[warehouseId] ?? 'Không xác định' : 'Không xác định';

    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Xác nhận nhập kho'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Kho nhập: $warehouseName'),
              Text('Sản phẩm: $productName'),
              const Text('Danh sách IMEI:'),
              ...imeis.map((imei) => Text('- $imei')),
              Text('Số lượng: ${imeis.length}'),
              Text('Cước vận chuyển: ${formatNumberLocal(transportFeeValue)}'),
              if (feeErrorMessage != null)
                Text('Lý do cước bằng 0: $feeErrorMessage', style: const TextStyle(color: Colors.red)),
              Text('Ghi chú: ${note ?? "Không có"}'),
            ],
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Sửa lại')),
          ElevatedButton(
            onPressed: () async {
              Navigator.pop(context);
              showDialog(
                context: context,
                barrierDismissible: false,
                builder: (context) => AlertDialog(
                  content: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: const [
                      CircularProgressIndicator(),
                      SizedBox(height: 16),
                      Text(
                        'Vui lòng chờ xử lý dữ liệu.',
                        textAlign: TextAlign.center,
                      ),
                    ],
                  ),
                ),
              );
              await saveReceive(imeis, transportFeeValue, feesPerProduct);
            },
            child: const Text('Tạo phiếu'),
          ),
        ],
      ),
    );
  }

  Future<void> _rollbackChanges(Map<String, dynamic> snapshot, String ticketId) async {
    final supabase = widget.tenantClient;
    
    try {
      // Rollback transporters
      if (snapshot['transporters'] != null && (snapshot['transporters'] as List).isNotEmpty) {
        for (var transporter in snapshot['transporters']) {
          try {
            await supabase
                .from('transporters')
                .update(transporter)
                .eq('name', transporter['name']);
            developer.log('Rollback transporter: ${transporter['name']} thành công');
          } catch (e) {
            developer.log('Lỗi khi rollback transporter ${transporter['name']}: $e', level: 1000);
          }
        }
      }

      // Rollback products
      if (snapshot['products'] != null && (snapshot['products'] as List).isNotEmpty) {
        for (var product in snapshot['products']) {
          try {
            await supabase
                .from('products')
                .update(product)
                .eq('imei', product['imei']);
            developer.log('Rollback product với IMEI ${product['imei']} thành công');
          } catch (e) {
            developer.log('Lỗi khi rollback product với IMEI ${product['imei']}: $e', level: 1000);
          }
        }
      }

      // Delete created transporter orders
      try {
        await supabase
            .from('transporter_orders')
            .delete()
            .eq('ticket_id', ticketId);
        developer.log('Xóa transporter orders với ticket_id $ticketId thành công');
      } catch (e) {
        developer.log('Lỗi khi xóa transporter orders với ticket_id $ticketId: $e', level: 1000);
      }
    } catch (e) {
      developer.log('Lỗi tổng thể khi rollback dữ liệu: $e', level: 1000);
      throw Exception('Lỗi khi rollback dữ liệu: $e');
    }
  }

  Future<bool> _verifyData(String ticketId, List<String> imeiList) async {
    final supabase = widget.tenantClient;
    
    try {
      // Verify products data
      final productsData = await supabase
          .from('products')
          .select('status, warehouse_id, import_transfer_date, transport_fee, cost_price')
          .inFilter('imei', imeiList);
      
      // Verify all IMEIs are marked as in stock, assigned to correct warehouse, and have updated transport_fee and cost_price
      for (var product in productsData) {
        if (product['status'] != 'Tồn kho' || 
            product['warehouse_id'] != warehouseId ||
            product['import_transfer_date'] == null ||
            product['transport_fee'] == null ||
            product['cost_price'] == null ||
            (product['transport_fee'] as num) < 0 ||
            (product['cost_price'] as num) < 0) {
          developer.log('Dữ liệu không hợp lệ cho IMEI ${product['imei']}: status=${product['status']}, warehouse_id=${product['warehouse_id']}, transport_fee=${product['transport_fee']}, cost_price=${product['cost_price']}', level: 1000);
          return false;
        }
      }

      // Verify transporter orders
      final transporterOrders = await supabase
          .from('transporter_orders')
          .select()
          .eq('ticket_id', ticketId);

      // Verify transporter orders are created
      if (transporterOrders.isEmpty) {
        developer.log('Không tìm thấy transporter orders với ticket_id $ticketId', level: 1000);
        return false;
      }

      // Verify transporters data if any
      for (var order in transporterOrders) {
        final transporter = order['transporter'] as String?;
        if (transporter != null) {
          final transporterData = await supabase
              .from('transporters')
              .select()
              .eq('name', transporter)
              .single();
          if (transporterData == null) {
            developer.log('Không tìm thấy transporter $transporter', level: 1000);
            return false;
          }
        }
      }

      return true;
    } catch (e) {
      developer.log('Lỗi khi xác minh dữ liệu: $e', level: 1000);
      return false;
    }
  }

  Future<void> saveReceive(List<String> imeis, double transportFeeValue, Map<String, double> feesPerProduct) async {
    setState(() {
      isSubmitting = true;
    });

    try {
      final totalStopwatch = Stopwatch()..start();
      final now = DateTime.now();

      if (imeis.isEmpty) {
        throw Exception('Vui lòng nhập ít nhất 1 IMEI để tạo phiếu nhập kho');
      }

      if (productId == null || warehouseId == null) {
        throw Exception('Product ID hoặc warehouse ID không được null');
      }

      // Create snapshot before any changes
      final ticketId = uuid.v4();
      Map<String, dynamic> snapshot;
      try {
        developer.log('Lấy dữ liệu sản phẩm cho ${imeis.length} IMEI...');
        const batchSize = maxBatchSize;
        final batches = <List<String>>[];
        for (var i = 0; i < imeis.length; i += batchSize) {
          final endIndex = math.min(i + batchSize, imeis.length);
          batches.add(imeis.sublist(i, endIndex));
          developer.log('Created batch from index $i to $endIndex với ${batches.last.length} IMEI');
        }

        final stopwatchFetchProducts = Stopwatch()..start();
        final productsData = <Map<String, dynamic>>[];
        for (var batch in batches) {
          final batchStopwatch = Stopwatch()..start();
          final batchData = await widget.tenantClient
              .from('products')
              .select('imei, transporter, cost_price, warehouse_name, warehouse_id, status, transport_fee')
              .inFilter('imei', batch);
          productsData.addAll(batchData.map((item) => Map<String, dynamic>.from(item)));
          developer.log('Lấy dữ liệu batch (${batch.length} IMEI), thời gian: ${batchStopwatch.elapsedMilliseconds}ms');
          batchStopwatch.stop();
        }
        developer.log('Lấy dữ liệu sản phẩm hoàn tất, thời gian: ${stopwatchFetchProducts.elapsedMilliseconds}ms');
        stopwatchFetchProducts.stop();

        developer.log('Nhóm sản phẩm theo đơn vị vận chuyển...');
        final Map<String, List<String>> transporterImeis = {};
        for (var product in productsData) {
          final imei = product['imei'] as String;
          final transporter = (product['transporter'] as String?) ?? 'Không xác định';
          transporterImeis.putIfAbsent(transporter, () => []).add(imei);
        }

        developer.log('Lấy dữ liệu đơn vị vận chuyển...');
        final stopwatchFetchTransporters = Stopwatch()..start();
        final transporters = transporterImeis.keys.toList();
        List<Map<String, dynamic>> transporterData = [];
        if (transporters.isNotEmpty) {
          final rawTransporterData = await widget.tenantClient
              .from('transporters')
              .select()
              .inFilter('name', transporters.where((t) => t != 'Không xác định').toList());
          transporterData = rawTransporterData.map((item) => Map<String, dynamic>.from(item)).toList();
        }
        developer.log('Lấy dữ liệu đơn vị vận chuyển hoàn tất, thời gian: ${stopwatchFetchTransporters.elapsedMilliseconds}ms');
        stopwatchFetchTransporters.stop();

        developer.log('Tạo danh sách transporter_orders...');
        final transporterOrders = <Map<String, dynamic>>[];
        for (var transporter in transporterImeis.keys) {
          final imeiListForTransporter = transporterImeis[transporter]!;
          final imeiString = imeiListForTransporter.join(',');
          double feeForTransporter = 0;
          for (var imei in imeiListForTransporter) {
            feeForTransporter += feesPerProduct[imei] ?? 0;
          }
          transporterOrders.add({
            'id': uuid.v4(),
            'ticket_id': ticketId,
            'imei': imeiString,
            'product_id': productId,
            'transporter': transporter == 'Không xác định' ? null : transporter,
            'warehouse_id': warehouseId,
            'transport_fee': feeForTransporter,
            'type': 'nhập kho vận chuyển',
            'created_at': now.toIso8601String(),
            'iscancelled': false,
          });
        }

        developer.log('Tạo snapshot cho ticket $ticketId...');
        snapshot = await _createSnapshot(ticketId, transporterOrders, productsData, transporterData);
      } catch (e) {
        developer.log('Lỗi khi tạo snapshot: $e', level: 1000);
        setState(() {
          isSubmitting = false;
        });
        _showErrorSnackBar('Lỗi khi chuẩn bị dữ liệu: $e');
        return;
      }

      try {
        final supabase = widget.tenantClient;

        // Insert snapshot
        developer.log('Chèn snapshot cho ticket $ticketId...');
        await supabase.from('snapshots').insert({
          'ticket_id': ticketId,
          'ticket_table': 'transporter_orders',
          'snapshot_data': snapshot,
          'created_at': now.toIso8601String(),
        });

        // Insert transporter orders
        developer.log('Chèn transporter orders...');
        await supabase.from('transporter_orders').insert(snapshot['transporter_orders']);

        // Fetch current cost_price for all IMEIs in batches
        developer.log('Lấy cost_price cho tất cả IMEI...');
        final Map<String, double> costPrices = {};
        for (var i = 0; i < imeis.length; i += maxBatchSize) {
          final batch = imeis.sublist(i, math.min(i + maxBatchSize, imeis.length));
          try {
            final batchData = await supabase
                .from('products')
                .select('imei, cost_price')
                .inFilter('imei', batch);
            for (var data in batchData) {
              costPrices[data['imei'] as String] = (data['cost_price'] as num?)?.toDouble() ?? 0.0;
            }
          } catch (e) {
            developer.log('Lỗi khi lấy cost_price cho batch IMEI từ $i: $e', level: 1000);
            throw Exception('Lỗi khi lấy giá vốn hiện tại: $e');
          }
        }

        // Update products with transport_fee and new cost_price
        developer.log('Cập nhật bảng products...');
        for (var imei in imeis) {
          final transportFeeForImei = feesPerProduct[imei] ?? 0.0;
          if (transportFeeForImei < 0) {
            throw Exception('Cước vận chuyển cho IMEI $imei không được âm: $transportFeeForImei');
          }
          final oldCostPrice = costPrices[imei] ?? 0.0;
          final newCostPrice = oldCostPrice + transportFeeForImei;
          if (newCostPrice < 0) {
            throw Exception('Giá vốn mới cho IMEI $imei không được âm: $newCostPrice');
          }

          try {
            await supabase.from('products').update({
              'status': 'Tồn kho',
              'warehouse_id': warehouseId,
              'warehouse_name': warehouseMap[warehouseId],
              'import_transfer_date': now.toIso8601String(),
              'transport_fee': transportFeeForImei,
              'cost_price': newCostPrice,
            }).eq('imei', imei);
            developer.log('Cập nhật product với IMEI $imei: transport_fee=$transportFeeForImei, new_cost_price=$newCostPrice');
          } catch (e) {
            developer.log('Lỗi khi cập nhật product với IMEI $imei: $e', level: 1000);
            throw Exception('Lỗi khi cập nhật product với IMEI $imei: $e');
          }
        }

        // Update transporters
        developer.log('Cập nhật bảng transporters...');
        for (var transporterOrder in snapshot['transporter_orders']) {
          final transporter = transporterOrder['transporter'] as String?;
          final fee = (transporterOrder['transport_fee'] as num?)?.toDouble() ?? 0.0;
          if (transporter != null && fee > 0) {
            try {
              final currentTransporter = await supabase
                  .from('transporters')
                  .select('debt')
                  .eq('name', transporter)
                  .single();
              final currentDebt = (currentTransporter['debt'] as num?)?.toDouble() ?? 0.0;
              final updatedDebt = currentDebt + fee;
              await supabase.from('transporters').update({
                'debt': updatedDebt,
              }).eq('name', transporter);
              developer.log('Cập nhật debt cho transporter $transporter: $updatedDebt');
            } catch (e) {
              developer.log('Lỗi khi cập nhật debt cho transporter $transporter: $e', level: 1000);
              throw Exception('Lỗi khi cập nhật transporter $transporter: $e');
            }
          }
        }

        // After all updates, verify the data
        developer.log('Xác minh dữ liệu...');
        final isDataValid = await _verifyData(ticketId, imeis);
        if (!isDataValid) {
          developer.log('Dữ liệu không hợp lệ sau khi cập nhật, tiến hành rollback...', level: 1000);
          await _rollbackChanges(snapshot, ticketId);
          throw Exception('Dữ liệu không khớp sau khi cập nhật. Đã rollback thay đổi.');
        }

        // Success notification
        developer.log('Gửi thông báo thành công...');
        final productName = productId != null ? productMap[productId] ?? 'Không xác định' : 'Không xác định';
        await NotificationService.showNotification(
          141,
          'Đã tạo phiếu nhập kho vận chuyển',
          'Đã tạo phiếu nhập kho vận chuyển sản phẩm $productName imei ${imeis.join(', ')}',
          'transfer_receive_created',
        );

        if (mounted) {
          Navigator.pop(context);
          Navigator.pop(context);
        }

      } catch (e) {
        // If any error occurs, rollback changes
        try {
          developer.log('Lỗi khi lưu phiếu, tiến hành rollback...', level: 1000);
          await _rollbackChanges(snapshot, ticketId);
        } catch (rollbackError) {
          developer.log('Rollback thất bại: $rollbackError', level: 1000);
        }

        if (mounted) {
          setState(() {
            isSubmitting = false;
          });
          _showErrorSnackBar('Lỗi khi tạo phiếu nhập kho: $e');
        }
      } finally {
        developer.log('Hoàn tất xử lý saveReceive, thời gian: ${totalStopwatch.elapsedMilliseconds}ms');
        totalStopwatch.stop();
      }
    } catch (e) {
      developer.log('Lỗi tổng thể trong saveReceive: $e', level: 1000);
      if (mounted) {
        setState(() {
          isSubmitting = false;
        });
        _showErrorSnackBar('Lỗi không xác định: $e');
      }
    }
  }

  void _showErrorSnackBar(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: Colors.red,
        duration: const Duration(seconds: 5),
      ),
    );
  }

  Widget wrapField(Widget child, {bool isImeiField = false, bool isImeiList = false}) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      margin: const EdgeInsets.symmetric(vertical: 4),
      height: isImeiField ? 72 : isImeiList ? 120 : 48, // Tăng chiều cao IMEI field từ 48 lên 72 (50%)
      decoration: BoxDecoration(
        color: Colors.grey.shade200,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: imeiError != null ? Colors.red : Colors.grey.shade300),
      ),
      child: child,
    );
  }

  @override
  Widget build(BuildContext context) {
    if (isLoading) {
      return const Scaffold(
        body: Center(child: CircularProgressIndicator()),
      );
    }

    final isImeiManual = imeiList.isNotEmpty;

    return Scaffold(
      resizeToAvoidBottomInset: true,
      appBar: AppBar(
        title: const Text('Phiếu nhập kho vận chuyển', style: TextStyle(color: Colors.white)),
        backgroundColor: Colors.black,
        iconTheme: const IconThemeData(color: Colors.white),
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            wrapField(
              Autocomplete<String>(
                optionsBuilder: (TextEditingValue textEditingValue) {
                  final query = textEditingValue.text.toLowerCase();
                  if (warehouseMap.isEmpty) return ['Không có kho nào'];
                  final filtered = warehouseMap.entries
                      .where((entry) => entry.value.toLowerCase().contains(query))
                      .map((entry) => entry.value)
                      .toList()
                    ..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
                  return filtered.isNotEmpty ? filtered.take(10).toList() : ['Không tìm thấy kho'];
                },
                onSelected: (String selection) {
                  final selectedId = warehouseMap.entries
                      .firstWhere(
                        (entry) => entry.value == selection,
                        orElse: () => MapEntry('', ''),
                      )
                      .key;
                  if (selectedId.isNotEmpty) {
                    setState(() {
                      warehouseId = selectedId;
                      warehouseController.text = selection;
                    });
                  }
                },
                fieldViewBuilder: (context, controller, focusNode, onFieldSubmitted) {
                  controller.text = warehouseController.text;
                  return TextField(
                    controller: controller,
                    focusNode: focusNode,
                    onChanged: (value) {
                      setState(() {
                        warehouseController.text = value;
                        if (value.isEmpty) {
                          warehouseId = null;
                        }
                      });
                    },
                    decoration: const InputDecoration(
                      labelText: 'Kho nhập',
                      border: InputBorder.none,
                      isDense: true,
                    ),
                  );
                },
              ),
            ),
            wrapField(
              Autocomplete<String>(
                optionsBuilder: (TextEditingValue textEditingValue) {
                  final query = textEditingValue.text.toLowerCase();
                  if (productMap.isEmpty) return ['Không có sản phẩm nào'];
                  final filtered = productMap.entries
                      .where((entry) => entry.value.toLowerCase().contains(query))
                      .map((entry) => entry.value)
                      .toList()
                    ..sort((a, b) {
                      final aName = a.toLowerCase();
                      final bName = b.toLowerCase();
                      final aStartsWith = aName.startsWith(query);
                      final bStartsWith = bName.startsWith(query);
                      if (aStartsWith != bStartsWith) {
                        return aStartsWith ? -1 : 1;
                      }
                      final aIndex = aName.indexOf(query);
                      final bIndex = bName.indexOf(query);
                      if (aIndex != bIndex) {
                        return aIndex - bIndex;
                      }
                      return aName.compareTo(bName);
                    });
                  return filtered.isNotEmpty ? filtered.take(10).toList() : ['Không tìm thấy sản phẩm'];
                },
                onSelected: (String selection) async {
                  final selectedId = productMap.entries
                      .firstWhere(
                        (entry) => entry.value == selection,
                        orElse: () => MapEntry('', ''),
                      )
                      .key;
                  if (selectedId.isNotEmpty) {
                    setState(() {
                      productId = selectedId;
                      productController.text = selection;
                      imei = '';
                      imeiController.text = '';
                      imeiError = null;
                      imeiList = [];
                    });
                    _fetchImeiSuggestions('');
                  }
                },
                fieldViewBuilder: (context, controller, focusNode, onFieldSubmitted) {
                  controller.text = productController.text;
                  return TextField(
                    controller: controller,
                    focusNode: focusNode,
                    onChanged: (value) {
                      setState(() {
                        productController.text = value;
                        if (value.isEmpty) {
                          productId = null;
                          imei = '';
                          imeiController.text = '';
                          imeiError = null;
                          imeiList = [];
                        }
                      });
                    },
                    decoration: const InputDecoration(
                      labelText: 'Sản phẩm',
                      border: InputBorder.none,
                      isDense: true,
                    ),
                  );
                },
              ),
            ),
            wrapField(
              Row(
                children: [
                  Expanded(
                    child: TextFormField(
                      controller: quantityController,
                      keyboardType: TextInputType.number,
                      enabled: !isImeiManual,
                      onChanged: (val) {
                        setState(() {
                          quantity = int.tryParse(val) ?? 0;
                        });
                      },
                      decoration: const InputDecoration(
                        labelText: 'Số lượng',
                        border: InputBorder.none,
                        isDense: true,
                      ),
                    ),
                  ),
                  if (!isImeiManual)
                    IconButton(
                      icon: const Icon(Icons.search, color: Colors.blue),
                      onPressed: () async {
                        if (productId == null) {
                          _showErrorSnackBar('Vui lòng chọn sản phẩm trước!');
                          return;
                        }
                        
                        if (quantity <= 0) {
                          _showErrorSnackBar('Vui lòng nhập số lượng hợp lệ!');
                          return;
                        }
                        
                        final confirmed = await showDialog<bool>(
                          context: context,
                          builder: (context) => AlertDialog(
                            title: const Text('Xác nhận'),
                            content: Text('Tự động lấy $quantity IMEI từ kho?'),
                            actions: [
                              TextButton(
                                onPressed: () => Navigator.pop(context, false),
                                child: const Text('Hủy'),
                              ),
                              ElevatedButton(
                                onPressed: () => Navigator.pop(context, true),
                                child: const Text('Xác nhận'),
                              ),
                            ],
                          ),
                        );
                        
                        if (confirmed == true) {
                          try {
                            final autoImeis = await _generateRandomImeis(quantity, productId!);
                            setState(() {
                              imeiList = autoImeis;
                            });
                          } catch (e) {
                            setState(() {
                              imeiList = [];
                            });
                            _showErrorSnackBar('$e');
                          }
                        }
                      },
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints(),
                    ),
                ],
              ),
            ),
            wrapField(
              Column(
                children: [
                  // Phần nhập IMEI
                  Expanded(
                    child: Autocomplete<String>(
                      optionsBuilder: (TextEditingValue textEditingValue) {
                        final query = textEditingValue.text.toLowerCase();
                        if (productId == null) return ['Vui lòng chọn sản phẩm'];
                        if (query.isEmpty) return imeiSuggestions.take(10).toList();
                        final filtered = imeiSuggestions
                            .where((option) => option.toLowerCase().contains(query))
                            .toList()
                          ..sort((a, b) {
                            final aLower = a.toLowerCase();
                            final bLower = b.toLowerCase();
                            final aStartsWith = aLower.startsWith(query);
                            final bStartsWith = bLower.startsWith(query);
                            if (aStartsWith != bStartsWith) {
                              return aStartsWith ? -1 : 1;
                            }
                            return aLower.compareTo(bLower);
                          });
                        return filtered.isNotEmpty ? filtered.take(10).toList() : ['Không tìm thấy IMEI'];
                      },
                      onSelected: (String selection) async {
                        if (selection == 'Vui lòng chọn sản phẩm' || selection == 'Không tìm thấy IMEI') return;

                        final error = _checkDuplicateImeis(selection);
                        if (error != null) {
                          setState(() {
                            imeiError = error;
                          });
                          return;
                        }

                        final inventoryError = await _checkInventoryStatus(selection);
                        if (inventoryError != null) {
                          setState(() {
                            imeiError = inventoryError;
                          });
                          return;
                        }

                        setState(() {
                          imeiList.add(selection);
                          imei = '';
                          imeiController.text = '';
                          imeiError = null;
                        });
                        _fetchImeiSuggestions('');
                      },
                      fieldViewBuilder: (context, controller, focusNode, onFieldSubmitted) {
                        controller.text = imeiController.text;
                        return TextField(
                          controller: controller,
                          focusNode: focusNode,
                          enabled: productId != null,
                          onChanged: (value) {
                            setState(() {
                              imei = value;
                              imeiController.text = value;
                              imeiError = null;
                            });
                            _fetchImeiSuggestions(value);
                          },
                          onSubmitted: (value) async {
                            if (value.isEmpty) return;

                            final error = _checkDuplicateImeis(value);
                            if (error != null) {
                              setState(() {
                                imeiError = error;
                              });
                              return;
                            }

                            final inventoryError = await _checkInventoryStatus(value);
                            if (inventoryError != null) {
                              setState(() {
                                imeiError = inventoryError;
                              });
                              return;
                            }

                            setState(() {
                              imeiList.add(value);
                              imei = '';
                              imeiController.text = '';
                              imeiError = null;
                            });
                            _fetchImeiSuggestions('');
                          },
                          decoration: InputDecoration(
                            labelText: 'IMEI',
                            border: InputBorder.none,
                            isDense: true,
                            errorText: imeiError,
                            hintText: productId == null ? 'Chọn sản phẩm trước' : null,
                          ),
                        );
                      },
                    ),
                  ),
                  // 2 nút quét
                  Row(
                    children: [
                      // Nút quét QR (màu vàng)
                      Expanded(
                        child: Container(
                          height: 24, // Chiều cao bằng 1/2 của phần còn lại
                          margin: const EdgeInsets.only(right: 4),
                          child: ElevatedButton.icon(
                            onPressed: _scanQRCode,
                            icon: const Icon(Icons.qr_code_scanner, size: 16),
                            label: const Text('QR', style: TextStyle(fontSize: 12)),
                            style: ElevatedButton.styleFrom(
                              backgroundColor: Colors.amber,
                              foregroundColor: Colors.black,
                              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(4),
                              ),
                            ),
                          ),
                        ),
                      ),
                      // Nút quét Text (màu xanh lá cây)
                      Expanded(
                        child: Container(
                          height: 24, // Chiều cao bằng 1/2 của phần còn lại
                          margin: const EdgeInsets.only(left: 4),
                          child: ElevatedButton.icon(
                            onPressed: _scanText,
                            icon: const Icon(Icons.text_fields, size: 16),
                            label: const Text('IMEI', style: TextStyle(fontSize: 12)),
                            style: ElevatedButton.styleFrom(
                              backgroundColor: Colors.green,
                              foregroundColor: Colors.white,
                              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(4),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
              isImeiField: true,
            ),
            wrapField(
              SizedBox(
                height: 120,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Danh sách IMEI đã thêm (${imeiList.length})',
                      style: const TextStyle(fontSize: 14, color: Colors.black54),
                    ),
                    const SizedBox(height: 4),
                    Expanded(
                      child: imeiList.isEmpty
                          ? const Center(
                              child: Text(
                                'Chưa có IMEI nào',
                                style: TextStyle(fontSize: 14, color: Colors.grey),
                              ),
                            )
                          : ListView.builder(
                              itemCount: math.min(imeiList.length, displayImeiLimit),
                              itemExtent: 24,
                              itemBuilder: (context, index) {
                                return Row(
                                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                  children: [
                                    Expanded(
                                      child: Text(
                                        imeiList[index],
                                        style: const TextStyle(fontSize: 14),
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                    ),
                                    IconButton(
                                      icon: const Icon(Icons.delete, color: Colors.red, size: 18),
                                      onPressed: () {
                                        setState(() {
                                          imeiList.removeAt(index);
                                        });
                                      },
                                      padding: EdgeInsets.zero,
                                      constraints: const BoxConstraints(),
                                    ),
                                  ],
                                );
                              },
                            ),
                    ),
                    if (imeiList.length > displayImeiLimit)
                      Text(
                        '... và ${formatNumberLocal(imeiList.length - displayImeiLimit)} IMEI khác',
                        style: const TextStyle(fontSize: 14, color: Colors.grey),
                      ),
                  ],
                ),
              ),
              isImeiList: true,
            ),
            wrapField(
              TextFormField(
                controller: feeController,
                keyboardType: TextInputType.number,
                inputFormatters: [ThousandsFormatterLocal()],
                onChanged: (val) => setState(() {
                  transportFee = val.replaceAll('.', '');
                }),
                decoration: const InputDecoration(
                  labelText: 'Cước vận chuyển',
                  border: InputBorder.none,
                  isDense: true,
                ),
              ),
            ),
            wrapField(
              TextFormField(
                onChanged: (val) => setState(() => note = val),
                decoration: const InputDecoration(labelText: 'Ghi chú', border: InputBorder.none, isDense: true),
              ),
            ),
            const SizedBox(height: 20),
            ElevatedButton(
              onPressed: isSubmitting ? null : showConfirmDialog,
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.blue,
                foregroundColor: Colors.white,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
              ),
              child: const Text('Xác nhận'),
            ),
            const SizedBox(height: 20),
          ],
        ),
      ),
    );
  }
}

class QRCodeScannerScreen extends StatefulWidget {
  const QRCodeScannerScreen({super.key});

  @override
  _QRCodeScannerScreenState createState() => _QRCodeScannerScreenState();
}

class _QRCodeScannerScreenState extends State<QRCodeScannerScreen> {
  MobileScannerController controller = MobileScannerController(
    detectionSpeed: DetectionSpeed.normal,
    facing: CameraFacing.back,
    torchEnabled: false,
  );
  bool scanned = false;

  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Quét QR Code', style: TextStyle(color: Colors.white)),
        backgroundColor: Colors.black,
        iconTheme: const IconThemeData(color: Colors.white),
        actions: [
          IconButton(
            icon: const Icon(Icons.flash_on),
            onPressed: () {
              controller.toggleTorch();
            },
          ),
        ],
      ),
      body: Column(
        children: <Widget>[
          Expanded(
            flex: 5,
            child: MobileScanner(
              controller: controller,
              onDetect: (BarcodeCapture capture) {
                if (!scanned) {
                  final String? code = capture.barcodes.first.rawValue;
                  if (code != null) {
                    setState(() {
                      scanned = true;
                    });
                    Navigator.pop(context, code);
                  }
                }
              },
            ),
          ),
          Expanded(
            flex: 1,
            child: Center(
              child: Text(
                'Quét QR code để lấy IMEI',
                style: const TextStyle(fontSize: 18, color: Colors.black),
              ),
            ),
          ),
        ],
      ),
    );
  }
}