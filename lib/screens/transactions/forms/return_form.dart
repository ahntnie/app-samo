import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'dart:async';
import 'dart:math' as math;
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'return_summary.dart';
import '../../text_scanner_screen.dart';

// Constants for IMEI handling
const int maxImeiQuantity = 100000;
const int warnImeiQuantity = 10000;
const int batchSize = 1000;
const int displayImeiLimit = 100;

class ThousandsFormatterLocal extends TextInputFormatter {
  @override
  TextEditingValue formatEditUpdate(TextEditingValue oldValue, TextEditingValue newValue) {
    String newText = newValue.text.replaceAll('.', '').replaceAll(',', '');
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

class CacheUtil {
  static final Map<String, String> productNameCache = {};

  static void cacheProductName(String id, String name) => productNameCache[id] = name;
  static String getProductName(String? id) => id != null ? productNameCache[id] ?? 'Không xác định' : 'Không xác định';
}

class Debouncer {
  final Duration delay;
  Timer? _timer;

  Debouncer({required this.delay});

  void run(VoidCallback action) {
    _timer?.cancel();
    _timer = Timer(delay, action);
  }

  void dispose() {
    _timer?.cancel();
  }
}

class ReturnForm extends StatefulWidget {
  final SupabaseClient tenantClient;
  final String? initialSupplier;
  final String? initialProductId;
  final String? initialProductName;
  final String? initialPrice;
  final String? initialImei;
  final String? initialNote;
  final String? initialCurrency;
  final List<Map<String, dynamic>> ticketItems;
  final int? editIndex;

  const ReturnForm({
    super.key,
    required this.tenantClient,
    this.initialSupplier,
    this.initialProductId,
    this.initialProductName,
    this.initialPrice,
    this.initialImei,
    this.initialNote,
    this.initialCurrency,
    this.ticketItems = const [],
    this.editIndex,
  });

  @override
  State<ReturnForm> createState() => _ReturnFormState();
}

class _ReturnFormState extends State<ReturnForm> {
  String? supplier;
  String? productId;
  String? imei = '';
  List<String> imeiList = [];
  Map<String, Map<String, dynamic>> imeiData = {};
  int quantity = 0;
  String? price;
  String? currency;
  String? note;
  bool isAccessory = false;
  String? imeiPrefix;
  List<Map<String, dynamic>> ticketItems = [];
  bool isManualEntry = false; // Biến để theo dõi xem đã nhập IMEI thủ công hay chưa

  List<String> suppliers = [];
  List<String> currencies = [];
  List<String> imeiSuggestions = [];
  Map<String, String> productMap = {};
  bool isLoading = true;
  String? errorMessage;
  String? imeiError;

  final TextEditingController imeiController = TextEditingController();
  final TextEditingController supplierController = TextEditingController();
  final TextEditingController productController = TextEditingController();
  final TextEditingController priceController = TextEditingController();
  final TextEditingController quantityController = TextEditingController();
  late final Debouncer _debouncer;

  final NumberFormat numberFormat = NumberFormat.decimalPattern('vi_VN');

  @override
  void initState() {
    super.initState();
    _debouncer = Debouncer(delay: const Duration(milliseconds: 300));
    supplier = widget.initialSupplier;
    productId = widget.initialProductId;
    price = widget.initialPrice;
    imei = widget.initialImei ?? '';
    note = widget.initialNote;
    currency = widget.initialCurrency;
    ticketItems = List.from(widget.ticketItems);

    supplierController.text = supplier ?? '';
    productController.text = widget.initialProductName ?? '';
    priceController.text = price != null ? formatNumberLocal(double.parse(price!)) : '';
    imeiController.text = imei ?? '';
    quantityController.text = quantity.toString();

    if (widget.initialImei != null && widget.initialImei!.isNotEmpty) {
      imeiList = widget.initialImei!.split(',').where((e) => e.trim().isNotEmpty).toList();
      isManualEntry = true; // Đánh dấu là nhập thủ công nếu có IMEI ban đầu
    }

    _fetchInitialData();
  }

  @override
  void dispose() {
    _debouncer.dispose();
    imeiController.dispose();
    supplierController.dispose();
    productController.dispose();
    priceController.dispose();
    quantityController.dispose();
    super.dispose();
  }

  Future<void> _fetchInitialData() async {
    setState(() {
      isLoading = true;
      errorMessage = null;
    });

    try {
      final supabase = widget.tenantClient;

      final supplierResponse = await supabase.from('suppliers').select('name');
      final supplierList = supplierResponse
          .map((e) => e['name'] as String?)
          .whereType<String>()
          .toList()
        ..sort();

      final productResponse = await supabase.from('products_name').select('id, products');
      final productList = productResponse
          .map((e) => {'id': e['id'].toString(), 'name': e['products'] as String})
          .toList()
        ..sort((a, b) => (a['name'] as String).toLowerCase().compareTo((b['name'] as String).toLowerCase()));

      final currencyResponse = await supabase
          .from('financial_accounts')
          .select('currency')
          .neq('currency', '');
      final uniqueCurrencies = currencyResponse
          .map((e) => e['currency'] as String?)
          .whereType<String>()
          .toSet()
          .toList();

      if (mounted) {
        setState(() {
          suppliers = supplierList;
          currencies = uniqueCurrencies;
          supplier = widget.initialSupplier != null && supplierList.contains(widget.initialSupplier) ? widget.initialSupplier : null;
          supplierController.text = supplier ?? '';
          isLoading = false;

          productMap = {
            for (var product in productList) product['id'] as String: product['name'] as String
          };

          for (var product in productList) {
            CacheUtil.cacheProductName(product['id'] as String, product['name'] as String);
          }
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          errorMessage = 'Không thể tải dữ liệu: $e';
          isLoading = false;
        });
      }
    }
  }

  Future<void> _fetchAvailableImeis(String query) async {
    if (productId == null || query.isEmpty || supplier == null || supplier!.isEmpty) {
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
          .eq('status', 'Tồn kho')
          .eq('supplier', supplier!)
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
      debugPrint('Lỗi khi tải gợi ý IMEI: $e');
      if (mounted) {
        setState(() {
          imeiSuggestions = [];
        });
      }
    }
  }

  Future<Map<String, dynamic>?> _fetchImeiData(String input) async {
    if (input.trim().isEmpty || productId == null) {
      return null;
    }

    try {
      final supabase = widget.tenantClient;
      var queryBuilder = supabase
          .from('products')
          .select('imei, import_price, import_currency, status, product_id')
          .eq('imei', input)
          .eq('product_id', productId!);

      if (supplier != null && supplier!.isNotEmpty) {
        queryBuilder = queryBuilder.eq('supplier', supplier!);
      }

      final response = await queryBuilder.maybeSingle();

      if (response == null || response['status'] == null) {
        return null;
      }

      final status = response['status'] as String;
      if (status != 'Tồn kho') {
        return null;
      }

      return {
        'imei': response['imei'] as String,
        'price': response['import_price'] as num?,
        'currency': response['import_currency'] as String?,
      };
    } catch (e) {
      debugPrint('Lỗi khi kiểm tra IMEI "$input": $e');
      return null;
    }
  }

  Future<List<String>> _fetchImeisForQuantity(int quantity) async {
    if (productId == null || quantity <= 0 || supplier == null || supplier!.isEmpty) {
      return [];
    }

    try {
      final supabase = widget.tenantClient;
      final response = await supabase
          .from('products')
          .select('imei, import_price, import_currency')
          .eq('product_id', productId!)
          .eq('status', 'Tồn kho')
          .eq('supplier', supplier!)
          .limit(quantity);

      final imeiListFromDb = response
          .map((e) => {
                'imei': e['imei'] as String?,
                'price': e['import_price'] as num?,
                'currency': e['import_currency'] as String?,
              })
          .where((e) => e['imei'] != null)
          .toList();

      if (imeiListFromDb.length < quantity) {
        if (mounted) {
          await showDialog(
            context: context,
            builder: (context) => AlertDialog(
              title: const Text('Thông báo'),
              content: Text('Số lượng sản phẩm tồn kho không đủ! Chỉ có ${imeiListFromDb.length} sản phẩm "${CacheUtil.getProductName(productId)}" của nhà cung cấp "$supplier" trong kho.'),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: const Text('Đóng'),
                ),
              ],
            ),
          );
        }
        return [];
      }

      final filteredImeis = <String>[];
      for (var item in imeiListFromDb) {
        final imei = item['imei'] as String;
        if (!imeiList.contains(imei)) {
          filteredImeis.add(imei);
          imeiData[imei] = {
            'price': item['price'] ?? 0,
            'currency': item['currency'] ?? 'VND',
          };
        }
      }
      filteredImeis.sort();

      // Cập nhật currency và priceController dựa trên imeiData
      if (filteredImeis.isNotEmpty) {
        final firstImei = filteredImeis.first;
        final firstData = imeiData[firstImei]!;
        currency = firstData['currency'] as String;
        price = firstData['price'].toString();
        priceController.text = formatNumberLocal(firstData['price'] as num);
      }

      debugPrint('Fetched ${filteredImeis.length} IMEIs for quantity: $quantity');
      return filteredImeis;
    } catch (e) {
      debugPrint('Error fetching IMEIs for quantity: $e');
      return [];
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
          debugPrint('Scanned QR code: $scannedData');
          isManualEntry = true; // Đánh dấu là nhập thủ công
        });

