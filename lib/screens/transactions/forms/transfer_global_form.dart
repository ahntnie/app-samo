import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:intl/intl.dart';
import 'package:uuid/uuid.dart';
import 'dart:math' as math;
import 'dart:developer' as developer;
import '../../notification_service.dart';
import 'package:flutter/services.dart';
import '../../text_scanner_screen.dart';

// Utility class for caching product names
class CacheUtil {
  static final Map<String, String> productNameCache = {};

  static void cacheProductName(String id, String name) => productNameCache[id] = name;
  static String getProductName(String? id) => id != null ? productNameCache[id] ?? 'Không xác định' : 'Không xác định';
}

// Constants for IMEI handling
const int maxImeiQuantity = 100000;
const int displayImeiLimit = 100;

// Main widget for global transfer form
class TransferGlobalForm extends StatefulWidget {
  final SupabaseClient tenantClient;

  const TransferGlobalForm({super.key, required this.tenantClient});

  @override
  State<TransferGlobalForm> createState() => _TransferGlobalFormState();
}

// State class for TransferGlobalForm
class _TransferGlobalFormState extends State<TransferGlobalForm> {
  String? transporter;
  String? productId;
  String? imei = '';
  List<String> imeiList = [];
  List<String> transporters = [];
  List<Map<String, dynamic>> products = [];
  List<String> availableImeis = [];
  bool isLoading = true;
  bool isSubmitting = false;
  String? errorMessage;
  String? imeiError;

  final TextEditingController productController = TextEditingController();
  final TextEditingController imeiController = TextEditingController();
  final FocusNode imeiFocusNode = FocusNode();
  final uuid = const Uuid();

  @override
  void initState() {
    super.initState();
    _fetchInitialData();
  }

  @override
  void dispose() {
    productController.dispose();
    imeiController.dispose();
    imeiFocusNode.dispose();
    super.dispose();
  }

  // Fetch initial data from Supabase
  Future<void> _fetchInitialData() async {
    setState(() {
      isLoading = true;
      errorMessage = null;
    });

    try {
      final supabase = widget.tenantClient;

      // Fetch transporters
      final transporterResponse = await supabase
          .from('transporters')
          .select('name')
          .eq('type', 'vận chuyển quốc tế');
      final transporterList = transporterResponse
          .map((e) => e['name'] as String?)
          .whereType<String>()
          .toList()
        ..sort();

      // Fetch products from products_name
      final productResponse = await supabase
          .from('products_name')
          .select('id, products');
      final productList = productResponse
          .map((e) => {
                'id': e['id'].toString(),
                'name': e['products'] as String,
              })
          .toList()
        ..sort((a, b) => (a['name'] as String).toLowerCase().compareTo((b['name'] as String).toLowerCase()));

      if (mounted) {
        setState(() {
          transporters = transporterList;
          products = productList;
          isLoading = false;
          for (var product in productList) {
            CacheUtil.cacheProductName(product['id'] as String, product['name'] as String);
          }
        });
      }
    } catch (e) {
      print('Error fetching data from Supabase: $e');
      if (mounted) {
        setState(() {
          errorMessage = 'Không thể tải dữ liệu từ Supabase: $e';
          isLoading = false;
        });
      }
    }
  }

  // Fetch IMEI suggestions
  Future<void> _fetchAvailableImeis(String query) async {
    if (productId == null) {
      setState(() {
        availableImeis = [];
      });
      return;
    }

    try {
      final supabase = widget.tenantClient;
      final response = await supabase
          .from('products')
          .select('imei')
          .eq('product_id', productId!)
          .eq('status', 'Tồn kho')
          .ilike('imei', '%$query%')
          .limit(10);

      final imeiListFromDb = response
          .map((e) => e['imei'] as String?)
          .whereType<String>()
          .toList();

      final filteredImeis = imeiListFromDb
          .where((imei) => !imeiList.contains(imei))
          .toList()
        ..sort();

      setState(() {
        availableImeis = filteredImeis;
      });
    } catch (e) {
      print('Error fetching IMEI suggestions: $e');
      setState(() {
        availableImeis = [];
      });
    }
  }

  // Check for duplicate IMEIs
  String? _checkDuplicateImeis(String input) {
    final trimmedInput = input.trim();
    if (imeiList.contains(trimmedInput)) {
      return 'IMEI "$trimmedInput" đã được nhập!';
    }
    return null;
  }

