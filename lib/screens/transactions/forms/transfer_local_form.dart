import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:intl/intl.dart';
import 'package:uuid/uuid.dart';
import 'dart:math' as math;
import 'dart:developer' as developer; // Added import
import '../../notification_service.dart';
import 'package:flutter/services.dart';
import '../../text_scanner_screen.dart';
import '../../../helpers/error_handler.dart';

// Utility class for caching product names
class CacheUtil {
  static final Map<String, String> productNameCache = {};
  static final Map<String, String> warehouseNameCache = {};

  static void cacheProductName(String id, String name) => productNameCache[id] = name;
  static String getProductName(String? id) => id != null ? productNameCache[id] ?? 'Không xác định' : 'Không xác định';
  static void cacheWarehouseName(String id, String name) => warehouseNameCache[id] = name;
  static String getWarehouseName(String? id) => id != null ? warehouseNameCache[id] ?? 'Không xác định' : 'Không xác định';
}

// Constants for IMEI handling
const int maxImeiQuantity = 100000;
const int displayImeiLimit = 100;

// Main widget for local transfer form
class TransferLocalForm extends StatefulWidget {
  final SupabaseClient tenantClient;

  const TransferLocalForm({super.key, required this.tenantClient});

  @override
  State<TransferLocalForm> createState() => _TransferLocalFormState();
}

// State class for TransferLocalForm
class _TransferLocalFormState extends State<TransferLocalForm> {
  String? transporter;
  String? productId;
  String? imei = '';
  List<String> imeiList = [];
  List<String> transporters = [];
  List<Map<String, dynamic>> products = [];
  List<String> availableImeis = [];
  List<Map<String, dynamic>> warehouses = [];
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
          .eq('type', 'vận chuyển nội địa');
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

      // Fetch warehouses
      final warehouseResponse = await supabase
          .from('warehouses')
          .select('id, name');
      final warehouseList = warehouseResponse
          .map((e) {
            final id = e['id'] as String?;
            final name = e['name'] as String?;
            if (id != null && name != null) {
              CacheUtil.cacheWarehouseName(id, name);
              return {'id': id, 'name': name};
            }
            return null;
          })
          .whereType<Map<String, dynamic>>()
          .toList()
        ..sort((a, b) => (a['name'] ?? '').toLowerCase().compareTo((b['name'] ?? '')));