        final data = await _fetchImeiData(scannedData);
        setState(() {
          imeiError = data == null ? 'IMEI "$scannedData" không hợp lệ hoặc không tồn kho!' : null;
        });

        if (data != null) {
          if (imeiList.contains(scannedData)) {
            setState(() {
              imeiError = 'IMEI "$scannedData" đã có trong danh sách!';
              imei = '';
              imeiController.text = '';
            });
            debugPrint('Duplicate IMEI: $scannedData');
          } else {
            setState(() {
              imeiList.insert(0, scannedData);
              imeiData[scannedData] = {
                'price': data['price'] ?? 0,
                'currency': data['currency'] ?? 'VND',
              };
              currency = data['currency'] ?? 'VND';
              price = data['price'].toString();
              priceController.text = formatNumberLocal(data['price'] as num);
              imei = '';
              imeiController.text = '';
              imeiError = null;
              // Không cập nhật quantity ở đây để tránh vô hiệu hóa ô nhập IMEI
            });
            debugPrint('Added IMEI: $scannedData');
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
        debugPrint('Error scanning QR code: $e');
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
          debugPrint('Scanned text: $scannedData');
          isManualEntry = true; // Đánh dấu là nhập thủ công
        });

        final data = await _fetchImeiData(scannedData);
        setState(() {
          imeiError = data == null ? 'IMEI "$scannedData" không hợp lệ hoặc không tồn kho!' : null;
        });

