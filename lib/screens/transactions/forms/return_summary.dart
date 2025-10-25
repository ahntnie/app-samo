import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:intl/intl.dart';
import '../../notification_service.dart';
import 'return_form.dart';
import 'dart:math' as math;
import '../../../../helpers/error_handler.dart';

class ReturnSummary extends StatefulWidget {
  final SupabaseClient tenantClient;
  final String supplier;
  final List<Map<String, dynamic>> ticketItems;
  final String currency;

  const ReturnSummary({
    super.key,
    required this.tenantClient,
    required this.supplier,
    required this.ticketItems,
    required this.currency,
  });

  @override
  State<ReturnSummary> createState() => _ReturnSummaryState();
}

class _ReturnSummaryState extends State<ReturnSummary> {
  List<Map<String, Object?>> accounts = [];
  List<String> accountNames = [];
  String? account;
  bool isLoading = true;
  bool isProcessing = false;
  String? errorMessage;

  final NumberFormat numberFormat = NumberFormat.decimalPattern('vi_VN');
  static const int batchSize = 1000;

  @override
  void initState() {
    super.initState();
    _fetchInitialData();
  }

  Future<void> _fetchInitialData() async {
    setState(() {
      isLoading = true;
      errorMessage = null;
    });

    try {
      // Kiểm tra đơn vị tiền tệ của ticketItems
      final currencies = widget.ticketItems.map((item) => item['currency'] as String).toSet();
      if (currencies.isEmpty) {
        throw Exception('Không có đơn vị tiền tệ trong danh sách sản phẩm');
      }

      final supabase = widget.tenantClient;
      debugPrint('Fetching financial accounts for currencies: $currencies');
      final accountResponse = await supabase
          .from('financial_accounts')
          .select('name, currency, balance')
          .inFilter('currency', currencies.toList());

      final accountList = accountResponse
          .map((e) => {
                'name': e['name'] as String?,
                'currency': e['currency'] as String?,
                'balance': e['balance'] as num?,
              })
          .toList();

      if (accountList.isEmpty) {
        throw Exception('Không tìm thấy tài khoản nào cho các loại tiền tệ $currencies');
      }

      if (mounted) {
        setState(() {
          accounts = accountList;
          accountNames = accountList
              .where((e) => e['name'] != null)
              .map((e) => e['name'] as String)
              .toList();
          accountNames.add('Công nợ');
          isLoading = false;
          debugPrint('Loaded ${accounts.length} accounts for currencies $currencies');
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          errorMessage = 'Lỗi tải tài khoản: $e';
          isLoading = false;
        });
        debugPrint('Error fetching accounts: $e');
      }
    }
  }

  Map<String, double> _calculateTotalAmountByCurrency() {
    final amounts = <String, double>{};
    for (var item in widget.ticketItems) {
      final imeiCount = (item['imei'] as String).split(',').where((e) => e.trim().isNotEmpty).length;
      final currency = item['currency'] as String;
      final price = (item['price'] as num).toDouble();
      amounts[currency] = (amounts[currency] ?? 0) + price * imeiCount;
    }
    return amounts;
  }

