import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import '../../notification_service.dart';
import 'dart:async';
import 'dart:math' as math;
import '../../text_scanner_screen.dart';
import '../../../helpers/error_handler.dart';

// Cache utility class
class CacheUtil {
  static final Map<String, String> productNameCache = {};
  static final Map<String, String> warehouseNameCache = {};

  static void cacheProductName(String id, String name) => productNameCache[id] = name;
  static void cacheWarehouseName(String id, String name) => warehouseNameCache[id] = name;
  static String getProductName(String? id) => id != null ? productNameCache[id] ?? 'Không xác định' : 'Không xác định';
  static String getWarehouseName(String? id) => id != null ? warehouseNameCache[id] ?? 'Không xác định' : 'Không xác định';
}

// Constants for IMEI handling
const int maxImeiQuantity = 100000;
const int warnImeiQuantity = 10000;
const int batchSize = 1000;
const int displayImeiLimit = 100;
const int maxRetries = 3;
const Duration retryDelay = Duration(seconds: 1);
const int queryLimit = 50;

// Retries a function with exponential backoff
Future<T> retry<T>(Future<T> Function() fn, {String? operation}) async {
  for (int attempt = 0; attempt < maxRetries; attempt++) {
    try {
      return await fn();
    } catch (e) {
      if (attempt == maxRetries - 1) {
        throw Exception('${operation ?? 'Operation'} failed after $maxRetries attempts: $e');
      }
      await Future.delayed(retryDelay * math.pow(2, attempt));
    }
  }
  throw Exception('Retry failed');
}

class ThousandsFormatterLocal extends TextInputFormatter {
  @override
  TextEditingValue formatEditUpdate(TextEditingValue oldValue, TextEditingValue newValue) {
    String newText = newValue.text.replaceAll('.', '');
    if (newText.isEmpty) return newValue;
    final doubleValue = double.tryParse(newText);
    if (doubleValue == null) return oldValue;
    final formatted = NumberFormat('#,###', 'vi_VN').format(doubleValue).replaceAll(',', '.');
    return TextEditingValue(
      text: formatted,
      selection: TextSelection.collapsed(offset: formatted.length),
    );
  }
}

String formatNumberLocal(num value) {
  return NumberFormat('#,###', 'vi_VN').format(value).replaceAll(',', '.');
}

class ReimportForm extends StatefulWidget {
  final SupabaseClient tenantClient;

  const ReimportForm({super.key, required this.tenantClient});

  @override
  State<ReimportForm> createState() => _ReimportFormState();
}

class _ReimportFormState extends State<ReimportForm> {
  String? selectedTarget = 'Khách Hàng';
  String? productId;
  String? imei = '';
  String? price;
  String? currency;
  String? account;
  String? note;
  String? warehouseId;
  List<Map<String, dynamic>> addedItems = [];
  List<String> imeiSuggestions = [];

  List<String> fixers = [];
  List<Map<String, dynamic>> products = [];
  List<String> currencies = [];
  List<Map<String, dynamic>> accounts = [];
  List<String> accountNames = [];
  List<Map<String, dynamic>> warehouses = [];
  List<String> customers = [];
  Map<String, String> customerIdMap = {}; // Map customer name to id
  List<String> usedImeis = [];
  bool isLoading = true;
  String? errorMessage;
  String? imeiError;
  bool isImeiManual = true;

  final TextEditingController imeiController = TextEditingController();
  final TextEditingController priceController = TextEditingController();
  final TextEditingController productController = TextEditingController();
  late final FocusNode imeiFocusNode;
  Timer? _debounce;

  final NumberFormat numberFormat = NumberFormat.decimalPattern('vi_VN');

  @override
  void initState() {
    super.initState();
    imeiFocusNode = FocusNode();
    _fetchInitialData();
    imeiController.text = imei ?? '';
    priceController.text = price ?? '';
  }

  @override
  void dispose() {
    imeiController.dispose();
    priceController.dispose();
    productController.dispose();
    imeiFocusNode.dispose();
    _debounce?.cancel();
    super.dispose();
  }

  Future<void> _fetchInitialData() async {
    setState(() {
      isLoading = true;
      errorMessage = null;
    });

    try {
      final supabase = widget.tenantClient;

      // Fetch warehouses
      final warehouseResponse = await retry(
        () => supabase.from('warehouses').select('id, name'),
        operation: 'Fetch initial warehouses',
      );
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

      // Fetch currencies
      final currencyResponse = await retry(
        () => supabase.from('financial_accounts').select('currency').neq('currency', ''),
        operation: 'Fetch currencies',
      );
      final uniqueCurrencies = currencyResponse
          .map((e) => e['currency'] as String?)
          .whereType<String>()
          .toSet()
          .toList()
        ..sort();

      // Fetch accounts
      final accountResponse = await retry(
        () => supabase.from('financial_accounts').select('name, currency, balance'),
        operation: 'Fetch accounts',
      );
      final accountList = accountResponse
          .map((e) => {
                'name': e['name'] as String?,
                'currency': e['currency'] as String?,
                'balance': (e['balance'] as num?)?.toDouble() ?? 0.0,
              })
          .where((e) => e['name'] != null && e['currency'] != null)
          .cast<Map<String, dynamic>>()
          .toList();

      // Fetch products
      final productResponse = await retry(
        () => supabase.from('products_name').select('id, products'),
        operation: 'Fetch products',
      );
      final productList = productResponse
          .map((e) => {'id': e['id'].toString(), 'name': e['products'] as String})
          .toList()
        ..sort((a, b) => (a['name'] as String).toLowerCase().compareTo((b['name'] as String).toLowerCase()));

      // Fetch customers
      final customerResponse = await retry(
        () => supabase.from('customers').select('id, name'),
        operation: 'Fetch customers',
      );
      final customerList = customerResponse
          .map((e) => e['name'] as String?)
          .whereType<String>()
          .toList()
        ..sort();
      // Build customer id map
      final customerIdMapTemp = <String, String>{};
      for (var e in customerResponse) {
        final name = e['name'] as String?;
        final id = e['id']?.toString();
        if (name != null && id != null) {
          customerIdMapTemp[name] = id;
        }
      }

      if (mounted) {
        setState(() {
          warehouses = warehouseList;
          usedImeis = [];
          currencies = uniqueCurrencies;
          accounts = accountList;
          products = productList;
          customers = customerList;
          customerIdMap = customerIdMapTemp;
          currency = uniqueCurrencies.contains('VND') ? 'VND' : uniqueCurrencies.isNotEmpty ? uniqueCurrencies.first : null;
          _updateAccountNames(currency);
          isLoading = false;
          for (var product in productList) {
            CacheUtil.cacheProductName(product['id'] as String, product['name'] as String);
          }
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          errorMessage = 'Không thể tải dữ liệu từ Supabase: $e';
          isLoading = false;
        });
      }
    }
  }