        if (data != null) {
          if (imeiList.contains(scannedData)) {
            setState(() {
              imeiError = 'IMEI "$scannedData" đã có trong danh sách!';
              imei = '';
              imeiController.text = '';
            });
            debugPrint('Duplicate IMEI: $scannedData');
          } else {
            setState(() {
              imeiList.insert(0, scannedData);
              imeiData[scannedData] = {
                'price': data['price'] ?? 0,
                'currency': data['currency'] ?? 'VND',
              };
              currency = data['currency'] ?? 'VND';
              price = data['price'].toString();
              priceController.text = formatNumberLocal(data['price'] as num);
              imei = '';
              imeiController.text = '';
              imeiError = null;
              // Không cập nhật quantity ở đây để tránh vô hiệu hóa ô nhập IMEI
            });
            debugPrint('Added IMEI: $scannedData');
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
        debugPrint('Error scanning text: $e');
      }
    }
  }

  void addToTicket(BuildContext scaffoldContext) async {
    if (supplier == null || productId == null || currency == null || (imeiList.isEmpty && quantity == 0 && !isAccessory)) {
      if (mounted) {
        await showDialog(
          context: scaffoldContext,
          builder: (context) => AlertDialog(
            title: const Text('Thông báo'),
            content: const Text('Vui lòng điền đầy đủ thông tin, bao gồm nhà cung cấp, sản phẩm, đơn vị tiền và IMEI/số lượng!'),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('Đóng'),
              ),
            ],
          ),
        );
        debugPrint('Invalid input: supplier=$supplier, productId=$productId, currency=$currency, imeiList=$imeiList, quantity=$quantity');
      }
      return;
    }

    if (!isAccessory && imeiList.isEmpty && quantity == 0) {
      if (mounted) {
        await showDialog(
          context: scaffoldContext,
          builder: (context) => AlertDialog(
            title: const Text('Thông báo'),
            content: const Text('Vui lòng nhập ít nhất một IMEI hoặc chọn số lượng lớn hơn 0!'),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('Đóng'),
              ),
            ],
          ),
        );
        debugPrint('No IMEI or quantity for non-accessory');
      }
      return;
    }

    List<String> finalImeiList = [];
    if (isAccessory) {
      final prefix = imeiPrefix?.isNotEmpty == true ? imeiPrefix! : 'PK';
      for (int i = 0; i < quantity; i++) {
        final randomNumbers = math.Random().nextInt(10000000).toString().padLeft(7, '0');
        final generatedImei = '$prefix$randomNumbers';
        if (imeiList.contains(generatedImei)) {
          if (mounted) {
            await showDialog(
              context: scaffoldContext,
              builder: (context) => AlertDialog(
                title: const Text('Thông báo'),
                content: Text('Mã "$generatedImei" đã có trong danh sách!'),
                actions: [
                  TextButton(
                    onPressed: () => Navigator.pop(context),
                    child: const Text('Đóng'),
                  ),
                ],
              ),
            );
            debugPrint('Duplicate generated Imei: $generatedImei');
          }
          return;
        }
        finalImeiList.add(generatedImei);
      }
    } else {
      finalImeiList = imeiList;
    }

    if (mounted) {
      setState(() {
        if (isAccessory) {
          final amount = double.tryParse(price?.replaceAll('.', '') ?? '0') ?? 0;
          final item = {
            'product_id': productId!,
            'product_name': CacheUtil.getProductName(productId),
            'imei': finalImeiList.join(','),
            'price': amount,
            'currency': currency!,
            'note': note,
            'is_accessory': isAccessory,
            'imei_prefix': imeiPrefix,
          };
          if (widget.editIndex != null) {
            ticketItems[widget.editIndex!] = item;
          } else {
            ticketItems.add(item);
          }
        } else {
          // Nhóm theo import_price và import_currency
          final Map<String, List<String>> groupedImeis = {};
          for (var imei in finalImeiList) {
            final data = imeiData[imei] ?? {'price': 0, 'currency': currency ?? 'VND'};
            final key = '${data['price']}_${data['currency']}';
            groupedImeis[key] = groupedImeis[key] ?? [];
            groupedImeis[key]!.add(imei);
          }

          for (var entry in groupedImeis.entries) {
            final keyParts = entry.key.split('_');
            final amount = double.tryParse(keyParts[0]) ?? 0;
            final itemCurrency = keyParts[1];
            final item = {
              'product_id': productId!,
              'product_name': CacheUtil.getProductName(productId),
              'imei': entry.value.join(','),
              'price': amount,
              'currency': itemCurrency,
              'note': note,
              'is_accessory': isAccessory,
              'imei_prefix': null,
            };
            if (widget.editIndex != null) {
              ticketItems[widget.editIndex!] = item;
            } else {
              ticketItems.add(item);
            }
          }
        }
        debugPrint('Added/Updated ticket items: $ticketItems');
      });

      Navigator.pushReplacement(
        context,
        MaterialPageRoute(
          builder: (context) => ReturnSummary(
            tenantClient: widget.tenantClient,
            supplier: supplier ?? '',
            ticketItems: ticketItems,
            currency: currency ?? 'VND',
          ),
        ),
      );
    }
  }

  Widget wrapField(Widget child, {bool isImeiField = false, bool isSupplierField = false, bool isImeiList = false}) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      margin: const EdgeInsets.symmetric(vertical: 4),
      height: isImeiField ? 72 : isImeiList ? 120 : isSupplierField ? 56 : 48, // Tăng chiều cao IMEI field từ 48 lên 72 (50%)
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: imeiError != null && isImeiField ? Colors.red : Colors.grey.shade300),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.1),
            blurRadius: 4,
            offset: const Offset(0, 2),
          ),
        ],
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

    final amount = double.tryParse(price?.replaceAll('.', '') ?? '0') ?? 0;
    final totalAmount = amount * imeiList.length;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Phiếu trả hàng', style: TextStyle(color: Colors.white)),
        backgroundColor: Colors.black,
        iconTheme: const IconThemeData(color: Colors.white),
        leading: IconButton(
          icon: Transform.rotate(
            angle: math.pi,
            child: const Icon(Icons.arrow_forward_ios, color: Colors.white),
          ),
          onPressed: () => Navigator.pop(context),
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.arrow_forward_ios, color: Colors.white),
            onPressed: () {
              Navigator.pushReplacement(
                context,
                MaterialPageRoute(
                  builder: (context) => ReturnSummary(
                    tenantClient: widget.tenantClient,
                    supplier: supplier ?? '',
                    ticketItems: ticketItems,
                    currency: currency ?? 'VND',
                  ),
                ),
              );
            },
          ),
        ],
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            wrapField(
              Autocomplete<String>(
                optionsBuilder: (TextEditingValue textEditingValue) {
                  final query = textEditingValue.text.toLowerCase();
                  final filtered = suppliers
                      .where((option) => option.toLowerCase().contains(query))
                      .toList()
                    ..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
                  return filtered.isNotEmpty ? filtered.take(10).toList() : ['Không tìm thấy nhà cung cấp'];
                },
                onSelected: (String selection) {
                  if (selection != 'Không tìm thấy nhà cung cấp') {
                    setState(() {
                      supplier = selection;
                      supplierController.text = selection;
                    });
                  }
                },
                fieldViewBuilder: (
                  context,
                  controller,
                  focusNode,
                  onFieldSubmitted,
                ) {
                  controller.text = supplierController.text;
                  return TextField(
                    controller: supplierController,
                    focusNode: focusNode,
                    onChanged: (value) {
                      setState(() {
                        supplier = value.isNotEmpty ? value : null;
                      });
                    },
                    onEditingComplete: onFieldSubmitted,
                    decoration: const InputDecoration(
                      labelText: 'Nhà cung cấp',
                      border: InputBorder.none,
                      isDense: true,
                    ),
                  );
                },
              ),
              isSupplierField: true,
            ),
            Row(
              children: [
                Expanded(
                  child: wrapField(
                    _buildProductField(),
                  ),
                ),
              ],
            ),
            if (!isAccessory) ...[
              wrapField(
                _buildImeiField(),
                isImeiField: true,
              ),
              wrapField(
                SizedBox(
                  height: 120,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Danh sách IMEI. Đã nhập ${imeiList.length} chiếc.',
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
                                itemBuilder: (context, index) {
                                  return Card(
                                    margin: const EdgeInsets.symmetric(vertical: 2, horizontal: 4),
                                    elevation: 0,
                                    color: Colors.grey.shade300,
                                    shape: RoundedRectangleBorder(
                                      borderRadius: BorderRadius.circular(4),
                                    ),
                                    child: Container(
                                      height: 36,
                                      padding: const EdgeInsets.symmetric(vertical: 1, horizontal: 8),
                                      child: Row(
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
                                                imeiData.remove(imeiList[index]);
                                                if (imeiList.isEmpty) {
                                                  isManualEntry = false; // Reset trạng thái nhập thủ công
                                                  currency = null;
                                                  price = null;
                                                  priceController.text = '';
                                                } else {
                                                  final firstImei = imeiList.first;
                                                  final firstData = imeiData[firstImei];
                                                  currency = firstData?['currency'] as String? ?? 'VND';
                                                  price = firstData?['price'].toString();
                                                  priceController.text = formatNumberLocal(firstData?['price'] as num? ?? 0);
                                                }
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
                    ],
                  ),
                ),
                isImeiList: true,
              ),
            ],
            if (isAccessory)
              wrapField(
                TextFormField(
                  onChanged: (val) => setState(() {
                    imeiPrefix = val.isNotEmpty ? val : null;
                  }),
                  decoration: const InputDecoration(
                    labelText: 'Đầu mã IMEI',
                    border: InputBorder.none,
                    isDense: true,
                  ),
                ),
              ),
            wrapField(
              TextFormField(
                controller: quantityController,
                keyboardType: TextInputType.number,
                enabled: !isManualEntry, // Vô hiệu hóa nếu đã nhập IMEI thủ công
                onChanged: (val) async {
                  final newQuantity = int.tryParse(val) ?? 0;
                  setState(() {
                    quantity = newQuantity;
                  });
                  if (!isAccessory && newQuantity > 0 && !isManualEntry) {
                    final fetchedImeis = await _fetchImeisForQuantity(newQuantity);
                    setState(() {
                      if (fetchedImeis.isNotEmpty) {
                        imeiList = fetchedImeis;
                        quantity = imeiList.length;
                        quantityController.text = quantity.toString();
                      } else {
                        imeiList = [];
                        imeiData.clear();
                        quantity = 0;
                        quantityController.text = '0';
                        currency = null;
                        price = null;
                        priceController.text = '';
                      }
                    });
                  } else if (!isAccessory) {
                    setState(() {
                      imeiList = [];
                      imeiData.clear();
                      quantity = 0;
                      quantityController.text = '0';
                      currency = null;
                      price = null;
                      priceController.text = '';
                    });
                  }
                },
                decoration: InputDecoration(
                  labelText: 'Số lượng (tự động lấy IMEI nếu có)',
                  border: InputBorder.none,
                  isDense: true,
                  hintText: isManualEntry ? 'Vô hiệu hóa khi nhập IMEI thủ công' : null,
                ),
              ),
            ),
            wrapField(
              TextFormField(
                controller: priceController,
                keyboardType: TextInputType.number,
                inputFormatters: [ThousandsFormatterLocal()],
                enabled: !isManualEntry,
                onChanged: (val) {
                  final cleanedValue = val.replaceAll(RegExp(r'[^0-9]'), '');
                  if (cleanedValue.isNotEmpty) {
                    final parsedValue = double.tryParse(cleanedValue);
                    if (parsedValue != null) {
                      final formattedValue = formatNumberLocal(parsedValue);
                      priceController.value = TextEditingValue(
                        text: formattedValue,
                        selection: TextSelection.collapsed(offset: formattedValue.length),
                      );
                      setState(() {
                        price = cleanedValue;
                      });
                    }
                  } else {
                    setState(() {
                      price = null;
                    });
                  }
                },
                decoration: InputDecoration(
                  labelText: 'Số tiền',
                  border: InputBorder.none,
                  isDense: true,
                  hintText: isManualEntry ? 'Tự động lấy từ giá nhập' : null,
                ),
              ),
            ),
            wrapField(
              DropdownButtonFormField<String>(
                value: currency,
                items: currencies.map((e) => DropdownMenuItem(value: e, child: Text(e))).toList(),
                hint: const Text('Đơn vị tiền'),
                onChanged: !isManualEntry ? (val) => setState(() {
                  currency = val;
                }) : null,
                decoration: InputDecoration(
                  border: InputBorder.none,
                  isDense: true,
                  hintText: isManualEntry ? 'Tự động lấy từ đơn vị nhập' : null,
                ),
              ),
            ),
            wrapField(
              TextFormField(
                onChanged: (val) => setState(() => note = val),
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
              onPressed: () => addToTicket(context),
              child: Text(widget.editIndex != null ? 'Cập Nhật Sản Phẩm' : 'Thêm Vào Phiếu'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildProductField() {
    return Autocomplete<String>(
      optionsBuilder: (TextEditingValue textEditingValue) {
        final query = textEditingValue.text.toLowerCase();
        if (query.isEmpty) {
          return productMap.values.take(10).toList();
        }
        final filtered = productMap.entries
            .where((entry) => entry.value.toLowerCase().contains(query))
            .map((entry) => entry.value)
            .toList()
          ..sort((a, b) {
            final aLower = a.toLowerCase();
            final bLower = b.toLowerCase();
            final aStartsWith = aLower.startsWith(query);
            final bStartsWith = bLower.startsWith(query);
            if (aStartsWith != bStartsWith) {
              return aStartsWith ? -1 : 1;
            }
            final aIndex = aLower.indexOf(query);
            final bIndex = bLower.indexOf(query);
            if (aIndex != bIndex) {
              return aIndex - bIndex;
            }
            return aLower.compareTo(bLower);
          });
        return filtered.isNotEmpty ? filtered.take(10).toList() : ['Không tìm thấy sản phẩm'];
      },
      onSelected: (String selection) {
        if (selection == 'Không tìm thấy sản phẩm') return;

        final selectedEntry = productMap.entries.firstWhere(
          (entry) => entry.value == selection,
          orElse: () => MapEntry('', ''),
        );

        if (selectedEntry.key.isNotEmpty) {
          setState(() {
            productId = selectedEntry.key;
            productController.text = selection;
            isAccessory = ['Ốp lưng', 'Tai nghe'].contains(selection);
            imei = '';
            imeiController.text = '';
            imeiError = null;
            imeiList = [];
            imeiData.clear();
            quantity = 0;
            quantityController.text = '0';
            currency = null;
            price = null;
            priceController.text = '';
            isManualEntry = false; // Reset trạng thái nhập thủ công khi chọn sản phẩm mới
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
                isAccessory = false;
                imei = '';
                imeiController.text = '';
                imeiError = null;
                imeiList = [];
                imeiData.clear();
                quantity = 0;
                quantityController.text = '0';
                currency = null;
                price = null;
                priceController.text = '';
                isManualEntry = false; // Reset trạng thái nhập thủ công
              }
            });
          },
          decoration: const InputDecoration(
            labelText: 'Sản phẩm',
            border: InputBorder.none,
            isDense: true,
            contentPadding: EdgeInsets.symmetric(vertical: 8, horizontal: 0),
            floatingLabelBehavior: FloatingLabelBehavior.auto,
            labelStyle: TextStyle(fontSize: 14),
          ),
        );
      },
    );
  }

  Widget _buildImeiField() {
    return Column(
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
              if (selection == 'Vui lòng chọn sản phẩm' || selection == 'Không tìm thấy IMEI') {
                return;
              }

              if (imeiList.contains(selection)) {
                setState(() {
                  imeiError = 'IMEI "$selection" đã được nhập!';
                });
                return;
              }

              final data = await _fetchImeiData(selection);
              setState(() {
                imeiError = data == null ? 'IMEI "$selection" không hợp lệ hoặc không tồn kho!' : null;
              });

              if (data != null) {
                setState(() {
                  imeiList.add(selection);
                  imeiData[selection] = {
                    'price': data['price'] ?? 0,
                    'currency': data['currency'] ?? 'VND',
                  };
                  currency = data['currency'] ?? 'VND';
                  price = data['price'].toString();
                  priceController.text = formatNumberLocal(data['price'] as num);
                  imei = '';
                  imeiController.text = '';
                  imeiError = null;
                  isManualEntry = true; // Đánh dấu là nhập thủ công
                });
                _fetchAvailableImeis('');
              }
            },
            fieldViewBuilder: (context, controller, focusNode, onFieldSubmitted) {
              controller.text = imeiController.text;
              return TextField(
                controller: controller,
                focusNode: focusNode,
                enabled: productId != null && !isAccessory, // Bật nếu đã chọn sản phẩm và không phải phụ kiện
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

                  if (imeiList.contains(value)) {
                    setState(() {
                      imeiError = 'IMEI "$value" đã được nhập!';
                    });
                    return;
                  }

                  final data = await _fetchImeiData(value);
                  setState(() {
                    imeiError = data == null ? 'IMEI "$value" không hợp lệ hoặc không tồn kho!' : null;
                  });

                  if (data != null) {
                    setState(() {
                      imeiList.add(value);
                      imeiData[value] = {
                        'price': data['price'] ?? 0,
                        'currency': data['currency'] ?? 'VND',
                      };
                      currency = data['currency'] ?? 'VND';
                      price = data['price'].toString();
                      priceController.text = formatNumberLocal(data['price'] as num);
                      imei = '';
                      imeiController.text = '';
                      imeiError = null;
                      isManualEntry = true; // Đánh dấu là nhập thủ công
                    });
                    _fetchAvailableImeis('');
                  }
                },
                decoration: InputDecoration(
                  labelText: 'IMEI',
                  border: InputBorder.none,
                  isDense: true,
                  contentPadding: const EdgeInsets.symmetric(vertical: 8, horizontal: 0),
                  floatingLabelBehavior: FloatingLabelBehavior.auto,
                  labelStyle: const TextStyle(fontSize: 14),
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
    );
  }
}

class QRCodeScannerScreen extends StatefulWidget {
  const QRCodeScannerScreen({super.key});

  @override
  State<QRCodeScannerScreen> createState() => _QRCodeScannerScreenState();
}

class _QRCodeScannerScreenState extends State<QRCodeScannerScreen> {
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