  Future<Map<String, dynamic>> _createSnapshot(String ticketId, List<String> imeiList) async {
    try {
      final supabase = widget.tenantClient;
      final snapshotData = <String, dynamic>{};

      debugPrint('Creating snapshot for ticket $ticketId');
      // Lấy tất cả supplier IDs từ ticketItems
      final supplierIds = widget.ticketItems
          .map((item) => item['supplier_id']?.toString())
          .whereType<String>()
          .toSet()
          .toList();
      
      final suppliersDataList = <Map<String, dynamic>>[];
      for (var supplierId in supplierIds) {
        final supplierData = await supabase
            .from('suppliers')
            .select()
            .eq('id', supplierId)
            .maybeSingle();
        if (supplierData != null) {
          suppliersDataList.add(supplierData);
        }
      }
      snapshotData['suppliers'] = suppliersDataList;

      if (account != null && account != 'Công nợ') {
        final accountData = await supabase
            .from('financial_accounts')
            .select()
            .eq('name', account!)
            .inFilter('currency', widget.ticketItems.map((e) => e['currency']).toList())
            .single();
        snapshotData['financial_accounts'] = accountData;
      }

      // Chỉ lấy snapshot của các sản phẩm trong phiếu trả hàng
      if (imeiList.isNotEmpty) {
        final productsData = <Map<String, dynamic>>[];
        for (int i = 0; i < imeiList.length; i += batchSize) {
          final batchImeis = imeiList.sublist(i, math.min(i + batchSize, imeiList.length));
          final batchData = await supabase
              .from('products')
              .select()
              .inFilter('imei', batchImeis)
              .eq('status', 'Tồn kho'); // Chỉ lấy sản phẩm đang tồn kho
          productsData.addAll(batchData);
          debugPrint('Fetched snapshot data for ${batchData.length} products being returned in batch ${i ~/ batchSize + 1}');
        }
        snapshotData['products'] = productsData;
      }

      snapshotData['return_orders'] = widget.ticketItems.map((item) {
        final imeiList = (item['imei'] as String).split(',').where((e) => e.trim().isNotEmpty).toList();
        return {
          'ticket_id': ticketId,
          'supplier_id': item['supplier_id'],
          'product_id': item['product_id'],
          'product_name': item['product_name'],
          'imei': item['imei'],
          'quantity': imeiList.length,
          'price': item['price'],
          'currency': item['currency'],
          'account': account,
          'note': item['note'],
          'total_amount': (item['price'] as num) * imeiList.length,
        };
      }).toList();

      return snapshotData;
    } catch (e) {
      debugPrint('Error creating snapshot: $e');
      throw Exception('Lỗi tạo snapshot: $e');
    }
  }

  String generateTicketId() {
    final now = DateTime.now();
    final dateFormat = DateFormat('yyyyMMdd-HHmmss');
    final randomNum = (100 + (now.millisecondsSinceEpoch % 900)).toString();
    return 'RETURN-${dateFormat.format(now)}-$randomNum';
  }

  Future<bool> _validateForeignKeys() async {
    final supabase = widget.tenantClient;

    // Validate tất cả supplier IDs từ ticketItems
    final supplierIds = widget.ticketItems
        .map((item) => item['supplier_id']?.toString())
        .whereType<String>()
        .toSet();
    
    for (var supplierId in supplierIds) {
      debugPrint('Validating supplier_id: $supplierId');
      final supplierResponse = await supabase
          .from('suppliers')
          .select('id')
          .eq('id', supplierId)
          .maybeSingle();
      if (supplierResponse == null) {
        debugPrint('Invalid supplier_id: $supplierId');
        return false;
      }
    }

    for (final item in widget.ticketItems) {
      final productId = item['product_id'] as String;
      final imeiList = (item['imei'] as String).split(',').where((e) => e.trim().isNotEmpty).toList();

      debugPrint('Validating product_id: $productId');
      final productResponse = await supabase
          .from('products_name')
          .select('id')
          .eq('id', productId)
          .maybeSingle();
      if (productResponse == null) {
        debugPrint('Invalid product_id: $productId');
        return false;
      }

      if (imeiList.isNotEmpty) {
        debugPrint('Validating IMEIs: $imeiList');
        final imeiResponse = await supabase
            .from('products')
            .select('imei')
            .inFilter('imei', imeiList)
            .eq('status', 'Tồn kho');
        final validImeis = imeiResponse.map((e) => e['imei'] as String).toSet();
        final invalidImeis = imeiList.where((imei) => !validImeis.contains(imei)).toList();
        if (invalidImeis.isNotEmpty) {
          debugPrint('Invalid IMEIs: $invalidImeis');
          return false;
        }
      }
    }

    return true;
  }

  /// ✅ NEW: Validate return prices against import prices
  Future<Map<String, dynamic>> _validateReturnPrices() async {
    final supabase = widget.tenantClient;
    final warnings = <String>[];
    int totalOverpriced = 0;
    num totalLoss = 0;

    for (final item in widget.ticketItems) {
      final imeiList = (item['imei'] as String).split(',').where((e) => e.trim().isNotEmpty).toList();
      final returnPrice = (item['price'] as num?) ?? 0;
      final returnCurrency = item['currency'] as String? ?? 'VND';
      final productName = item['product_name'] as String? ?? 'Sản phẩm';

      if (imeiList.isEmpty) continue;

      // Get import prices for all IMEIs
      final imeiResponse = await supabase
          .from('products')
          .select('imei, import_price, import_currency')
          .inFilter('imei', imeiList);

      for (var product in imeiResponse) {
        final imei = product['imei'] as String;
        final importPrice = (product['import_price'] as num?) ?? 0;
        final importCurrency = product['import_currency'] as String? ?? 'VND';

        // Only compare if same currency
        if (returnCurrency == importCurrency && returnPrice > importPrice) {
          totalOverpriced++;
          final loss = returnPrice - importPrice;
          totalLoss += loss;
          warnings.add(
            '• $productName (${imei.substring(0, imei.length > 8 ? 8 : imei.length)}...): '
            'Giá trả ${_formatCurrency(returnPrice, returnCurrency)} '
            '> Giá nhập ${_formatCurrency(importPrice, importCurrency)} '
            '(Lỗ: ${_formatCurrency(loss, returnCurrency)})'
          );
        }
      }
    }

    return {
      'hasWarning': warnings.isNotEmpty,
      'warnings': warnings,
      'totalOverpriced': totalOverpriced,
      'totalLoss': totalLoss,
    };
  }