      if (mounted) {
        setState(() {
          transporters = transporterList;
          products = productList;
          warehouses = warehouseList;
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
        'type': 'chuyển kho nội địa',
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

  // Show Auto IMEI dialog
  Future<void> _showAutoImeiDialog() async {
    int? localQuantity;
    String? localWarehouseId;
    String? selectedWarehouseId;
    final TextEditingController localQuantityController = TextEditingController();
    final TextEditingController localWarehouseController = TextEditingController();

    await showDialog(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Auto IMEI'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextFormField(
                controller: localQuantityController,
                keyboardType: TextInputType.number,
                onChanged: (val) {
                  localQuantity = int.tryParse(val);
                },
                decoration: const InputDecoration(
                  labelText: 'Số lượng',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 8),
              Autocomplete<Map<String, dynamic>>(
                optionsBuilder: (TextEditingValue textEditingValue) {
                  final query = textEditingValue.text.toLowerCase();
                  if (query.isEmpty) return warehouses.take(10).toList();
                  final filtered = warehouses
                      .where((option) => (option['name'] as String).toLowerCase().contains(query))
                      .toList()
                    ..sort((a, b) => (a['name'] as String).toLowerCase().compareTo((b['name'] as String).toLowerCase()));
                  return filtered.isNotEmpty ? filtered.take(10).toList() : [{'id': '', 'name': 'Không tìm thấy kho'}];
                },
                displayStringForOption: (option) => option['name'] as String,
                onSelected: (val) {
                  if (val['id'].isEmpty) return;
                  localWarehouseId = val['id'] as String;
                  selectedWarehouseId = val['id'] as String;
                  localWarehouseController.text = val['name'] as String;
                },
                fieldViewBuilder: (context, controller, focusNode, onFieldSubmitted) {
                  controller.text = localWarehouseController.text;
                  return TextFormField(
                    controller: controller,
                    focusNode: focusNode,
                    onChanged: (value) {
                      localWarehouseController.text = value;
                    },
                    decoration: const InputDecoration(
                      labelText: 'Kho gửi đi',
                      border: OutlineInputBorder(),
                    ),
                  );
                },
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('Hủy'),
          ),
          ElevatedButton(
            onPressed: () async {
              if (localQuantity == null || localQuantity! <= 0) {
                showDialog(
                  context: dialogContext,
                  builder: (ctx) => AlertDialog(
                    title: const Text('Thông báo'),
                    content: const Text('Vui lòng nhập số lượng hợp lệ!'),
                    actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Đóng'))],
                  ),
                );
                return;
              }
              if (localWarehouseId == null || localWarehouseId!.trim().isEmpty) {
                showDialog(
                  context: dialogContext,
                  builder: (ctx) => AlertDialog(
                    title: const Text('Thông báo'),
                    content: const Text('Vui lòng chọn kho gửi đi!'),
                    actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Đóng'))],
                  ),
                );
                return;
              }
              Navigator.pop(dialogContext);
              await _autoFetchImeis(localQuantity!, selectedWarehouseId!);
            },
            child: const Text('Tìm'),
          ),
        ],
      ),
    );
  }

  // Auto fetch IMEIs based on quantity and warehouse
  Future<void> _autoFetchImeis(int qty, String warehouseId) async {
    setState(() {
      isLoading = true;
    });

    try {
      final supabase = widget.tenantClient;
      
      // ✅ FIX: Lấy gấp đôi để đảm bảo đủ sau khi lọc duplicate
      final fetchQuantity = qty * 2;
      
      final response = await supabase
          .from('products')
          .select('imei, import_date')
          .eq('product_id', productId!)
          .eq('warehouse_id', warehouseId)
          .eq('status', 'Tồn kho')
          .order('import_date', ascending: true)  // FIFO - Lấy hàng cũ nhất trước
          .limit(fetchQuantity);

      final fetchedImeis = response
          .map((e) => e['imei'] as String?)
          .whereType<String>()
          .where((imei) => imei != null && imei.trim().isNotEmpty && !imeiList.contains(imei))
          .cast<String>()
          .take(qty)  // ✅ FIX: Chỉ lấy đúng số lượng sau khi lọc
          .toList();

      if (fetchedImeis.length < qty) {
        // Check tổng số lượng có trong kho
        final totalCountResponse = await supabase
            .from('products')
            .select('imei')
            .eq('product_id', productId!)
            .eq('warehouse_id', warehouseId)
            .eq('status', 'Tồn kho')
            .count(CountOption.exact);
        
        final totalCount = totalCountResponse.count;
        
        if (mounted) {
          await showDialog(
            context: context,
            builder: (ctx) => AlertDialog(
              title: const Text('Thông báo'),
              content: Text(
                'Số lượng sản phẩm tồn kho không đủ!\n\n'
                'Cần: $qty sản phẩm\n'
                'Có trong kho: $totalCount sản phẩm\n'
                'Đã nhập: ${imeiList.length} sản phẩm\n'
                'Có thể lấy thêm: ${fetchedImeis.length} sản phẩm\n\n'
                'Sản phẩm: "${CacheUtil.getProductName(productId)}"\n'
                'Kho: "${CacheUtil.getWarehouseName(warehouseId)}"'
              ),
              actions: [
                if (fetchedImeis.isNotEmpty)
                  TextButton(
                    onPressed: () {
                      Navigator.pop(ctx);
                      setState(() {
                        imeiList.addAll(fetchedImeis);
                        isLoading = false;
                      });
                    },
                    child: Text('Lấy ${fetchedImeis.length} sản phẩm'),
                  ),
                TextButton(
                  onPressed: () {
                    Navigator.pop(ctx);
                    setState(() {
                      isLoading = false;
                    });
                  },
                  child: const Text('Đóng'),
                ),
              ],
            ),
          );
        }
        setState(() {
          isLoading = false;
        });
        return;
      }

      setState(() {
        imeiList.addAll(fetchedImeis);
        isLoading = false;
      });
    } catch (e) {
      if (mounted) {
        showDialog(
          context: context,
          builder: (ctx) => AlertDialog(
            title: const Text('Lỗi'),
            content: Text('Không thể tải IMEI: $e'),
            actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Đóng'))],
          ),
        );
      }
      setState(() {
        isLoading = false;
      });
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
        title: const Text('Xác nhận chuyển kho nội địa'),
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

      // Get warehouse_id from first IMEI
      String? originWarehouseId;
      if (imeiList.isNotEmpty) {
        final firstImeiData = await supabase
            .from('products')
            .select('warehouse_id')
            .eq('imei', imeiList.first)
            .maybeSingle();
        originWarehouseId = firstImeiData?['warehouse_id']?.toString();
      }

      // Prepare transporter order data
      final transporterOrder = {
        'id': ticketId,
        'imei': imeiList.join(','),
        'product_id': productId,
        'transporter': transporter,
        'transport_fee': 0,
        'type': 'chuyển kho nội địa',
        'warehouse_id': originWarehouseId,
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
        139,
        "Đã tạo phiếu vận chuyển nội địa",
        "Đã tạo phiếu vận chuyển nội địa sản phẩm ${CacheUtil.getProductName(productId)} số lượng ${formatNumberLocal(imeiList.length)}",
        'transfer_local_created',
      );

      if (mounted) {
        await showDialog(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('Thông báo'),
            content: const Text('Đã tạo phiếu chuyển kho nội địa và cập nhật trạng thái'),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('Đóng'),
              ),
            ],
          ),
        );

        // Reset sau khi đóng dialog
        if (mounted) {
          setState(() {
            transporter = null;
            productId = null;
            imei = '';
            imeiList.clear(); // Use clear() instead of = []
            imeiError = null;
            isSubmitting = false;
          });
          
          // Clear controllers
          productController.clear();
          imeiController.clear();
        }
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
        title: const Text('Phiếu chuyển kho nội địa', style: TextStyle(color: Colors.white)),
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
            Stack(
              children: [
                // Ô sản phẩm chiếm toàn bộ chiều ngang
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
                // Nút Auto IMEI nằm đè lên góc phải
                Positioned(
                  right: 8,
                  top: 0,
                  bottom: 0,
                  child: Center(
                    child: ElevatedButton(
                      onPressed: productId != null ? _showAutoImeiDialog : null,
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.blue,
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(6),
                        ),
                      ),
                      child: const Text('Auto IMEI', style: TextStyle(fontSize: 12)),
                    ),
                  ),
                ),
              ],
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