  void _updateAccountNames(String? selectedCurrency) {
    if (selectedCurrency == null) {
      setState(() {
        accountNames = [];
        account = null;
      });
      return;
    }

    final filteredAccounts = accounts
        .where((acc) => acc['currency'] == selectedCurrency)
        .map((acc) => acc['name'] as String)
        .toList();
    filteredAccounts.add('Công nợ');

    setState(() {
      accountNames = filteredAccounts;
      account = null;
    });
  }

  Future<void> _fetchAvailableImeis(String query) async {
    if (productId == null) {
      setState(() {
        imeiSuggestions = [];
      });
      return;
    }

    try {
      final supabase = widget.tenantClient;
      final response = await supabase
          .from('products')
          .select('imei')
          .eq('product_id', productId!)
          .eq('status', 'Đã bán')
          .ilike('imei', '%$query%')
          .limit(10);

      final imeiListFromDb = response
          .map((e) => e['imei'] as String?)
          .whereType<String>()
          .where((imei) => !addedItems.any((item) => item['imei'] == imei))
          .toList()
        ..sort();

      if (mounted) {
        setState(() {
          imeiSuggestions = imeiListFromDb;
        });
      }
    } catch (e) {
      debugPrint('Lỗi khi tải gợi ý IMEI: $e');
      if (mounted) {
        setState(() {
          imeiSuggestions = [];
        });
      }
    }
  }

  Future<String?> _checkDuplicateImeis(String input) async {
    if (addedItems.any((item) => item['imei'] == input)) {
      return 'IMEI "$input" đã được nhập!';
    }
    return null;
  }


  Future<void> _addImeiToList(String input) async {
    if (input.trim().isEmpty || productId == null) {
      setState(() {
        imeiError = 'Vui lòng chọn sản phẩm và nhập IMEI!';
      });
      return;
    }

    final duplicateError = await _checkDuplicateImeis(input);
    if (duplicateError != null) {
      setState(() {
        imeiError = duplicateError;
      });
      return;
    }

    try {
      final supabase = widget.tenantClient;
      final response = await retry(
        () => supabase
            .from('sale_orders')
            .select('customer, customer_price, transporter_price, price, currency, account')
            .eq('product_id', productId!)
            .like('imei', '%$input%')
            .order('created_at', ascending: false)
            .limit(1)
            .maybeSingle(),
        operation: 'Fetch sale order',
      );

      if (response == null) {
        setState(() {
          imeiError = 'Không tìm thấy giao dịch bán cho IMEI "$input"!';
        });
        return;
      }

      // Lấy thông tin tiền cọc và tiền COD từ bảng products
      final productResponse = await retry(
        () => supabase
            .from('products')
            .select('customer_price, transporter_price, transporter, sale_date')
            .eq('imei', input)
            .single(),
        operation: 'Fetch product data',
      );

      print('Product data for IMEI $input: $productResponse');

      final price = response['price'] != null
          ? (response['price'] is num
              ? (response['price'] as num).toDouble()
              : double.tryParse(response['price'].toString()) ?? 0.0)
          : 0.0;

      final customerPrice = productResponse['customer_price'] != null
          ? (productResponse['customer_price'] is num
              ? (productResponse['customer_price'] as num).toDouble()
              : double.tryParse(productResponse['customer_price'].toString()) ?? 0.0)
          : 0.0;

      final transporterPrice = productResponse['transporter_price'] != null
          ? (productResponse['transporter_price'] is num
              ? (productResponse['transporter_price'] as num).toDouble()
              : double.tryParse(productResponse['transporter_price'].toString()) ?? 0.0)
          : 0.0;

      final saleDate = productResponse['sale_date'] != null
          ? DateFormat('dd/MM/yyyy HH:mm').format(DateTime.parse(productResponse['sale_date'] as String))
          : 'Không xác định';

      print('Parsed prices for IMEI $input:');
      print('- Customer price: $customerPrice');
      print('- Transporter price: $transporterPrice');
      print('- Sale date: $saleDate');

      final currency = response['currency'] as String? ?? 'VND';

      if (selectedTarget == 'Khách Hàng' && price == 0) {
        setState(() {
          imeiError = 'Giá bán của IMEI "$input" không hợp lệ!';
        });
        return;
      }

      if (mounted) {
        setState(() {
          addedItems.add({
            'imei': input,
            'product_id': productId,
            'product_name': CacheUtil.getProductName(productId),
            'isCod': true,
            'customer': response['customer'] as String? ?? 'Không xác định',
            'customer_price': customerPrice,
            'transporter_price': transporterPrice,
            'transporter': productResponse['transporter'] as String? ?? 'Không xác định',
            'sale_price': price,
            'sale_currency': currency,
            'reimport_price': null,
            'sale_date': saleDate,
          });
          imei = '';
          imeiController.text = '';
          imeiError = null;
        });
      }
    } catch (e) {
      setState(() {
        imeiError = 'Lỗi khi lấy thông tin giao dịch: $e';
      });
    }
  }