  String _formatCurrency(num amount, String currency) {
    final formatted = numberFormat.format(amount).replaceAll(',', '.');
    return '$formatted $currency';
  }

  void showConfirmDialog(BuildContext scaffoldContext) async {
    if (account == null) {
      if (mounted) {
        await showDialog(
          context: scaffoldContext,
          builder: (context) => AlertDialog(
            title: const Text('Thông báo'),
            content: const Text('Vui lòng chọn tài khoản thanh toán!'),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('Đóng'),
              ),
            ],
          ),
        );
      }
      debugPrint('No account selected');
      return;
    }

    if (widget.ticketItems.isEmpty) {
      if (mounted) {
        await showDialog(
          context: scaffoldContext,
          builder: (context) => AlertDialog(
            title: const Text('Thông báo'),
            content: const Text('Danh sách sản phẩm trống!'),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('Đóng'),
              ),
            ],
          ),
        );
      }
      debugPrint('Empty ticketItems');
      return;
    }

    // Kiểm tra tính hợp lệ của đơn vị tiền tệ
    final currencies = widget.ticketItems.map((item) => item['currency'] as String).toSet();
    if (currencies.length > 1) {
      if (mounted) {
        await showDialog(
          context: scaffoldContext,
          builder: (context) => AlertDialog(
            title: const Text('Thông báo'),
            content: const Text('Tất cả sản phẩm phải có cùng đơn vị tiền tệ!'),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('Đóng'),
              ),
            ],
          ),
        );
      }
      debugPrint('Multiple currencies detected: $currencies');
      return;
    }

    debugPrint('Starting ticket creation with ticketItems: ${widget.ticketItems}');
    debugPrint('Supplier: ${widget.supplier}, Account: $account, Currency: $currencies');

    // Hiển thị dialog "Đang xử lý"
    showDialog(
      context: scaffoldContext,
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

    // Kiểm tra khóa ngoại
    try {
      final isValid = await _validateForeignKeys();
      if (!isValid) {
        if (mounted) {
          Navigator.pop(scaffoldContext); // Đóng dialog "Đang xử lý"
          await showDialog(
            context: scaffoldContext,
            builder: (context) => AlertDialog(
              title: const Text('Thông báo'),
              content: const Text('Dữ liệu không hợp lệ: Nhà cung cấp, sản phẩm hoặc IMEI không tồn tại.'),
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
    } catch (e) {
      if (mounted) {
        Navigator.pop(scaffoldContext); // Đóng dialog "Đang xử lý"
        await showDialog(
          context: scaffoldContext,
          builder: (context) => AlertDialog(
            title: const Text('Thông báo'),
            content: Text('Lỗi kiểm tra dữ liệu: $e'),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('Đóng'),
              ),
            ],
          ),
        );
        debugPrint('Error validating foreign keys: $e');
      }
      return;
    }

    // ✅ NEW: Kiểm tra giá trả so với giá nhập
    try {
      final priceValidation = await _validateReturnPrices();
      if (priceValidation['hasWarning'] == true) {
        if (mounted) {
          Navigator.pop(scaffoldContext); // Đóng dialog "Đang xử lý"
          
          // Hiển thị cảnh báo với option tiếp tục hoặc hủy
          final shouldContinue = await showDialog<bool>(
            context: scaffoldContext,
            builder: (context) => AlertDialog(
              title: const Row(
                children: [
                  Icon(Icons.warning_amber_rounded, color: Colors.orange, size: 28),
                  SizedBox(width: 8),
                  Text('Cảnh báo: Giá Trả Cao'),
                ],
              ),
              content: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Phát hiện ${priceValidation['totalOverpriced']} sản phẩm có giá trả cao hơn giá nhập, '
                      'gây lỗ tổng cộng: ${_formatCurrency(priceValidation['totalLoss'], widget.currency)}',
                      style: const TextStyle(fontWeight: FontWeight.bold, color: Colors.red),
                    ),
                    const SizedBox(height: 12),
                    const Text('Chi tiết:', style: TextStyle(fontWeight: FontWeight.bold)),
                    const SizedBox(height: 8),
                    ...(priceValidation['warnings'] as List<String>).map((warning) => 
                      Padding(
                        padding: const EdgeInsets.only(bottom: 4),
                        child: Text(warning, style: const TextStyle(fontSize: 13)),
                      )
                    ),
                    const SizedBox(height: 12),
                    const Text(
                      'Điều này có thể do:\n'
                      '• Nhập sai giá trả\n'
                      '• NCC đồng ý đổi giá\n'
                      '• Trả hàng có chi phí phát sinh',
                      style: TextStyle(fontSize: 12, color: Colors.grey),
                    ),
                    const SizedBox(height: 8),
                    const Text(
                      'Bạn có chắc chắn muốn tiếp tục?',
                      style: TextStyle(fontWeight: FontWeight.bold),
                    ),
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(context, false),
                  child: const Text('Hủy - Kiểm tra lại', style: TextStyle(color: Colors.grey)),
                ),
                ElevatedButton(
                  onPressed: () => Navigator.pop(context, true),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.orange,
                  ),
                  child: const Text('Xác nhận - Tiếp tục'),
                ),
              ],
            ),
          );

          if (shouldContinue != true) {
            // User chose to cancel
            return;
          }
          
          // User confirmed, show processing dialog again
          if (mounted) {
            showDialog(
              context: scaffoldContext,
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
        }
      }
    } catch (e) {
      debugPrint('Error validating return prices: $e');
      // Non-blocking error, continue with ticket creation
    }

    if (!mounted) {
      Navigator.pop(scaffoldContext); // Đóng dialog "Đang xử lý"
      return;
    }

    // Thực hiện tạo phiếu
    try {
      final supabase = widget.tenantClient;
      final now = DateTime.now();
      debugPrint('Before generating ticketId');
      final ticketId = generateTicketId();
      debugPrint('Generated ticketId: $ticketId');

      // Tạo danh sách IMEI
      final allImeis = widget.ticketItems
          .expand((item) => (item['imei'] as String).split(',').where((e) => e.trim().isNotEmpty))
          .toList();

      // Tạo snapshot trước khi thay đổi dữ liệu
      debugPrint('Creating snapshot for IMEIs: $allImeis');
      final snapshotData = await _createSnapshot(ticketId, allImeis);
      debugPrint('Inserting snapshot');
      await supabase.from('snapshots').insert({
        'ticket_id': ticketId,
        'ticket_table': 'return_orders',
        'snapshot_data': snapshotData,
        'created_at': now.toIso8601String(),
      });

      debugPrint('Inserting return_orders');
      await supabase.from('return_orders').insert(widget.ticketItems.map((item) {
        final imeiList = (item['imei'] as String).split(',').where((e) => e.trim().isNotEmpty).toList();
        return {
          'ticket_id': ticketId,
          'supplier_id': item['supplier_id'],
          'product_id': item['product_id'],
          'product_name': item['product_name'],
          'imei': item['imei'],
          'quantity': imeiList.length,
          'price': item['price'],
          'currency': item['currency'],
          'account': account,
          'note': item['note'],
          'total_amount': (item['price'] as num) * imeiList.length,
          'created_at': now.toIso8601String(),
        };
      }).toList());

      // Update product status to "Đã trả ncc" instead of deleting
      for (final item in widget.ticketItems) {
        final imeiList = (item['imei'] as String).split(',').where((e) => e.trim().isNotEmpty).toList();
        if (imeiList.isNotEmpty) {
          debugPrint('Updating products with IMEIs to status "Đã trả ncc": $imeiList');
          for (int i = 0; i < imeiList.length; i += batchSize) {
            final batchImeis = imeiList.sublist(i, i + batchSize < imeiList.length ? i + batchSize : imeiList.length);
            await supabase.from('products')
              .update({
                'status': 'Đã trả ncc',
                'return_date': now.toIso8601String(),
              })
              .inFilter('imei', batchImeis);
          }
        }
      }

      // Tính tổng số lượng và lấy tên sản phẩm đầu tiên
      final totalQuantity = widget.ticketItems.fold<int>(0, (sum, item) {
        final imeiCount = (item['imei'] as String).split(',').where((e) => e.trim().isNotEmpty).length;
        return sum + imeiCount;
      });
      final firstProductName = widget.ticketItems.isNotEmpty ? widget.ticketItems.first['product_name'] as String : 'Không xác định';

      debugPrint('Sending notification');
      await NotificationService.showNotification(
        137,
        'Phiếu Trả Hàng Đã Tạo',
        'Đã trả hàng sản phẩm $firstProductName số lượng $totalQuantity',
        'return_created',
      );

      if (account == 'Công nợ') {
        debugPrint('Updating supplier debt');
        // Nhóm items theo supplier_id
        final supplierGroups = <String, List<Map<String, dynamic>>>{};
        for (var item in widget.ticketItems) {
          final supplierId = item['supplier_id']?.toString();
          if (supplierId != null && supplierId.isNotEmpty) {
            supplierGroups.putIfAbsent(supplierId, () => []).add(item);
          }
        }

        // Cập nhật công nợ cho từng supplier
        for (var supplierEntry in supplierGroups.entries) {
          final supplierId = supplierEntry.key;
          final items = supplierEntry.value;
          
          final currentSupplier = await supabase
              .from('suppliers')
              .select('debt_vnd, debt_cny, debt_usd')
              .eq('id', supplierId)
              .single();

          // Nhóm các items của supplier này theo currency
          final currenciesForSupplier = items.map((item) => item['currency'] as String).toSet();
          
          for (var currency in currenciesForSupplier) {
            String debtColumn;
            if (currency == 'VND') {
              debtColumn = 'debt_vnd';
            } else if (currency == 'CNY') {
              debtColumn = 'debt_cny';
            } else if (currency == 'USD') {
              debtColumn = 'debt_usd';
            } else {
              throw Exception('Loại tiền tệ không được hỗ trợ: $currency');
            }

            final totalAmount = items
                .where((item) => item['currency'] == currency)
                .fold<double>(0, (sum, item) {
                  final imeiCount = (item['imei'] as String).split(',').where((e) => e.trim().isNotEmpty).length;
                  return sum + (item['price'] as num).toDouble() * imeiCount;
                });

            final currentDebt = double.tryParse(currentSupplier[debtColumn]?.toString() ?? '0') ?? 0;
            final updatedDebt = currentDebt - totalAmount;

            await supabase
                .from('suppliers')
                .update({debtColumn: updatedDebt})
                .eq('id', supplierId);
          }
        }
      } else {
        debugPrint('Updating financial account balance');
        for (var currency in currencies) {
          final totalAmount = widget.ticketItems
              .where((item) => item['currency'] == currency)
              .fold<double>(0, (sum, item) {
                final imeiCount = (item['imei'] as String).split(',').where((e) => e.trim().isNotEmpty).length;
                return sum + (item['price'] as num).toDouble() * imeiCount;
              });

          final selectedAccount = accounts.firstWhere(
            (acc) => acc['name'] == account && acc['currency'] == currency,
            orElse: () => throw Exception('Không tìm thấy tài khoản cho đơn vị tiền $currency'),
          );
          final currentBalance = double.tryParse(selectedAccount['balance']?.toString() ?? '0') ?? 0;
          final updatedBalance = currentBalance + totalAmount;

          await supabase
              .from('financial_accounts')
              .update({'balance': updatedBalance})
              .eq('name', account!)
              .eq('currency', currency);
        }
      }

      if (mounted) {
        Navigator.pop(scaffoldContext); // Đóng dialog "Đang xử lý"
        await showDialog(
          context: scaffoldContext,
          builder: (context) => AlertDialog(
            title: const Text('Thông báo'),
            content: const Text('Đã tạo phiếu trả hàng thành công'),
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
        debugPrint('Ticket creation completed successfully');
      }
    } catch (e) {
      if (mounted) {
        Navigator.pop(scaffoldContext); // Đóng dialog "Đang xử lý"
        
        await ErrorHandler.showErrorDialog(
          context: scaffoldContext,
          title: 'Lỗi tạo phiếu trả hàng',
          error: e,
          showRetry: false, // Không retry vì quá phức tạp
        );
        
        debugPrint('Error creating ticket: $e');
      }
    }
  }

  Widget wrapField(Widget child) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      margin: const EdgeInsets.symmetric(vertical: 4),
      height: 40,
      decoration: BoxDecoration(
        color: Colors.grey.shade200,
        borderRadius: BorderRadius.circular(8),
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

    final totalAmounts = _calculateTotalAmountByCurrency();
    final totalAmountText = totalAmounts.entries
        .map((e) => '${formatNumberLocal(e.value)} ${e.key}')
        .join(', ');

    return Scaffold(
      appBar: AppBar(
        title: const Text('Danh sách sản phẩm', style: TextStyle(color: Colors.white)),
        backgroundColor: Colors.black,
        iconTheme: const IconThemeData(color: Colors.white),
      ),
      body: Column(
        children: [
          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Danh sách sản phẩm đã thêm:',
                    style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 8),
                  Container(
                    height: 300,
                    decoration: BoxDecoration(
                      border: Border.all(color: Colors.grey.shade300),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: ListView.builder(
                      itemCount: widget.ticketItems.length,
                      itemBuilder: (context, index) {
                        final item = widget.ticketItems[index];
                        return Card(
                          margin: const EdgeInsets.symmetric(vertical: 4, horizontal: 8),
                          child: Padding(
                            padding: const EdgeInsets.all(8.0),
                            child: Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      Text('Sản phẩm: ${item['product_name']}'),
                                      Text('IMEI: ${item['imei']}'),
                                      Text('Số tiền: ${formatNumberLocal(item['price'])} ${item['currency']}'),
                                      Text('Ghi chú: ${item['note'] ?? ''}'),
                                    ],
                                  ),
                                ),
                                Column(
                                  children: [
                                    IconButton(
                                      icon: const Icon(Icons.edit, color: Colors.blue, size: 20),
                                      onPressed: () {
                                        Navigator.push(
                                          context,
                                          MaterialPageRoute(
                                            builder: (context) => ReturnForm(
                                              tenantClient: widget.tenantClient,
                                              initialSupplier: widget.supplier,
                                              initialProductId: item['product_id'],
                                              initialProductName: item['product_name'],
                                              initialPrice: item['price'].toString(),
                                              initialImei: item['imei'],
                                              initialNote: item['note'],
                                              initialCurrency: item['currency'],
                                              ticketItems: widget.ticketItems,
                                              editIndex: index,
                                            ),
                                          ),
                                        );
                                      },
                                    ),
                                    IconButton(
                                      icon: const Icon(Icons.delete, color: Colors.red, size: 20),
                                      onPressed: () {
                                        setState(() {
                                          widget.ticketItems.removeAt(index);
                                          debugPrint('Removed ticket item at index $index');
                                        });
                                      },
                                    ),
                                  ],
                                ),
                              ],
                            ),
                          ),
                        );
                      },
                    ),
                  ),
                  const SizedBox(height: 16),
                  Text(
                    'Tổng tiền: $totalAmountText',
                    style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 8),
                  Text('Nhà cung cấp: ${widget.supplier}'),
                  const SizedBox(height: 8),
                  wrapField(
                    DropdownButtonFormField<String>(
                      value: account,
                      items: accountNames
                          .map((e) => DropdownMenuItem(value: e, child: Text(e)))
                          .toList(),
                      hint: const Text('Tài khoản'),
                      onChanged: (val) {
                        setState(() {
                          account = val;
                          debugPrint('Selected account: $val');
                        });
                      },
                      decoration: const InputDecoration(
                        border: InputBorder.none,
                        isDense: true,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(16.0),
            child: Row(
              children: [
                Expanded(
                  child: ElevatedButton(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.green,
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(vertical: 14),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                    onPressed: () {
                      Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (context) => ReturnForm(
                            tenantClient: widget.tenantClient,
                            initialSupplier: widget.supplier,
                            ticketItems: widget.ticketItems,
                            initialCurrency: widget.ticketItems.isNotEmpty ? widget.ticketItems.first['currency'] : 'VND',
                          ),
                        ),
                      );
                    },
                    child: const Text('Thêm Sản Phẩm'),
                  ),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: ElevatedButton(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.blue,
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(vertical: 14),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                    onPressed: () => showConfirmDialog(context),
                    child: const Text('Tạo Phiếu'),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  String formatNumberLocal(num number) {
    return numberFormat.format(number);
  }
}