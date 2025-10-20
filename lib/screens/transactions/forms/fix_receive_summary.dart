import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:intl/intl.dart';
import '../../notification_service.dart';
import 'fix_receive_form.dart';
import 'dart:math' as math;

// Cache utility class
class CacheUtil {
  static final Map<String, String> productNameCache = {};
  static final Map<String, String> warehouseNameCache = {};

  static void cacheProductName(String id, String name) => productNameCache[id] = name;
  static void cacheWarehouseName(String id, String name) => warehouseNameCache[id] = name;
  static String getProductName(String? id) => id != null ? productNameCache[id] ?? 'Không xác định' : 'Không xác định';
  static String getWarehouseName(String? id) => id != null ? warehouseNameCache[id] ?? 'Không xác định' : 'Không xác định';
}

// Constants for batch processing and limits
const int maxBatchSize = 1000;
const int maxRetries = 3;
const Duration retryDelay = Duration(seconds: 1);
const int maxImeiLimit = 100000;
const int maxTicketItems = 100;
const int displayImeiLimit = 100;

/// Retries a function with exponential backoff
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

class FixReceiveSummary extends StatefulWidget {
  final SupabaseClient tenantClient;
  final List<Map<String, dynamic>> ticketItems;
  final String currency;

  const FixReceiveSummary({
    super.key,
    required this.tenantClient,
    required this.ticketItems,
    required this.currency,
  });

  @override
  State<FixReceiveSummary> createState() => _FixReceiveSummaryState();
}

class _FixReceiveSummaryState extends State<FixReceiveSummary> {
  List<Map<String, Object?>> accounts = [];
  List<String> accountNames = [];
  String? account;
  bool isLoading = true;
  bool isProcessing = false;
  String? errorMessage;
  late List<Map<String, dynamic>> ticketItems;

  final NumberFormat numberFormat = NumberFormat.decimalPattern('vi_VN');

  @override
  void initState() {
    super.initState();
    ticketItems = List.from(widget.ticketItems);
    _fetchInitialData();
  }

