import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:intl/intl.dart';
import '../../notification_service.dart';
import 'return_form.dart';
import 'dart:math' as math;
import '../../../../helpers/error_handler.dart';

// Constants for batch processing
const int maxBatchSize = 1000;
const int maxRetries = 3;
const Duration retryDelay = Duration(seconds: 1);

/// Retries a function with exponential backoff
Future<T> retry<T>(Future<T> Function() fn, {String? operation}) async {
  for (int attempt = 0; attempt < maxRetries; attempt++) {
    try {
      return await fn();
    } catch (e) {
      if (attempt == maxRetries - 1) {
        // On final attempt, throw with detailed error info
        if (e is PostgrestException) {
          throw Exception('${operation ?? 'Operation'} failed after $maxRetries attempts: PostgrestException(message: ${e.message}, code: ${e.code}, details: ${e.details}, hint: ${e.hint})');
        }
        throw Exception('${operation ?? 'Operation'} failed after $maxRetries attempts: $e');
      }
      // Exponential backoff
      await Future.delayed(retryDelay * math.pow(2, attempt).toInt());
    }
  }
  throw Exception('${operation ?? 'Operation'} failed: Unexpected error');
}

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
    if (isProcessing) return;
    
    // Set isProcessing ngay để ngăn double-submit
    setState(() {
      isProcessing = true;
    });

    if (account == null) {
      setState(() {
        isProcessing = false;
      });
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
      setState(() {
        isProcessing = false;
      });
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
      setState(() {
        isProcessing = false;
      });
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
        setState(() {
          isProcessing = false;
        });
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

      // Prepare return orders list
      final returnOrdersList = widget.ticketItems.map((item) {
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
      }).toList();

      // Prepare products updates
      final productsUpdatesList = <Map<String, dynamic>>[];
      for (final item in widget.ticketItems) {
        final imeiList = (item['imei'] as String).split(',').where((e) => e.trim().isNotEmpty).toList();
        for (var imei in imeiList) {
          productsUpdatesList.add({
            'imei': imei,
            'status': 'Đã trả ncc',
            'return_date': now.toIso8601String(),
          });
        }
      }

      // Prepare suppliers debt changes
      final suppliersDebtChangesList = <Map<String, dynamic>>[];
      if (account == 'Công nợ') {
        // Nhóm items theo supplier_id
        final supplierGroups = <String, List<Map<String, dynamic>>>{};
        for (var item in widget.ticketItems) {
          final supplierId = item['supplier_id']?.toString();
          if (supplierId != null && supplierId.isNotEmpty) {
            supplierGroups.putIfAbsent(supplierId, () => []).add(item);
          }
        }

        // Tính debt change cho từng supplier
        for (var supplierEntry in supplierGroups.entries) {
          final supplierId = supplierEntry.key;
          final items = supplierEntry.value;

          double debtVnd = 0;
          double debtCny = 0;
          double debtUsd = 0;

          for (var item in items) {
            final imeiCount = (item['imei'] as String).split(',').where((e) => e.trim().isNotEmpty).length;
            final totalAmount = (item['price'] as num).toDouble() * imeiCount;
            final currency = item['currency'] as String;

            if (currency == 'VND') {
              debtVnd -= totalAmount; // Negative because debt decreases
            } else if (currency == 'CNY') {
              debtCny -= totalAmount;
            } else if (currency == 'USD') {
              debtUsd -= totalAmount;
            }
          }

          suppliersDebtChangesList.add({
            'supplier_id': supplierId,
            'debt_vnd': debtVnd,
            'debt_cny': debtCny,
            'debt_usd': debtUsd,
          });
        }
      }

      // Prepare account balance change (for each currency)
      double? accountBalanceChange;
      String? primaryCurrency;
      if (account != null && account != 'Công nợ' && currencies.isNotEmpty) {
        // Use first currency for RPC (will handle multiple currencies separately)
        primaryCurrency = currencies.first;
        final totalAmount = widget.ticketItems
            .where((item) => item['currency'] == primaryCurrency)
            .fold<double>(0, (sum, item) {
              final imeiCount = (item['imei'] as String).split(',').where((e) => e.trim().isNotEmpty).length;
              return sum + (item['price'] as num).toDouble() * imeiCount;
            });
        accountBalanceChange = totalAmount; // Positive because money comes back
      }

      // Debug logging
      debugPrint('🔍 DEBUG: Calling return RPC with data:');
      debugPrint('  ticket_id: $ticketId');
      debugPrint('  return_orders count: ${returnOrdersList.length}');
      debugPrint('  products_updates count: ${productsUpdatesList.length}');
      debugPrint('  suppliers_debt_changes count: ${suppliersDebtChangesList.length}');
      debugPrint('  account_balance_change: $accountBalanceChange');

      // ✅ CALL RPC FUNCTION - All operations in ONE atomic transaction
      final result = await retry(
        () => supabase.rpc('create_return_transaction', params: {
          'p_ticket_id': ticketId,
          'p_return_orders': returnOrdersList,
          'p_products_updates': productsUpdatesList,
          'p_suppliers_debt_changes': suppliersDebtChangesList,
          'p_account_balance_change': accountBalanceChange,
          'p_account': account ?? '',
          'p_currency': primaryCurrency ?? 'VND',
          'p_snapshot_data': snapshotData,
          'p_created_at': now.toIso8601String(),
        }),
        operation: 'Create return transaction (RPC)',
      );

      // Check result
      if (result == null || result['success'] != true) {
        throw Exception('RPC function returned error: ${result?['message'] ?? 'Unknown error'}');
      }

      debugPrint('✅ Return transaction created successfully via RPC!');

      // Handle additional currencies if needed (for financial accounts only)
      if (account != null && account != 'Công nợ' && currencies.length > 1) {
        for (var currency in currencies.skip(1)) {
          final totalAmount = widget.ticketItems
              .where((item) => item['currency'] == currency)
              .fold<double>(0, (sum, item) {
                final imeiCount = (item['imei'] as String).split(',').where((e) => e.trim().isNotEmpty).length;
                return sum + (item['price'] as num).toDouble() * imeiCount;
              });

          if (totalAmount > 0) {
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
      
      // ✅ Gửi thông báo push đến tất cả thiết bị
      await NotificationService.sendNotificationToAll(
        'Phiếu Trả Hàng Đã Tạo',
        'Đã trả hàng sản phẩm $firstProductName số lượng $totalQuantity',
        data: {'type': 'return_created'},
      );

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
                                      Text('Nhà cung cấp: ${item['supplier_name'] ?? 'N/A'}'),
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
                                              initialSupplierId: item['supplier_id']?.toString(),
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