  // Hàm phát âm thanh beep
  void _playBeepSound() {
    SystemSound.play(SystemSoundType.click);
  }

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
        });

        await _addImeiToList(scannedData);
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
        });

        await _addImeiToList(scannedData);
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

  Future<void> _showAutoImeiDialog() async {
    int? localQuantity;
    String? localCustomer;
    final TextEditingController localQuantityController = TextEditingController();
    final TextEditingController localCustomerController = TextEditingController();

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
              if (selectedTarget == 'Khách Hàng')
                Autocomplete<String>(
                  optionsBuilder: (TextEditingValue textEditingValue) {
                    final query = textEditingValue.text.toLowerCase();
                    if (query.isEmpty) return customers.take(10).toList();
                    final filtered = customers.where((option) => option.toLowerCase().contains(query)).toList()
                      ..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
                    return filtered.isNotEmpty ? filtered.take(10).toList() : ['Không tìm thấy khách hàng'];
                  },
                  onSelected: (String selection) {
                    if (selection != 'Không tìm thấy khách hàng') {
                      localCustomer = selection;
                      localCustomerController.text = selection;
                    }
                  },
                  fieldViewBuilder: (context, controller, focusNode, onFieldSubmitted) {
                    controller.text = localCustomerController.text;
                    return TextFormField(
                      controller: controller,
                      focusNode: focusNode,
                      onChanged: (value) {
                        localCustomer = value;
                      },
                      decoration: const InputDecoration(
                        labelText: 'Tên khách hàng',
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
              if (selectedTarget == 'Khách Hàng' && (localCustomer == null || localCustomer!.trim().isEmpty)) {
                showDialog(
                  context: dialogContext,
                  builder: (ctx) => AlertDialog(
                    title: const Text('Thông báo'),
                    content: const Text('Vui lòng nhập tên khách hàng!'),
                    actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Đóng'))],
                  ),
                );
                return;
              }
              Navigator.pop(dialogContext);
              await _autoFetchImeis(localQuantity!, localCustomer);
            },
            child: const Text('Tìm'),
          ),
        ],
      ),
    );
  }

  Future<void> _autoFetchImeis(int qty, String? cust) async {
    setState(() {
      isLoading = true;
    });

    try {
      final supabase = widget.tenantClient;
      var query = supabase
          .from('sale_orders')
          .select('imei, customer, customer_id, transporter, customer_price, transporter_price, price, currency, account, quantity')
          .eq('product_id', productId!);

      if (selectedTarget == 'Khách Hàng') {
        final customerId = customerIdMap[cust];
        if (customerId != null) {
          query = query.eq('customer_id', customerId).neq('account', 'Ship COD');
        } else {
          // Fallback to customer name if id not found
          query = query.eq('customer', cust!).neq('account', 'Ship COD');
        }
      } else {
        query = query.eq('account', 'Ship COD');
      }

      // Fetch more rows to ensure we have enough individual IMEIs
      final response = await query.order('created_at', ascending: false).limit(qty * 2);

      // Process all rows to collect individual IMEIs
      final List<Map<String, dynamic>> allItems = [];
      
      for (var item in response) {
        final imeiString = item['imei'] as String;
        
        // Split IMEI string by comma and trim spaces
        final individualImeis = imeiString.split(',').map((e) => e.trim()).where((e) => e.isNotEmpty).toList();
        
        for (var individualImei in individualImeis) {
          if (allItems.length >= qty) break;
          
          // Check for duplicates
          if (await _checkDuplicateImeis(individualImei) != null) continue;
          
          try {
            final productResponse = await retry(
              () => supabase
                  .from('products')
                  .select('customer_price, transporter_price, transporter, sale_date')
                  .eq('imei', individualImei)
                  .single(),
              operation: 'Fetch product data for IMEI $individualImei',
            );

            final price = item['price'] != null
                ? (item['price'] is num
                    ? (item['price'] as num).toDouble()
                    : double.tryParse(item['price'].toString()) ?? 0.0)
                : 0.0;

            // Price is already per-item, no need to divide by quantity
            final perItemPrice = price;

            final customerPrice = productResponse['customer_price'] != null
                ? (productResponse['customer_price'] is num
                    ? (productResponse['customer_price'] as num).toDouble()
                    : double.tryParse(productResponse['customer_price'].toString()) ?? 0.0)
                : 0.0;

            final transporterPrice = productResponse['transporter_price'] != null
                ? (productResponse['transporter_price'] is num
                    ? (productResponse['transporter_price'] as num).toDouble()
                    : double.tryParse(productResponse['transporter_price'].toString()) ?? 0.0)
                : 0.0;

            final saleDate = productResponse['sale_date'] != null
                ? DateFormat('dd/MM/yyyy HH:mm').format(DateTime.parse(productResponse['sale_date'] as String))
                : 'Không xác định';

            allItems.add({
              'imei': individualImei,
              'product_id': productId,
              'product_name': CacheUtil.getProductName(productId),
              'customer': item['customer'] as String? ?? 'Không xác định',
              'customer_price': customerPrice,
              'transporter_price': transporterPrice,
              'transporter': productResponse['transporter'] as String? ?? 'Không xác định',
              'sale_price': perItemPrice,
              'sale_currency': item['currency'] as String? ?? 'VND',
              'reimport_price': null,
              'isCod': item['account'] == 'Ship COD',
              'sale_date': saleDate,
            });
          } catch (e) {
            // Skip this IMEI if product data not found
            print('Skipping IMEI $individualImei: $e');
            continue;
          }
        }
        
        if (allItems.length >= qty) break;
      }

      if (allItems.length < qty) {
        final msg = selectedTarget == 'Khách Hàng'
            ? 'Khách hàng $cust mua chưa đủ số lượng. Chỉ có ${allItems.length} IMEI.'
            : 'Sản phẩm đang ship cod không đủ số lượng. Chỉ có ${allItems.length} IMEI.';
        if (mounted) {
          showDialog(
            context: context,
            builder: (ctx) => AlertDialog(
              title: const Text('Thông báo'),
              content: Text(msg),
              actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Đóng'))],
            ),
          );
        }
        setState(() {
          isLoading = false;
        });
        return;
      }

      setState(() {
        addedItems = allItems;
        isImeiManual = false;
        isLoading = false;
      });
    } catch (e) {
      if (mounted) {
        showDialog(
          context: context,
          builder: (ctx) => AlertDialog(
            title: const Text('Lỗi'),
            content: Text('$e'),
            actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Đóng'))],
          ),
        );
      }
      setState(() {
        isLoading = false;
      });
    }
  }

  Future<void> showConfirmDialog() async {
    if (productId == null || warehouseId == null) {
      if (mounted) {
        showDialog(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('Thông báo'),
            content: const Text('Vui lòng chọn sản phẩm và kho nhập lại!'),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('Đóng'),
              ),
            ],
          ),
        );
      }
      return;
    }

    if (selectedTarget == 'Khách Hàng' && (currency == null || account == null)) {
      if (mounted) {
        showDialog(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('Thông báo'),
            content: const Text('Vui lòng điền đầy đủ thông tin tài chính!'),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('Đóng'),
              ),
            ],
          ),
        );
      }
      return;
    }

    List<Map<String, dynamic>> itemsToProcess = [];

    try {
      if (addedItems.isEmpty) {
        throw Exception('Vui lòng nhập IMEI hoặc sử dụng Auto IMEI!');
      }
      if (selectedTarget == 'Khách Hàng') {
        for (var item in addedItems) {
          if (item['reimport_price'] != null && (item['reimport_price'] <= 0)) {
            throw Exception('Giá nhập lại cho IMEI ${item['imei']} phải lớn hơn 0!');
          }
        }
      }
      itemsToProcess = addedItems;

      if (itemsToProcess.length > maxImeiQuantity) {
        throw Exception(
            'Số lượng IMEI (${formatNumberLocal(itemsToProcess.length)}) vượt quá giới hạn ${formatNumberLocal(maxImeiQuantity)}. Vui lòng chia thành nhiều phiếu.');
      }

      if (mounted) {
        showDialog(
          context: context,
          builder: (dialogContext) => AlertDialog(
            title: const Text('Xác nhận phiếu nhập lại hàng'),
            content: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Đối tượng: $selectedTarget'),
                  if (selectedTarget == 'Khách Hàng')
                    ...itemsToProcess.map((item) => Text('Khách hàng: ${item['customer']} (Sản phẩm: ${item['product_name']})')),
                  Text('Sản phẩm: ${CacheUtil.getProductName(productId)}'),
                  Text('Danh sách IMEI:'),
                  ...itemsToProcess.map((item) => Text('- ${item['imei']}')),
                  Text('Số lượng: ${itemsToProcess.length}'),
                  Text('Kho nhập lại: ${CacheUtil.getWarehouseName(warehouseId)}'),
                  if (selectedTarget == 'Khách Hàng') ...[
                    ...itemsToProcess
                        .map((item) => Text('- IMEI ${item['imei']}: ${formatNumberLocal(item['reimport_price'] ?? item['sale_price'])} ${item['sale_currency']}')),
                    Text('Tài khoản: ${account ?? 'Không xác định'}'),
                  ],
                  Text('Ghi chú: ${note ?? 'Không có'}'),
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
                  await _processReimportOrder(itemsToProcess);
                },
                child: const Text('Tạo phiếu'),
              ),
            ],
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        showDialog(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('Thông báo'),
            content: Text(e.toString()),
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

  Future<void> _processReimportOrder(List<Map<String, dynamic>> items) async {
    if (items.isEmpty) {
      throw Exception('Danh sách IMEI trống, không thể tạo phiếu!');
    }

    if (mounted) {
      showDialog(
        context: context,
        barrierDismissible: false,
        builder: (context) => const AlertDialog(
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              CircularProgressIndicator(),
              SizedBox(height: 16),
              Text('Vui lòng chờ xử lý dữ liệu.'),
            ],
          ),
        ),
      );
    }

    Map<String, dynamic>? snapshotData;
    try {
      final supabase = widget.tenantClient;
      final ticketId = generateTicketId();
      final now = DateTime.now();

      print('Processing ${items.length} IMEIs for reimport order $ticketId');

      // Create snapshot before making any changes
      snapshotData = await retry(
        () => _createSnapshot(ticketId, items),
        operation: 'Create snapshot',
      );

      final customerGroups = <String, List<Map<String, dynamic>>>{};
      for (var item in items) {
        final customer = item['customer'] as String;
        customerGroups.putIfAbsent(customer, () => []).add(item);
      }

      try {
        for (var item in items) {
          final reimportPrice = item['reimport_price'] != null
              ? (item['reimport_price'] is num ? (item['reimport_price'] as num).toDouble() : 0.0)
              : (item['sale_price'] is num ? (item['sale_price'] as num).toDouble() : 0.0);

          print('Inserting reimport order for IMEI ${item['imei']}, price: $reimportPrice');

          await retry(
            () => supabase.from('reimport_orders').insert({
              'ticket_id': ticketId,
              'customer': item['customer'],
              'product_id': item['product_id'],
              'warehouse_id': warehouseId,
              'imei': item['imei'],
              'quantity': 1,
              'price': reimportPrice,
              'currency': item['sale_currency'],
              'account': account,
              'note': note,
              'created_at': now.toIso8601String(),
            }),
            operation: 'Insert reimport order for IMEI ${item['imei']}',
          );

          await retry(
            () => supabase.from('products').update({
              'status': 'Tồn kho',
              'warehouse_id': warehouseId,
              'sale_date': null,
              'profit': null,
              'customer_price': null,
              'transporter_price': null,
              'sale_price': null,
              ...selectedTarget == 'COD Hoàn' ? {} : {'cost_price': reimportPrice},
            }).eq('imei', item['imei']),
            operation: 'Update product ${item['imei']}',
          );
        }

        // Save snapshot
        await retry(
          () => supabase.from('snapshots').insert({
            'ticket_id': ticketId,
            'ticket_table': 'reimport_orders',
            'snapshot_data': snapshotData,
            'created_at': now.toIso8601String(),
          }),
          operation: 'Save snapshot',
        );

        // Process financial changes
        if (selectedTarget == 'Khách Hàng') {
          if (account == 'Công nợ') {
            for (var customer in customerGroups.keys) {
              final customerItems = customerGroups[customer]!;
              final currencyGroups = <String, List<Map<String, dynamic>>>{};
              for (var item in customerItems) {
                final saleCurrency = item['sale_currency'] as String;
                currencyGroups.putIfAbsent(saleCurrency, () => []).add(item);
              }

              for (var saleCurrency in currencyGroups.keys) {
                final itemsByCurrency = currencyGroups[saleCurrency]!;
                final customerAmount = itemsByCurrency.fold<double>(
                    0.0,
                    (sum, item) => sum +
                        (item['reimport_price'] != null
                            ? (item['reimport_price'] is num ? (item['reimport_price'] as num).toDouble() : 0.0)
                            : (item['sale_price'] is num ? (item['sale_price'] as num).toDouble() : 0.0)));

                print('Updating debt for customer $customer, currency $saleCurrency, amount: $customerAmount');

                String debtColumn;
                if (saleCurrency == 'VND') {
                  debtColumn = 'debt_vnd';
                } else if (saleCurrency == 'CNY') {
                  debtColumn = 'debt_cny';
                } else if (saleCurrency == 'USD') {
                  debtColumn = 'debt_usd';
                } else {
                  throw Exception('Loại tiền tệ không được hỗ trợ: $saleCurrency cho IMEI ${itemsByCurrency.first['imei']}');
                }

                final customerId = customerIdMap[customer];
                if (customerId == null) {
                  throw Exception('Không tìm thấy ID của khách hàng "$customer"!');
                }
                final currentCustomer = await retry(
                  () => supabase.from('customers').select('debt_vnd, debt_cny, debt_usd').eq('id', customerId).maybeSingle(),
                  operation: 'Fetch customer debt',
                );

                if (currentCustomer == null) {
                  throw Exception('Khách hàng "$customer" không tồn tại trong hệ thống!');
                }

                final currentDebt = (currentCustomer[debtColumn] as num?)?.toDouble() ?? 0.0;
                final updatedDebt = currentDebt - customerAmount;

                await retry(
                  () => supabase.from('customers').update({debtColumn: updatedDebt}).eq('id', customerId),
                  operation: 'Update customer debt for $debtColumn',
                );
              }
            }
          } else {
            final selectedAccount = accounts.firstWhere((acc) => acc['name'] == account);
            final currentBalance = selectedAccount['balance'] as double? ?? 0.0;
            final updatedBalance = currentBalance -
                items.fold<double>(
                    0.0,
                    (sum, item) => sum +
                        (item['reimport_price'] != null
                            ? (item['reimport_price'] is num ? (item['reimport_price'] as num).toDouble() : 0.0)
                            : (item['sale_price'] is num ? (item['sale_price'] as num).toDouble() : 0.0)));

            await retry(
              () => supabase.from('financial_accounts').update({'balance': updatedBalance}).eq('name', account!).eq('currency', currency!),
              operation: 'Update account balance',
            );
          }
        }

        if (selectedTarget == 'COD Hoàn') {
          // Map lưu tổng tiền cọc theo khách hàng
          final customerDeposits = <String, double>{};
          // Map lưu tổng tiền COD theo đơn vị vận chuyển
          final transporterCODs = <String, double>{};

          for (var customer in customerGroups.keys) {
            final customerItems = customerGroups[customer]!;
            if (customerItems.isEmpty) continue;

            // Tính tổng tiền cọc cho khách hàng này
            final customerDeposit = customerItems
                .map((item) => (item['customer_price'] as num?)?.toDouble() ?? 0.0)
                .fold<double>(0.0, (sum, price) => sum + price);

            print('Customer deposit for $customer: $customerDeposit');

            // Luôn cập nhật customerDeposits, kể cả khi deposit = 0
            customerDeposits[customer] = (customerDeposits[customer] ?? 0.0) + customerDeposit;

            // Tính tổng tiền COD theo từng đơn vị vận chuyển
            for (var item in customerItems) {
              final transporter = item['transporter'] as String? ?? 'Không xác định';
              if (transporter != 'Không xác định') {
                final codAmount = (item['transporter_price'] as num?)?.toDouble() ?? 0.0;
                print('COD amount for IMEI ${item['imei']}: $codAmount, transporter: $transporter');
                transporterCODs[transporter] = (transporterCODs[transporter] ?? 0.0) + codAmount;
              }
            }

            print('Current transporter CODs after processing customer $customer: $transporterCODs');
          }

          print('Final customer deposits: $customerDeposits');
          print('Final transporter CODs: $transporterCODs');

          // Cập nhật công nợ cho các khách hàng
          for (final entry in customerDeposits.entries) {
            final customer = entry.key;
            final depositAmount = entry.value;

            if (customer != 'Không xác định') {
              final customerId = customerIdMap[customer];
              if (customerId == null) {
                throw Exception('Không tìm thấy ID của khách hàng "$customer"!');
              }
              final currentCustomer = await retry(
                () => supabase.from('customers').select('debt_vnd').eq('id', customerId).maybeSingle(),
                operation: 'Fetch customer debt for COD',
              );
              if (currentCustomer == null) {
                throw Exception('Khách hàng "$customer" không tồn tại trong hệ thống!');
              }
              final currentCustomerDebt = (currentCustomer['debt_vnd'] as num?)?.toDouble() ?? 0.0;
              final updatedCustomerDebt = currentCustomerDebt - depositAmount;

              print('Updating customer $customer debt from $currentCustomerDebt to $updatedCustomerDebt (deposit: $depositAmount)');

              await retry(
                () => supabase.from('customers').update({'debt_vnd': updatedCustomerDebt}).eq('id', customerId),
                operation: 'Update customer debt for COD',
              );
            }
          }

          // Cập nhật công nợ cho các đơn vị vận chuyển
          for (final entry in transporterCODs.entries) {
            final transporter = entry.key;
            final codAmount = entry.value;

            final currentTransporter = await retry(
              () => supabase.from('transporters').select('debt').eq('name', transporter).maybeSingle(),
              operation: 'Fetch transporter debt',
            );
            if (currentTransporter == null) {
              throw Exception('Đơn vị vận chuyển "$transporter" không tồn tại trong hệ thống!');
            }
            final currentTransporterDebt = (currentTransporter['debt'] as num?)?.toDouble() ?? 0.0;
            final updatedTransporterDebt = currentTransporterDebt + codAmount;

            print('Updating transporter $transporter debt from $currentTransporterDebt to $updatedTransporterDebt (COD: $codAmount)');

            await retry(
              () => supabase.from('transporters').update({'debt': updatedTransporterDebt}).eq('name', transporter),
              operation: 'Update transporter debt',
            );
          }
        }

        // Calculate total amount by currency
        final amountsByCurrency = <String, double>{};
        for (var item in items) {
          final saleCurrency = item['sale_currency'] as String;
          final price = item['reimport_price'] != null
              ? (item['reimport_price'] is num ? (item['reimport_price'] as num).toDouble() : 0.0)
              : (item['sale_price'] is num ? (item['sale_price'] as num).toDouble() : 0.0);
          amountsByCurrency[saleCurrency] = (amountsByCurrency[saleCurrency] ?? 0.0) + price;
        }

        await NotificationService.showNotification(
          136,
          'Phiếu Nhập Lại Hàng Đã Tạo',
          'Đã tạo phiếu nhập lại hàng cho ${customerGroups.keys.join(', ')}',
          'reimport_created',
        );

        if (mounted) {
          Navigator.pop(context);
          await showDialog(
            context: context,
            builder: (context) => AlertDialog(
              title: const Text('Thông báo'),
              content: const Text('Đã tạo phiếu nhập lại hàng thành công'),
              actions: [
                TextButton(
                  onPressed: () {
                    Navigator.pop(context);
                    Navigator.pop(context);
                  },
                  child: const Text('Đóng'),
                ),
              ],
            ),
          );

          setState(() {
            selectedTarget = 'Khách Hàng';
            productId = null;
            productController.text = '';
            imei = null;
            imeiController.text = '';
            price = null;
            priceController.text = '';
            currency = currencies.contains('VND') ? 'VND' : currencies.isNotEmpty ? currencies.first : null;
            account = null;
            note = null;
            warehouseId = null;
            imeiError = null;
            addedItems = [];
            isImeiManual = true;
            _updateAccountNames(currency);
          });
          await _fetchInitialData();
        }
      } catch (e) {
        // Rollback if any error occurs
        if (snapshotData != null) {
          await _rollbackSnapshot(snapshotData);
        }
        throw e;
      }
    } catch (e) {
      if (mounted) {
        Navigator.pop(context);
        await showDialog(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('Thông báo'),
            content: Text(e.toString()),
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

  Future<Map<String, dynamic>> _createSnapshot(String ticketId, List<Map<String, dynamic>> items) async {
    final supabase = widget.tenantClient;
    final snapshotData = <String, dynamic>{};

    try {
      final customerNames = items.map((item) => item['customer'] as String).toSet();
      for (var customer in customerNames) {
        if (customer != 'Không xác định') {
          final customerId = customerIdMap[customer];
          if (customerId != null) {
            final customerData = await retry(
              () => supabase.from('customers').select().eq('id', customerId).maybeSingle(),
              operation: 'Fetch customer data',
            );
            if (customerData != null) {
              snapshotData['customers'] = snapshotData['customers'] ?? [];
              snapshotData['customers'].add(customerData);
            }
          }
        }
      }

      if (selectedTarget == 'COD Hoàn' && items.isNotEmpty) {
        final firstItem = items.first;
        final saleOrderData = await retry(
          () => supabase
              .from('sale_orders')
              .select('customer, transporter')
              .eq('product_id', firstItem['product_id'])
              .like('imei', '%${firstItem['imei']}%')
              .order('created_at', ascending: false)
              .limit(1)
              .maybeSingle(),
          operation: 'Fetch sale order for COD',
        );
        if (saleOrderData != null) {
          final codTransporter = saleOrderData['transporter'] as String?;
          if (codTransporter != null && codTransporter != 'Không xác định') {
            final transporterData = await retry(
              () => supabase.from('transporters').select().eq('name', codTransporter).maybeSingle(),
              operation: 'Fetch transporter data',
            );
            if (transporterData != null) {
              snapshotData['transporters'] = transporterData;
            }
          }
        }
      }

      if (account != null && account != 'Công nợ' && currency != null) {
        final accountData = await retry(
          () => supabase.from('financial_accounts').select().eq('name', account!).eq('currency', currency!).maybeSingle(),
          operation: 'Fetch account data',
        );
        if (accountData != null) {
          snapshotData['financial_accounts'] = accountData;
        }
      }

      if (items.isNotEmpty) {
        final imeis = items.map((item) => item['imei'] as String).toList();
        final productsData = await retry(
          () => supabase.from('products').select('imei, product_id, warehouse_id, status, cost_price').inFilter('imei', imeis),
          operation: 'Fetch products data',
        );
        snapshotData['products'] = productsData;
      }

      snapshotData['reimport_orders'] = items.map((item) {
        final reimportPrice = item['reimport_price'] != null
            ? (item['reimport_price'] is num ? (item['reimport_price'] as num).toDouble() : 0.0)
            : (item['sale_price'] is num ? (item['sale_price'] as num).toDouble() : 0.0);
        return {
          'ticket_id': ticketId,
          'customer': item['customer'],
          'product_id': item['product_id'],
          'product_name': item['product_name'],
          'warehouse_id': warehouseId,
          'warehouse_name': CacheUtil.getWarehouseName(warehouseId),
          'imei': item['imei'],
          'quantity': 1,
          'price': reimportPrice,
          'currency': item['sale_currency'],
          'account': account,
          'note': note,
        };
      }).toList();

      return snapshotData;
    } catch (e) {
      throw Exception('Failed to create snapshot: $e');
    }
  }

  String generateTicketId() {
    final now = DateTime.now();
    final dateFormat = DateFormat('yyyyMMdd-HHmmss');
    final randomNum = (100 + (now.millisecondsSinceEpoch % 900)).toString();
    return 'REIMPORT-${dateFormat.format(now)}-$randomNum';
  }

  Widget wrapField(Widget child, {bool isImeiField = false, bool isImeiList = false}) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      margin: const EdgeInsets.symmetric(vertical: 4),
      height: isImeiField ? 72 : isImeiList ? 240 : 48, // Tăng chiều cao IMEI field từ 48 lên 72 (50%)
      decoration: BoxDecoration(
        color: Colors.grey.shade200,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: imeiError != null && isImeiField ? Colors.red : Colors.grey.shade300),
      ),
      child: child,
    );
  }

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

    final selectedProductIds = addedItems.map((item) => item['product_id'] as String).toSet().toList();

    return Scaffold(
      appBar: AppBar(
        title: const Text('Phiếu nhập lại hàng', style: TextStyle(color: Colors.white)),
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
              Center(
                child: DropdownButtonFormField<String>(
                  value: selectedTarget,
                  items: ['Khách Hàng', 'COD Hoàn'].map((e) => DropdownMenuItem(value: e, child: Text(e))).toList(),
                  onChanged: (val) {
                    setState(() {
                      selectedTarget = val;
                      priceController.text = '';
                      currency = currencies.contains('VND') ? 'VND' : currencies.isNotEmpty ? currencies.first : null;
                      account = null;
                      _updateAccountNames(currency);
                    });
                  },
                  decoration: const InputDecoration(
                    border: InputBorder.none,
                    isDense: true,
                  ),
                  hint: const Text('Đối tượng', textAlign: TextAlign.center),
                ),
              ),
            ),
            Stack(
              children: [
                // Ô sản phẩm chiếm toàn bộ chiều ngang
                wrapField(
                  Autocomplete<Map<String, dynamic>>(
                    optionsBuilder: (TextEditingValue textEditingValue) {
                      final query = textEditingValue.text.toLowerCase();
                      if (query.isEmpty) return products.take(3).toList();
                      final filtered = products.where((option) => (option['name'] as String).toLowerCase().contains(query)).toList()
                        ..sort((a, b) {
                          final aName = (a['name'] as String).toLowerCase();
                          final bName = (b['name'] as String).toLowerCase();
                          final aIndex = aName.indexOf(query);
                          final bIndex = bName.indexOf(query);
                          if (aIndex != bIndex) {
                            return aIndex - bIndex;
                          }
                          return aName.compareTo(bName);
                        });
                      return filtered.isNotEmpty ? filtered : [{'id': '', 'name': 'Không tìm thấy sản phẩm'}];
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
                          addedItems = [];
                        });
                      }
                    },
                    fieldViewBuilder: (context, controller, focusNode, onFieldSubmitted) {
                      controller.text = productController.text;
                      return TextField(
                        controller: controller,
                        focusNode: focusNode,
                        onChanged: (value) {
                          setState(() {
                            productId = null;
                            productController.text = value;
                            imei = '';
                            imeiController.text = '';
                            imeiError = null;
                            addedItems = [];
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
            if (selectedProductIds.isNotEmpty) ...[
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                children: selectedProductIds
                    .map((productId) => Chip(
                          label: Text(CacheUtil.getProductName(productId)),
                          onDeleted: () {
                            setState(() {
                              addedItems.removeWhere((item) => item['product_id'] == productId);
                            });
                          },
                        ))
                    .toList(),
              ),
            ],
            wrapField(
              Autocomplete<Map<String, dynamic>>(
                optionsBuilder: (TextEditingValue textEditingValue) {
                  final query = textEditingValue.text.toLowerCase();
                  if (query.isEmpty) return warehouses.take(10).toList();
                  final filtered = warehouses.where((option) => (option['name'] as String).toLowerCase().contains(query)).toList()
                    ..sort((a, b) => (a['name'] as String).toLowerCase().compareTo((b['name'] as String).toLowerCase()));
                  return filtered.isNotEmpty ? filtered.take(10).toList() : [{'id': '', 'name': 'Không tìm thấy kho'}];
                },
                displayStringForOption: (option) => option['name'] as String,
                onSelected: (val) {
                  if (val['id'].isEmpty) return;
                  setState(() {
                    warehouseId = val['id'] as String;
                    if (!warehouses.any((w) => w['id'] == val['id'])) {
                      warehouses = [...warehouses, val];
                    }
                  });
                },
                fieldViewBuilder: (context, controller, focusNode, onFieldSubmitted) {
                  controller.text = warehouseId != null ? CacheUtil.getWarehouseName(warehouseId) : '';
                  return TextField(
                    controller: controller,
                    focusNode: focusNode,
                    onChanged: (value) {
                      if (_debounce?.isActive ?? false) _debounce?.cancel();
                      _debounce = Timer(const Duration(milliseconds: 300), () {
                        setState(() {
                          warehouseId = null;
                        });
                      });
                    },
                    decoration: const InputDecoration(
                      labelText: 'Kho nhập lại',
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
                        if (productId == null) return ['Vui lòng chọn sản phẩm trước'];
                        if (query.isEmpty) return imeiSuggestions.take(10).toList();
                        final filtered = imeiSuggestions.where((option) => option.toLowerCase().contains(query)).toList()
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
                        if (selection == 'Vui lòng chọn sản phẩm trước' || selection == 'Không tìm thấy IMEI') {
                          return;
                        }
                        final error = await _checkDuplicateImeis(selection);
                        if (error != null) {
                          setState(() {
                            imeiError = error;
                          });
                        } else {
                          await _addImeiToList(selection);
                          await _fetchAvailableImeis('');
                        }
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
                            if (_debounce?.isActive ?? false) _debounce!.cancel();
                            _debounce = Timer(const Duration(milliseconds: 300), () {
                              _fetchAvailableImeis(value);
                            });
                          },
                          onSubmitted: (value) async {
                            if (value.isEmpty) return;
                            final error = await _checkDuplicateImeis(value);
                            if (error != null) {
                              setState(() {
                                imeiError = error;
                              });
                              return;
                            }
                            await _addImeiToList(value);
                            await _fetchAvailableImeis('');
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
                height: 240,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Danh sách IMEI đã thêm (${addedItems.length})',
                      style: const TextStyle(fontSize: 14, color: Colors.black54),
                    ),
                    const SizedBox(height: 4),
                    Expanded(
                      child: addedItems.isEmpty
                          ? const Center(
                              child: Text(
                                'Chưa có IMEI nào',
                                style: TextStyle(fontSize: 14, color: Colors.grey),
                              ),
                            )
                          : ListView.builder(
                              itemCount: addedItems.length < displayImeiLimit ? addedItems.length : displayImeiLimit,
                              itemBuilder: (context, index) {
                                final item = addedItems[index];
                                return Card(
                                  margin: const EdgeInsets.symmetric(vertical: 2, horizontal: 4),
                                  child: Padding(
                                    padding: const EdgeInsets.all(8.0),
                                    child: Row(
                                      children: [
                                        Expanded(
                                          child: Column(
                                            crossAxisAlignment: CrossAxisAlignment.start,
                                            children: [
                                              Text('Sản phẩm: ${item['product_name']}', style: const TextStyle(fontSize: 12)),
                                              Text('IMEI: ${item['imei']}', style: const TextStyle(fontSize: 12)),
                                              Text(
                                                'Khách: ${item['customer']}',
                                                style: const TextStyle(fontSize: 12),
                                              ),
                                              if (selectedTarget == 'COD Hoàn' && item['isCod']) ...[
                                                Text(
                                                  'Cọc: ${formatNumberLocal(item['customer_price'])} VND',
                                                  style: const TextStyle(fontSize: 12),
                                                ),
                                                Text(
                                                  'COD: ${formatNumberLocal(item['transporter_price'])} VND',
                                                  style: const TextStyle(fontSize: 12),
                                                ),
                                              ],
                                              if (selectedTarget == 'Khách Hàng') ...[
                                                Text(
                                                  'Giá bán: ${formatNumberLocal(item['sale_price'])} ${item['sale_currency']}',
                                                  style: const TextStyle(fontSize: 12),
                                                ),
                                                Row(
                                                  children: [
                                                    Expanded(
                                                      child: TextFormField(
                                                        initialValue: item['reimport_price'] != null ? formatNumberLocal(item['reimport_price']) : '',
                                                        keyboardType: TextInputType.number,
                                                        inputFormatters: [ThousandsFormatterLocal()],
                                                        style: const TextStyle(fontSize: 12),
                                                        decoration: const InputDecoration(
                                                          labelText: 'Giá nhập lại',
                                                          isDense: true,
                                                          contentPadding: EdgeInsets.symmetric(vertical: 4),
                                                        ),
                                                        onChanged: (value) {
                                                          final cleanedValue = value.replaceAll('.', '');
                                                          if (cleanedValue.isNotEmpty) {
                                                            final parsedValue = double.tryParse(cleanedValue);
                                                            if (parsedValue != null) {
                                                              setState(() {
                                                                addedItems[index]['reimport_price'] = parsedValue;
                                                              });
                                                              print('reimport_price for IMEI ${item['imei']}: $parsedValue');
                                                            }
                                                          } else {
                                                            setState(() {
                                                              addedItems[index]['reimport_price'] = null;
                                                            });
                                                          }
                                                        },
                                                      ),
                                                    ),
                                                  ],
                                                ),
                                              ],
                                              Text('Ngày: ${item['sale_date']}', style: const TextStyle(fontSize: 12)),
                                            ],
                                          ),
                                        ),
                                        IconButton(
                                          icon: const Icon(Icons.delete, color: Colors.red, size: 20),
                                          onPressed: () {
                                            setState(() {
                                              addedItems.removeAt(index);
                                            });
                                          },
                                          padding: EdgeInsets.zero,
                                          constraints: const BoxConstraints(),
                                        ),
                                      ],
                                    ),
                                  ),
                                );
                              },
                            ),
                    ),
                    if (addedItems.length > displayImeiLimit)
                      Text(
                        '... và ${formatNumberLocal(addedItems.length - displayImeiLimit)} IMEI khác',
                        style: const TextStyle(fontSize: 14, color: Colors.grey),
                      ),
                  ],
                ),
              ),
              isImeiList: true,
            ),
            if (selectedTarget == 'Khách Hàng') ...[
              Row(
                children: [
                  Expanded(
                    child: wrapField(
                      DropdownButtonFormField<String>(
                        value: currency,
                        items: currencies.map((e) => DropdownMenuItem(value: e, child: Text(e))).toList(),
                        hint: const Text('Đơn vị tiền'),
                        onChanged: (val) {
                          setState(() {
                            currency = val;
                            _updateAccountNames(val);
                          });
                        },
                        decoration: const InputDecoration(border: InputBorder.none, isDense: true),
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: wrapField(
                      DropdownButtonFormField<String>(
                        value: account,
                        items: accountNames.map((e) => DropdownMenuItem(value: e, child: Text(e))).toList(),
                        hint: const Text('Tài khoản'),
                        onChanged: (val) {
                          setState(() {
                            account = val;
                          });
                        },
                        decoration: const InputDecoration(border: InputBorder.none, isDense: true),
                      ),
                    ),
                  ),
                ],
              ),
            ],
            wrapField(
              TextFormField(
                onChanged: (val) {
                  setState(() {
                    note = val;
                  });
                },
                decoration: const InputDecoration(
                  labelText: 'Ghi chú',
                  border: InputBorder.none,
                  isDense: true,
                ),
              ),
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

  Future<void> _rollbackSnapshot(Map<String, dynamic> snapshotData) async {
    final supabase = widget.tenantClient;

    try {
      if (snapshotData['customers'] != null) {
        for (var customer in snapshotData['customers']) {
          await retry(
            () => supabase.from('customers').update({
              'debt_vnd': customer['debt_vnd'],
              'debt_cny': customer['debt_cny'],
              'debt_usd': customer['debt_usd'],
            }).eq('name', customer['name']),
            operation: 'Rollback customer ${customer['name']}',
          );
        }
      }

      if (snapshotData['transporters'] != null) {
        await retry(
          () => supabase.from('transporters').update({
            'debt': snapshotData['transporters']['debt'],
          }).eq('name', snapshotData['transporters']['name']),
          operation: 'Rollback transporter ${snapshotData['transporters']['name']}',
        );
      }

      if (snapshotData['financial_accounts'] != null) {
        await retry(
          () => supabase.from('financial_accounts').update({
            'balance': snapshotData['financial_accounts']['balance'],
          }).eq('name', snapshotData['financial_accounts']['name']).eq('currency', snapshotData['financial_accounts']['currency']),
          operation: 'Rollback financial account ${snapshotData['financial_accounts']['name']}',
        );
      }

      if (snapshotData['products'] != null) {
        for (var product in snapshotData['products']) {
          await retry(
            () => supabase.from('products').update({
              'status': product['status'],
              'warehouse_id': product['warehouse_id'],
              'cost_price': product['cost_price'],
            }).eq('imei', product['imei']),
            operation: 'Rollback product ${product['imei']}',
          );
        }
      }
    } catch (e) {
      print('Error during rollback: $e');
      throw Exception('Lỗi khi rollback dữ liệu: $e');
    }
  }
}

class QRCodeScannerScreen extends StatefulWidget {
  const QRCodeScannerScreen({super.key});

  @override
  QRCodeScannerScreenState createState() => QRCodeScannerScreenState();
}

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