  Future<void> _fetchInitialData() async {
    setState(() {
      isLoading = true;
      errorMessage = null;
    });

    try {
      final supabase = widget.tenantClient;

      final accountResponse = await retry(
        () => supabase
            .from('financial_accounts')
            .select('name, currency, balance')
            .eq('currency', widget.currency),
        operation: 'Fetch accounts',
      );
      final accountList = accountResponse
          .map((e) => {
                'name': e['name'] as String?,
                'currency': e['currency'] as String?,
                'balance': e['balance'] as num?,
              })
          .where((e) => e['name'] != null && e['currency'] != null)
          .cast<Map<String, Object?>>()
          .toList();

      if (mounted) {
        setState(() {
          accounts = accountList;
          accountNames = accountList.map((acc) => acc['name'] as String).toList();
          accountNames.add('Công nợ');
          isLoading = false;
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

  double _calculateTotalAmount() {
    return ticketItems.fold(0, (sum, item) => sum + (item['price'] as num) * (item['quantity'] as int));
  }

  Future<Map<String, dynamic>> _createSnapshot(String ticketId, List<String> imeiList) async {
    final supabase = widget.tenantClient;
    final snapshotData = <String, dynamic>{};

    try {
      if (account != null && account != 'Công nợ') {
        final accountData = await retry(
          () => supabase
              .from('financial_accounts')
              .select()
              .eq('name', account!)
              .eq('currency', widget.currency)
              .single(),
          operation: 'Fetch account data',
        );
        snapshotData['financial_accounts'] = accountData;
      }

      if (account == 'Công nợ') {
        final fixerNames = ticketItems.map((item) => item['fixer'] as String).toSet();
        final fixerData = await retry(
          () => supabase
              .from('fix_units')
              .select()
              .inFilter('name', fixerNames.toList()),
          operation: 'Fetch fixer data',
        );
        snapshotData['fix_units'] = fixerData;
      }

      if (imeiList.isNotEmpty) {
        List<Map<String, dynamic>> productsData = [];
        for (int i = 0; i < imeiList.length; i += maxBatchSize) {
          final batchImeis = imeiList.sublist(i, math.min(i + maxBatchSize, imeiList.length));
          final response = await retry(
            () => supabase.from('products').select('imei, product_id, warehouse_id, status, fix_price, cost_price, fix_unit').inFilter('imei', batchImeis),
            operation: 'Fetch products snapshot batch ${i ~/ maxBatchSize + 1}',
          );
          productsData.addAll(response.cast<Map<String, dynamic>>());
        }
        snapshotData['products'] = productsData;
      }

      snapshotData['fix_receive_orders'] = ticketItems.map((item) {
        return {
          'ticket_id': ticketId,
          'fixer': item['fixer'],
          'product_id': item['product_id'],
          'product_name': item['product_name'],
          'warehouse_id': item['warehouse_id'],
          'warehouse_name': item['warehouse_name'],
          'imei': item['imei'],
          'quantity': item['quantity'],
          'price': item['price'],
          'currency': item['currency'],
          'account': account,
        };
      }).toList();

      return snapshotData;
    } catch (e) {
      throw Exception('Failed to create snapshot: $e');
    }
  }

  Future<num> _getExchangeRate(String currency) async {
    try {
      final supabase = widget.tenantClient;
      final response = await retry(
        () => supabase
            .from('financial_orders')
            .select('rate_vnd_cny, rate_vnd_usd')
            .eq('type', 'exchange')
            .order('created_at', ascending: false)
            .limit(1)
            .maybeSingle(),
        operation: 'Fetch exchange rate',
      );

      if (response == null) return 1;

      if (currency == 'CNY' && response['rate_vnd_cny'] != null) {
        final rate = response['rate_vnd_cny'] as num;
        return rate != 0 ? rate : 1;
      } else if (currency == 'USD' && response['rate_vnd_usd'] != null) {
        final rate = response['rate_vnd_usd'] as num;
        return rate != 0 ? rate : 1;
      }
      return 1;
    } catch (e) {
      return 1;
    }
  }

  String generateTicketId() {
    final now = DateTime.now();
    final dateFormat = DateFormat('yyyyMMdd-HHmmss');
    final randomNum = (100 + (now.millisecondsSinceEpoch % 900)).toString();
    return 'FIXRECV-${dateFormat.format(now)}-$randomNum';
  }

  String formatNumberLocal(num value) {
    return NumberFormat('#,###', 'vi_VN').format(value).replaceAll(',', '.');
  }

  Future<bool> _validateImeis(List<String> allImeis) async {
    final supabase = widget.tenantClient;
    List<String> validImeis = [];

    try {
      for (int i = 0; i < allImeis.length; i += maxBatchSize) {
        final batchImeis = allImeis.sublist(i, math.min(i + maxBatchSize, allImeis.length));
        final response = await retry(
          () => supabase
              .from('products')
              .select('imei, product_id, status, fix_unit')
              .inFilter('imei', batchImeis)
              .eq('status', 'Đang sửa'),
          operation: 'Validate IMEIs batch ${i ~/ maxBatchSize + 1}',
        );

        validImeis.addAll(
          response
              .where((p) => ticketItems.any((item) => p['product_id'] == item['product_id'] && p['fix_unit'] == item['fixer']))
              .map((p) => p['imei'] as String),
        );
      }

      final invalidImeis = allImeis.where((imei) => !validImeis.contains(imei)).toList();
      if (invalidImeis.isNotEmpty && mounted) {
        await showDialog(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('Thông báo'),
            content: Text('Các IMEI sau không hợp lệ, không ở trạng thái "Đang sửa", hoặc không thuộc đơn vị sửa: ${invalidImeis.take(10).join(', ')}${invalidImeis.length > 10 ? '... (tổng cộng ${invalidImeis.length} IMEI)' : ''}'),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('Đóng'),
              ),
            ],
          ),
        );
        return false;
      }
      return true;
    } catch (e) {
      if (mounted) {
        await showDialog(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('Thông báo'),
            content: Text('Lỗi khi kiểm tra IMEI: $e'),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('Đóng'),
              ),
            ],
          ),
        );
      }
      return false;
    }
  }

  Future<void> _rollbackChanges(Map<String, dynamic> snapshot, String ticketId) async {
    final supabase = widget.tenantClient;
    
    try {
      // Rollback fix units
      if (snapshot['fix_units'] != null) {
        for (var fixUnit in snapshot['fix_units']) {
          await supabase
            .from('fix_units')
            .update(fixUnit)
            .eq('name', fixUnit['name']);
        }
      }

      // Rollback financial accounts
      if (snapshot['financial_accounts'] != null && account != null) {
        await supabase
          .from('financial_accounts')
          .update(snapshot['financial_accounts'])
          .eq('name', account!)
          .eq('currency', widget.currency);
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

      // Delete created fix receive orders
      await supabase
        .from('fix_receive_orders')
        .delete()
        .eq('ticket_id', ticketId);

    } catch (e) {
      print('Error during rollback: $e');
      throw Exception('Lỗi khi rollback dữ liệu: $e');
    }
  }

  Future<bool> _verifyData(String ticketId, List<String> imeiList) async {
    final supabase = widget.tenantClient;
    
    try {
      // Verify fix units data if using debt
      if (account == 'Công nợ') {
        final fixerNames = ticketItems.map((item) => item['fixer'] as String).toSet();
        for (var fixer in fixerNames) {
          final fixerData = await supabase
              .from('fix_units')
              .select()
              .eq('name', fixer)
              .single();
          if (fixerData == null) return false;
        }
      }
      
      // Verify products data
      final productsData = await supabase
          .from('products')
          .select('status, fix_unit, warehouse_id')
          .inFilter('imei', imeiList);
      
      // Verify fix receive orders
      final fixReceiveOrders = await supabase
          .from('fix_receive_orders')
          .select()
          .eq('ticket_id', ticketId);

      // Verify all IMEIs are marked as in stock and assigned to correct warehouse
      for (var product in productsData) {
        if (product['status'] != 'Tồn kho' || 
            product['fix_unit'] != null) {
          return false;
        }
      }

      // Verify all fix receive orders are created
      if (fixReceiveOrders.length != ticketItems.length) {
        return false;
      }

      // Verify financial account if used
      if (account != null && account != 'Công nợ') {
        final accountData = await supabase
            .from('financial_accounts')
            .select()
            .eq('name', account!)
            .eq('currency', widget.currency)
            .single();
        if (accountData == null) return false;
      }

      return true;
    } catch (e) {
      print('Error during data verification: $e');
      return false;
    }
  }

  Future<void> createTicket(BuildContext scaffoldContext) async {
    if (isProcessing) return;

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
      return;
    }

    if (ticketItems.isEmpty) {
      if (mounted) {
        showDialog(
          context: scaffoldContext,
          builder: (context) => AlertDialog(
            title: const Text('Thông báo'),
            content: const Text('Vui lòng thêm ít nhất một sản phẩm để tạo phiếu!'),
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

    if (ticketItems.length > maxTicketItems) {
      if (mounted) {
        showDialog(
          context: scaffoldContext,
          builder: (context) => AlertDialog(
            title: const Text('Thông báo'),
            content: Text('Số lượng mục (${ticketItems.length}) vượt quá $maxTicketItems. Vui lòng giảm số mục để tối ưu hiệu suất.'),
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

    final allImeis = ticketItems.expand((item) => (item['imei'] as String).split(',').where((e) => e.trim().isNotEmpty)).toList();
    if (allImeis.length > maxImeiLimit) {
      if (mounted) {
        showDialog(
          context: scaffoldContext,
          builder: (context) => AlertDialog(
            title: const Text('Thông báo'),
            content: Text('Số lượng IMEI (${formatNumberLocal(allImeis.length)}) vượt quá $maxImeiLimit. Vui lòng chia thành nhiều phiếu nhỏ hơn.'),
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

    if (!await _validateImeis(allImeis)) return;

    setState(() {
      isProcessing = true;
    });

    final ticketId = generateTicketId();

    // Create snapshot before any changes
    Map<String, dynamic> snapshot;
    try {
      snapshot = await _createSnapshot(ticketId, allImeis);
    } catch (e) {
      setState(() {
        isProcessing = false;
        errorMessage = 'Lỗi khi tạo snapshot: $e';
      });
      return;
    }

    try {
      final supabase = widget.tenantClient;
      final now = DateTime.now();
      final totalAmount = _calculateTotalAmount();

      final exchangeRate = await _getExchangeRate(widget.currency);
      if (exchangeRate == 1 && widget.currency != 'VND') {
        throw Exception('Vui lòng tạo phiếu đổi tiền để cập nhật tỷ giá cho ${widget.currency}.');
      }

      if (account != 'Công nợ') {
        final selectedAccount = accounts.firstWhere((acc) => acc['name'] == account);
        final currentBalance = selectedAccount['balance'] as num? ?? 0;
        if (currentBalance < totalAmount) {
          throw Exception('Tài khoản không đủ số dư để thanh toán!');
        }
      }

      // Insert snapshot
      await retry(
        () => supabase.from('snapshots').insert({
          'ticket_id': ticketId,
          'ticket_table': 'fix_receive_orders',
          'snapshot_data': snapshot,
          'created_at': now.toIso8601String(),
        }),
        operation: 'Insert snapshot',
      );

      // Prepare and insert fix receive orders
      final fixReceiveOrders = ticketItems.map((item) {
        return {
          'ticket_id': ticketId,
          'fixer': item['fixer'],
          'product_id': item['product_id'],
          'warehouse_id': item['warehouse_id'],
          'imei': item['imei'],
          'quantity': item['quantity'],
          'price': item['price'],
          'currency': item['currency'],
          'account': account,
          'created_at': now.toIso8601String(),
          'iscancelled': false,
        };
      }).toList();

      await retry(
        () => supabase.from('fix_receive_orders').insert(fixReceiveOrders),
        operation: 'Insert fix_receive_orders',
      );

      // Update products
      for (var item in ticketItems) {
        final imeiList = (item['imei'] as String).split(',').where((e) => e.trim().isNotEmpty).toList();
        for (var imei in imeiList) {
          num fixCostPerItemInVND = item['price'] as num;
          if (item['currency'] == 'CNY') {
            fixCostPerItemInVND *= exchangeRate;
          } else if (item['currency'] == 'USD') {
            fixCostPerItemInVND *= exchangeRate;
          }

          // Lấy giá vốn ban đầu (cost_price) và giá fix lỗi hiện tại (fix_price) từ bảng products
          final productResponse = await retry(
            () => supabase
                .from('products')
                .select('cost_price, fix_price')
                .eq('imei', imei)
                .eq('product_id', item['product_id'])
                .single(),
            operation: 'Fetch cost_price and fix_price for product $imei',
          );

          final oldCostPrice = productResponse['cost_price'] as num? ?? 0;
          final oldFixPrice = productResponse['fix_price'] as num? ?? 0; // Lấy fix_price cũ, mặc định là 0 nếu null
          final newCostPrice = oldCostPrice + fixCostPerItemInVND;
          final newFixPrice = oldFixPrice + fixCostPerItemInVND; // Cộng dồn fix_price cũ với fixCostPerItemInVND

          await retry(
            () => supabase.from('products').update({
              'status': 'Tồn kho',
              'fix_unit': null,
              'send_fix_date': null,
              'warehouse_id': item['warehouse_id'],
              'fix_price': newFixPrice, // Cập nhật fix_price mới
              'fix_currency': 'VND',
              'fix_receive_date': now.toIso8601String(),
              'cost_price': newCostPrice,
            }).eq('imei', imei).eq('product_id', item['product_id']),
            operation: 'Update product $imei',
          );
        }
      }

      // Update financial data
      if (account == 'Công nợ') {
        for (var item in ticketItems) {
          final fixer = item['fixer'] as String;
          final debtColumn = 'debt_${widget.currency.toLowerCase()}';
          final currentDebtResponse = await retry(
            () => supabase
                .from('fix_units')
                .select(debtColumn)
                .eq('name', fixer)
                .single(),
            operation: 'Fetch fixer debt',
          );
          final currentDebt = currentDebtResponse[debtColumn] as num? ?? 0;
          final itemAmount = (item['price'] as num) * (item['quantity'] as int);
          final updatedDebt = currentDebt + itemAmount;
          await retry(
            () => supabase
                .from('fix_units')
                .update({debtColumn: updatedDebt})
                .eq('name', fixer),
            operation: 'Update fixer debt for $fixer',
          );
        }
      } else {
        final selectedAccount = accounts.firstWhere((acc) => acc['name'] == account);
        final currentBalance = selectedAccount['balance'] as num? ?? 0;
        final updatedBalance = currentBalance - totalAmount;
        await retry(
          () => supabase
              .from('financial_accounts')
              .update({'balance': updatedBalance})
              .eq('name', account!)
              .eq('currency', widget.currency),
            operation: 'Update financial account balance',
        );
      }

      // After all updates, verify the data
      final isDataValid = await _verifyData(ticketId, allImeis);
      if (!isDataValid) {
        // If data verification fails, rollback changes
        await _rollbackChanges(snapshot, ticketId);
        throw Exception('Dữ liệu không khớp sau khi cập nhật. Đã rollback thay đổi.');
      }

      await NotificationService.showNotification(
        130,
        'Phiếu Nhận Hàng Đã Tạo',
        'Đã tạo phiếu nhận hàng sửa về kho',
        'fix_receive_created',
      );

      if (mounted) {
        setState(() {
          isProcessing = false;
        });
        await showDialog(
          context: scaffoldContext,
          builder: (context) => AlertDialog(
            title: const Text('Thông báo'),
            content: const Text('Đã tạo phiếu nhận sửa thành công'),
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
          isProcessing = false;
          errorMessage = e.toString();
        });
      }
    }
  }

  Widget wrapField(Widget child) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      margin: const EdgeInsets.symmetric(vertical: 4),
      height: 48,
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

    final totalAmount = _calculateTotalAmount();

    return Scaffold(
      appBar: AppBar(
        title: const Text('Danh sách sản phẩm nhận sửa', style: TextStyle(color: Colors.white)),
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
                      itemCount: ticketItems.length,
                      itemBuilder: (context, index) {
                        final item = ticketItems[index];
                        final imeiList = (item['imei'] as String).split(',').where((e) => e.trim().isNotEmpty).toList();
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
                                      Text('Đơn vị sửa: ${item['fixer'] ?? 'Không xác định'}'),
                                      Text('Sản phẩm: ${item['product_name'] ?? 'Không xác định'}'),
                                      Text('Kho nhận: ${item['warehouse_name'] ?? 'Không xác định'}'),
                                      Text('Số lượng IMEI: ${formatNumberLocal(item['quantity'])}'),
                                      Text('Chi phí mỗi sản phẩm: ${formatNumberLocal(item['price'])} ${item['currency']}'),
                                      if (imeiList.length <= displayImeiLimit) ...[
                                        Text('IMEI:'),
                                        ...imeiList.map((imei) => Text('- $imei')),
                                      ] else
                                        Text('IMEI: ${imeiList.take(displayImeiLimit).join(', ')}... và ${formatNumberLocal(imeiList.length - displayImeiLimit)} IMEI khác'),
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
                                            builder: (context) => FixReceiveForm(
                                              tenantClient: widget.tenantClient,
                                              initialProductId: item['product_id'] as String?,
                                              initialPrice: (item['price'] ?? 0).toString(),
                                              initialImei: item['imei'] as String?,
                                              initialCurrency: item['currency'] as String?,
                                              initialWarehouseId: item['warehouse_id'] as String?,
                                              ticketItems: ticketItems,
                                              editIndex: index,
                                            ),
                                          ),
                                        );
                                      },
                                    ),
                                    IconButton(
                                      icon: const Icon(Icons.delete, color: Colors.red, size: 20),
                                      onPressed: () {
                                        if (mounted) {
                                          setState(() {
                                            ticketItems.removeAt(index);
                                          });
                                        }
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
                    'Tổng tiền: ${formatNumberLocal(totalAmount)} ${widget.currency}',
                    style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 8),
                  wrapField(
                    DropdownButtonFormField<String>(
                      value: account,
                      items: accountNames.map((e) => DropdownMenuItem(value: e, child: Text(e))).toList(),
                      hint: const Text('Tài khoản'),
                      onChanged: (val) {
                        setState(() {
                          account = val;
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
                          builder: (context) => FixReceiveForm(
                            tenantClient: widget.tenantClient,
                            ticketItems: ticketItems,
                            initialCurrency: widget.currency,
                            initialWarehouseId: ticketItems.isNotEmpty ? ticketItems.last['warehouse_id'] as String? : null,
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
                    onPressed: isProcessing ? null : () => createTicket(context),
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
}