  // Check inventory status of IMEI
  Future<String?> _checkInventoryStatus(String input) async {
    if (productId == null) return 'Vui lòng chọn sản phẩm!';
    if (input.trim().isEmpty) return null;

    try {
      final supabase = widget.tenantClient;
      final productResponse = await supabase
          .from('products')
          .select('status, product_id')
          .eq('imei', input.trim())
          .eq('product_id', productId!)
          .maybeSingle();

      if (productResponse == null || productResponse['status'] != 'Tồn kho') {
        final productName = CacheUtil.getProductName(productId);
        return 'IMEI "$input" không tồn tại, không thuộc sản phẩm "$productName", hoặc không ở trạng thái Tồn kho!';
      }
      return null;
    } catch (e) {
      return 'Lỗi khi kiểm tra IMEI "$input": $e';
    }
  }

  // Create snapshot for transfer
  Future<Map<String, dynamic>> _createSnapshot(String ticketId, List<String> imeiList) async {
    final supabase = widget.tenantClient;
    final snapshotData = <String, dynamic>{};

    if (transporter != null) {
      final transporterData = await supabase
          .from('transporters')
          .select()
          .eq('name', transporter!)
          .single();
      snapshotData['transporters'] = transporterData;
    }

    if (imeiList.isNotEmpty) {
      final productsData = await supabase
          .from('products')
          .select()
          .inFilter('imei', imeiList);
      snapshotData['products'] = productsData;
    }

    snapshotData['transporter_orders'] = [
      {
        'id': ticketId,
        'imei': imeiList.join(','),
        'product_id': productId,
        'product_name': CacheUtil.getProductName(productId),
        'transporter': transporter,
        'transport_fee': 0,
        'type': 'chuyển kho quốc tế',
      }
    ];

    return snapshotData;
  }

  // Hàm phát âm thanh beep
  void _playBeepSound() {
    SystemSound.play(SystemSoundType.click);
  }

  // Scan QR code for IMEI
  Future<void> _scanQRCode() async {
    try {
      final scannedData = await Navigator.push<String?>(
        context,
        MaterialPageRoute(builder: (context) => const QRCodeScannerScreen()),
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
      if (mounted) {
        await showDialog(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('Thông báo'),
            content: Text('Lỗi khi quét QR code: $e'),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('Đóng'),
              ),
            ],
          ),
        );
      }
    }
  }

  // Scan text for IMEI
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
      if (mounted) {
        await showDialog(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('Thông báo'),
            content: Text('Lỗi khi quét text: $e'),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('Đóng'),
              ),
            ],
          ),
        );
      }
    }
  }

  // Show confirmation dialog
  void showConfirmDialog() {
    if (isSubmitting) return;

    if (transporter == null || productId == null || imeiList.isEmpty) {
      showDialog(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Thông báo'),
          content: const Text('Vui lòng điền đầy đủ thông tin!'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Đóng'),
            ),
          ],
        ),
      );
      return;
    }

    if (imeiList.length > maxImeiQuantity) {
      showDialog(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Thông báo'),
          content: Text('Số lượng IMEI (${formatNumberLocal(imeiList.length)}) vượt quá giới hạn (${formatNumberLocal(maxImeiQuantity)}). Vui lòng chia thành nhiều phiếu.'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Đóng'),
            ),
          ],
        ),
      );
      return;
    }

    showDialog(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Xác nhận chuyển kho quốc tế'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Đơn vị vận chuyển: ${transporter ?? 'Không xác định'}'),
              Text('Sản phẩm: ${CacheUtil.getProductName(productId)}'),
              Text('Danh sách IMEI:'),
              ...imeiList.map((imei) => Text('- $imei')),
              Text('Số lượng: ${imeiList.length}'),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('Sửa lại'),
          ),
          ElevatedButton(
            onPressed: () async {
              Navigator.pop(dialogContext);
              await saveTransfer(imeiList);
            },
            child: const Text('Tạo phiếu'),
          ),
        ],
      ),
    );
  }

  // Save transfer to Supabase
  Future<void> saveTransfer(List<String> imeiList) async {
    if (isSubmitting) return;

    setState(() {
      isSubmitting = true;
    });

    try {
      final supabase = widget.tenantClient;
      final now = DateTime.now();

      // Validate input
      if (transporter == null || productId == null || imeiList.isEmpty) {
        throw Exception('Thông tin không đầy đủ: Vui lòng kiểm tra đơn vị vận chuyển, sản phẩm và IMEI.');
      }

      // Create ticketId
      final ticketId = uuid.v4();

      // Create snapshot first
      developer.log('Creating snapshot for ticket $ticketId with ${imeiList.length} IMEIs');
      final snapshotData = await _createSnapshot(ticketId, imeiList);

      // Prepare transporter order data
      final transporterOrder = {
        'id': ticketId,
        'imei': imeiList.join(','),
        'product_id': productId,
        'transporter': transporter,
        'transport_fee': 0,
        'type': 'chuyển kho quốc tế',
        'created_at': now.toIso8601String(),
        'iscancelled': false,
      };

      // Prepare batch updates for products
      const batchSize = 1000;
      final batches = <List<String>>[];
      developer.log('Preparing batches for ${imeiList.length} IMEIs with batch size $batchSize');
      for (var i = 0; i < imeiList.length; i += batchSize) {
        final endIndex = math.min(i + batchSize, imeiList.length);
        batches.add(imeiList.sublist(i, endIndex));
        developer.log('Created batch from index $i to $endIndex with ${batches.last.length} IMEIs');
      }

      // Execute operations directly instead of using execute_transaction RPC
      developer.log('Executing operations with ${batches.length} batches');

      // Insert snapshot
      await supabase.from('snapshots').insert({
        'ticket_id': ticketId,
        'ticket_table': 'transporter_orders',
        'snapshot_data': snapshotData,
        'created_at': now.toIso8601String(),
      });

      // Insert transporter order
      await supabase.from('transporter_orders').insert(transporterOrder);

      // Update products in batches
      for (var batch in batches) {
        developer.log('Updating products for batch with ${batch.length} IMEIs');
        await supabase
            .from('products')
            .update({
              'status': 'đang vận chuyển',
              'transporter': transporter,
              'send_transfer_date': now.toIso8601String(),
            })
            .inFilter('imei', batch);
      }

      // Send push notification
      await NotificationService.showNotification(
        140,
        "Đã tạo phiếu vận chuyển quốc tế",
        "Đã tạo phiếu vận chuyển quốc tế sản phẩm ${CacheUtil.getProductName(productId)} số lượng ${formatNumberLocal(imeiList.length)}",
        'transfer_global_created',
      );

      if (mounted) {
        await showDialog(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('Thông báo'),
            content: const Text('Đã tạo phiếu chuyển kho quốc tế và cập nhật trạng thái'),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('Đóng'),
              ),
            ],
          ),
        );

        setState(() {
          transporter = null;
          productId = null;
          imei = '';
          productController.text = '';
          imeiController.text = '';
          imeiList = [];
          imeiError = null;
          isSubmitting = false;
        });

        await _fetchInitialData();
      }
    } catch (e) {
      print('Error saving transfer: $e');
      if (mounted) {
        await showDialog(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('Thông báo'),
            content: Text('Lỗi khi tạo phiếu: $e'),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('Đóng'),
              ),
            ],
          ),
        );
        setState(() {
          isSubmitting = false;
        });
      }
    }
  }

  // Format number for display
  String formatNumberLocal(num value) {
    return NumberFormat('#,###', 'vi_VN').format(value).replaceAll(',', '.');
  }

  // Wrap field with styled container
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

  // Build the UI
  @override
  Widget build(BuildContext context) {
    if (isLoading) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }

    if (errorMessage != null) {
      return Scaffold(
        body: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Text(errorMessage!),
              const SizedBox(height: 16),
              ElevatedButton(
                onPressed: _fetchInitialData,
                child: const Text('Thử lại'),
              ),
            ],
          ),
        ),
      );
    }

    return Scaffold(
      appBar: AppBar(
        title: const Text('Phiếu chuyển kho quốc tế', style: TextStyle(color: Colors.white)),
        backgroundColor: Colors.black,
        iconTheme: const IconThemeData(color: Colors.white),
        leading: IconButton(
          icon: Transform.rotate(
            angle: math.pi,
            child: const Icon(Icons.arrow_forward_ios, color: Colors.white),
          ),
          onPressed: () => Navigator.pop(context),
        ),
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            wrapField(
              Autocomplete<String>(
                optionsBuilder: (TextEditingValue textEditingValue) {
                  final query = textEditingValue.text.toLowerCase();
                  if (query.isEmpty) return transporters.take(10).toList();
                  final filtered = transporters
                      .where((option) => option.toLowerCase().contains(query))
                      .toList()
                    ..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
                  return filtered.isNotEmpty ? filtered.take(10).toList() : ['Không tìm thấy đơn vị vận chuyển'];
                },
                onSelected: (String selection) {
                  if (selection != 'Không tìm thấy đơn vị vận chuyển') {
                    setState(() {
                      transporter = selection;
                    });
                  }
                },
                fieldViewBuilder: (context, controller, focusNode, onFieldSubmitted) {
                  controller.text = transporter ?? '';
                  return TextField(
                    controller: controller,
                    focusNode: focusNode,
                    onChanged: (value) {
                      setState(() {
                        transporter = value.isNotEmpty ? value : null;
                      });
                    },
                    decoration: const InputDecoration(
                      labelText: 'Đơn vị vận chuyển',
                      border: InputBorder.none,
                      isDense: true,
                    ),
                  );
                },
              ),
            ),
            wrapField(
              Autocomplete<Map<String, dynamic>>(
                optionsBuilder: (TextEditingValue textEditingValue) {
                  final query = textEditingValue.text.toLowerCase();
                  if (query.isEmpty) return products.take(10).toList();
                  final filtered = products
                      .where((option) => (option['name'] as String).toLowerCase().contains(query))
                      .toList()
                    ..sort((a, b) {
                      final aName = (a['name'] as String).toLowerCase();
                      final bName = (b['name'] as String).toLowerCase();
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
                  return filtered.isNotEmpty ? filtered.take(10).toList() : [{'id': '', 'name': 'Không tìm thấy sản phẩm'}];
                },
                displayStringForOption: (option) => option['name'] as String,
                onSelected: (val) {
                  if (val['id'].isNotEmpty) {
                    setState(() {
                      productId = val['id'] as String;
                      productController.text = val['name'] as String;
                      imei = '';
                      imeiController.text = '';
                      imeiError = null;
                      imeiList = [];
                    });
                    _fetchAvailableImeis('');
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
                    onEditingComplete: onFieldSubmitted,
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
              Column(
                children: [
                  // Phần nhập IMEI
                  Expanded(
                    child: Autocomplete<String>(
                      optionsBuilder: (TextEditingValue textEditingValue) {
                        final query = textEditingValue.text.toLowerCase();
                        if (productId == null) return ['Vui lòng chọn sản phẩm'];
                        if (query.isEmpty) return availableImeis.take(10).toList();
                        final filtered = availableImeis
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
                        _fetchAvailableImeis('');
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
                            _fetchAvailableImeis(value);
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
                            _fetchAvailableImeis('');
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
            const SizedBox(height: 20),
            ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.blue,
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 24),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              ),
              onPressed: showConfirmDialog,
              child: const Text('Xác nhận'),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _rollbackChanges(Map<String, dynamic> snapshot, String ticketId) async {
    final supabase = widget.tenantClient;
    
    try {
      // Rollback transporters
      if (snapshot['transporters'] != null) {
        await supabase
          .from('transporters')
          .update(snapshot['transporters'])
          .eq('name', snapshot['transporters']['name']);
      }

      // Rollback products
      if (snapshot['products'] != null) {
        for (var product in snapshot['products']) {
          await supabase
            .from('products')
            .update(product)
            .eq('imei', product['imei']);
        }
      }

      // Delete created transporter orders
      await supabase
        .from('transporter_orders')
        .delete()
        .eq('id', ticketId);

    } catch (e) {
      print('Error during rollback: $e');
      throw Exception('Lỗi khi rollback dữ liệu: $e');
    }
  }

  Future<bool> _verifyData(String ticketId, List<String> imeiList) async {
    final supabase = widget.tenantClient;
    
    try {
      // Verify products data
      final productsData = await supabase
          .from('products')
          .select('status, transporter')
          .inFilter('imei', imeiList);
      
      // Verify transporter orders
      final transporterOrders = await supabase
          .from('transporter_orders')
          .select()
          .eq('id', ticketId);

      // Verify all IMEIs are marked as being transported and assigned to correct transporter
      for (var product in productsData) {
        if (product['status'] != 'Đang vận chuyển' || 
            product['transporter'] != transporter) {
          return false;
        }
      }

      // Verify transporter order is created
      if (transporterOrders.isEmpty) {
        return false;
      }

      // Verify transporter data
      if (transporter != null) {
        final transporterData = await supabase
            .from('transporters')
            .select()
            .eq('name', transporter!)
            .single();
        if (transporterData == null) return false;
      }

      return true;
    } catch (e) {
      print('Error during data verification: $e');
      return false;
    }
  }

  Future<void> _submitTransfer() async {
    if (isSubmitting) return;

    if (transporter == null) {
      setState(() {
        errorMessage = 'Vui lòng chọn đơn vị vận chuyển!';
      });
      return;
    }

    if (imeiList.isEmpty) {
      setState(() {
        errorMessage = 'Vui lòng thêm ít nhất một IMEI!';
      });
      return;
    }

    if (imeiList.length > maxImeiQuantity) {
      setState(() {
        errorMessage = 'Số lượng IMEI (${imeiList.length}) vượt quá $maxImeiQuantity. Vui lòng chia thành nhiều phiếu nhỏ hơn.';
      });
      return;
    }

    setState(() {
      isSubmitting = true;
      errorMessage = null;
    });

    try {
      final supabase = widget.tenantClient;
      final now = DateTime.now();
      final ticketId = uuid.v4();

      // Create snapshot before any changes
      Map<String, dynamic> snapshot;
      try {
        snapshot = await _createSnapshot(ticketId, imeiList);
      } catch (e) {
        setState(() {
          isSubmitting = false;
          errorMessage = 'Lỗi khi tạo snapshot: $e';
        });
        return;
      }

      try {
        // Execute transaction
        await supabase.rpc('execute_transaction', params: {
          'operations': [
            {
              'type': 'insert',
              'table': 'snapshots',
              'data': {
                'ticket_id': ticketId,
                'ticket_table': 'transporter_orders',
                'snapshot_data': snapshot,
                'created_at': now.toIso8601String(),
              },
            },
            {
              'type': 'insert',
              'table': 'transporter_orders',
              'data': {
                'id': ticketId,
                'imei': imeiList.join(','),
                'product_id': productId,
                'product_name': CacheUtil.getProductName(productId),
                'transporter': transporter,
                'transport_fee': 0,
                'type': 'chuyển kho quốc tế',
                'created_at': now.toIso8601String(),
                'iscancelled': false,
              },
            },
            {
              'type': 'update',
              'table': 'products',
              'condition': {'imei': imeiList},
              'data': {
                'status': 'Đang vận chuyển',
                'transporter': transporter,
                'transport_date': now.toIso8601String(),
              },
            },
          ],
        });

        // After all updates, verify the data
        final isDataValid = await _verifyData(ticketId, imeiList);
        if (!isDataValid) {
          // If data verification fails, rollback changes
          await _rollbackChanges(snapshot, ticketId);
          throw Exception('Dữ liệu không khớp sau khi cập nhật. Đã rollback thay đổi.');
        }

        // Success notification
        await NotificationService.showNotification(
          137,
          'Phiếu Chuyển Kho Quốc Tế Đã Tạo',
          'Đã chuyển ${imeiList.length} sản phẩm ${CacheUtil.getProductName(productId)} cho ${transporter}',
          'transfer_global_created',
        );

        if (mounted) {
          Navigator.pop(context);
        }

      } catch (e) {
        // If any error occurs, rollback changes
        try {
          await _rollbackChanges(snapshot, ticketId);
        } catch (rollbackError) {
          print('Rollback failed: $rollbackError');
        }

        if (mounted) {
          setState(() {
            isSubmitting = false;
            errorMessage = e.toString();
          });
        }
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          isSubmitting = false;
          errorMessage = e.toString();
        });
      }
    }
  }
}

// QR code scanner screen
class QRCodeScannerScreen extends StatefulWidget {
  const QRCodeScannerScreen({super.key});

  @override
  QRCodeScannerScreenState createState() => QRCodeScannerScreenState();
}

// State class for QRCodeScannerScreen
class QRCodeScannerScreenState extends State<QRCodeScannerScreen> {
  final MobileScannerController controller = MobileScannerController(
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
        children: [
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
            child: const Center(
              child: Text(
                'Quét QR code để lấy IMEI',
                style: TextStyle(fontSize: 18, color: Colors.black),
              ),
            ),
          ),
        ],
      ),
    );
  }
}