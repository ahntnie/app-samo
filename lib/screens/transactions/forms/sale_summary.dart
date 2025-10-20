import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:intl/intl.dart';
import '../../notification_service.dart';
import 'sale_form.dart';
import 'dart:math' as math;

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
        throw Exception('${operation ?? 'Operation'} failed after $maxRetries attempts: $e');
      }
      await Future.delayed(retryDelay * math.pow(2, attempt));
    }
  }
  throw Exception('Retry failed');
}

class SaleSummary extends StatefulWidget {
  final SupabaseClient tenantClient;
  final String customer;
  final List<Map<String, dynamic>> ticketItems;
  final String salesman;
  final String currency;

  const SaleSummary({
    super.key,
    required this.tenantClient,
    required this.customer,
    required this.ticketItems,
    required this.salesman,
    required this.currency,
  });

  @override
  State<SaleSummary> createState() => _SaleSummaryState();
}

class _SaleSummaryState extends State<SaleSummary> {
  List<Map<String, Object?>> accounts = [];
  List<String> accountNames = [];
  List<String> localTransporters = [];
  String? account;
  String? transporter;
  String? deposit;
  double codAmount = 0;
  double customerDebt = 0;
  bool isLoading = true;
  bool isProcessing = false;
  String? errorMessage;
  String? depositError;

  final TextEditingController depositController = TextEditingController();
  final NumberFormat numberFormat = NumberFormat.decimalPattern('vi_VN');

  @override
  void initState() {
    super.initState();
    _fetchInitialData();
  }

  @override
  void dispose() {
    depositController.dispose();
    super.dispose();
  }

  Future<void> _fetchInitialData() async {
    setState(() {
      isLoading = true;
      errorMessage = null;
    });

    try {
      final supabase = widget.tenantClient;

      final accountResponse = await retry(
        () => supabase.from('financial_accounts').select('id, name, currency, balance').eq('currency', widget.currency),
        operation: 'Fetch financial accounts',
      );
      final accountList = (accountResponse as List<dynamic>)
          .map((e) => {
                'id': e['id'] as int,
                'name': e['name'] as String?,
                'currency': e['currency'] as String?,
                'balance': e['balance'] as num?,
              })
          .where((e) => e['name'] != null && e['currency'] != null)
          .cast<Map<String, Object?>>()
          .toList();

      final transporterResponse = await retry(
        () => supabase.from('transporters').select('name').eq('type', 'vận chuyển nội địa'),
        operation: 'Fetch transporters',
      );
      final transporterList = (transporterResponse as List<dynamic>).map((e) => e['name'] as String?).whereType<String>().toList();

      final customerResponse = await retry(
        () => supabase.from('customers').select('debt_vnd').eq('name', widget.customer).single(),
        operation: 'Fetch customer debt',
      );
      final debt = double.tryParse(customerResponse['debt_vnd'].toString()) ?? 0;

      if (mounted) {
        setState(() {
          accounts = accountList;
          localTransporters = transporterList;
          customerDebt = debt < 0 ? -debt : 0;
          accountNames = accountList.map((acc) => acc['name'] as String).toList();
          accountNames.add('Công nợ');
          accountNames.add('Ship COD');
          isLoading = false;
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

  double _calculateTotalAmount() {
    return widget.ticketItems.fold(0, (sum, item) {
      final imeiCount = (item['imei'] as String).split(',').where((e) => e.trim().isNotEmpty).length;
      return sum + (item['price'] as double) * imeiCount;
    });
  }

  int _calculateTotalImeiCount() {
    return widget.ticketItems.fold(0, (sum, item) {
      return sum + (item['imei'] as String).split(',').where((e) => e.trim().isNotEmpty).length;
    });
  }

  String _getFirstProductName() {
    return widget.ticketItems.isNotEmpty ? widget.ticketItems.first['product_name'] as String : 'Không xác định';
  }

  Future<Map<String, dynamic>> _createSnapshot(String ticketId, List<String> imeiList) async {
    final supabase = widget.tenantClient;
    final snapshotData = <String, dynamic>{};

    try {
      final customerData = await retry(
        () => supabase.from('customers').select().eq('name', widget.customer).single(),
        operation: 'Fetch customer for snapshot',
      );
      snapshotData['customers'] = customerData;

      if (account == 'Ship COD' && transporter != null) {
        final transporterData = await retry(
          () => supabase.from('transporters').select().eq('name', transporter!).single(),
          operation: 'Fetch transporter for snapshot',
        );
        snapshotData['transporters'] = transporterData;
      }

      if (account != null && account != 'Công nợ' && account != 'Ship COD') {
        final accountData = await retry(
          () => supabase.from('financial_accounts').select().eq('name', account!).eq('currency', widget.currency).single(),
          operation: 'Fetch financial account for snapshot',
        );
        snapshotData['financial_accounts'] = accountData;
      }

      if (imeiList.isNotEmpty) {
        final response = await retry(
          () => supabase.from('products').select('*, saleman').inFilter('imei', imeiList),
          operation: 'Fetch products for snapshot',
        );
        snapshotData['products'] = response as List<dynamic>;
      }

      snapshotData['sale_orders'] = widget.ticketItems.map((item) {
        final imeiList = (item['imei'] as String).split(',').where((e) => e.trim().isNotEmpty).toList();
        return {
          'ticket_id': ticketId,
          'customer': widget.customer,
          'product_id': item['product_id'],
          'product_name': item['product_name'],
          'imei': item['imei'],
          'quantity': imeiList.length,
          'price': item['price'],
          'currency': item['currency'],
          'account': account,
          'note': item['note'],
        };
      }).toList();

      return snapshotData;
    } catch (e) {
      throw Exception('Failed to create snapshot: $e');
    }
  }

  Future<double> _getExchangeRate(String currency) async {
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
        operation: 'Get exchange rate',
      );

      if (response == null) return 1;

      if (currency == 'CNY' && response['rate_vnd_cny'] != null) {
        final rate = double.tryParse(response['rate_vnd_cny'].toString()) ?? 0;
        return rate != 0 ? rate : 1;
      } else if (currency == 'USD' && response['rate_vnd_usd'] != null) {
        final rate = double.tryParse(response['rate_vnd_usd'].toString()) ?? 0;
        return rate != 0 ? rate : 1;
      }
      return 1;
    } catch (e) {
      print('Error getting exchange rate: $e');
      return 1;
    }
  }

  String generateTicketId() {
    final now = DateTime.now();
    final dateFormat = DateFormat('yyyyMMdd-HHmmss');
    final randomNum = (100 + (now.millisecondsSinceEpoch % 900)).toString();
    return 'SALE-${dateFormat.format(now)}-$randomNum';
  }

  String formatNumberLocal(num value) {
    return NumberFormat('#,###', 'vi_VN').format(value).replaceAll(',', '.');
  }

  Future<void> _rollbackChanges(Map<String, dynamic> snapshot, String ticketId) async {
    final supabase = widget.tenantClient;

    try {
      if (snapshot.containsKey('customers') && snapshot['customers'] != null) {
        try {
          await retry(
            () => supabase.from('customers').update(snapshot['customers']).eq('name', widget.customer),
            operation: 'Rollback customers',
          );
        } catch (e) {
          print('Rollback customers failed: $e');
        }
      }

      if (snapshot.containsKey('transporters') && snapshot['transporters'] != null && transporter != null) {
        try {
          await retry(
            () => supabase.from('transporters').update(snapshot['transporters']).eq('name', transporter!),
            operation: 'Rollback transporters',
          );
        } catch (e) {
          print('Rollback transporters failed: $e');
        }
      }

      if (snapshot.containsKey('financial_accounts') && snapshot['financial_accounts'] != null && account != null) {
        try {
          await retry(
            () => supabase
                .from('financial_accounts')
                .update(snapshot['financial_accounts'])
                .eq('name', account!)
                .eq('currency', widget.currency),
            operation: 'Rollback financial accounts',
          );
        } catch (e) {
          print('Rollback financial accounts failed: $e');
        }
      }

      if (snapshot.containsKey('products') && snapshot['products'] != null) {
        for (var product in snapshot['products'] as List<dynamic>) {
          try {
            await retry(
              () => supabase.from('products').update(product).eq('imei', product['imei']),
              operation: 'Rollback product ${product['imei']}',
            );
          } catch (e) {
            print('Rollback product ${product['imei']} failed: $e');
          }
        }
      }

      try {
        await retry(
          () => supabase.from('sale_orders').delete().eq('ticket_id', ticketId),
          operation: 'Delete sale orders',
        );
      } catch (e) {
        print('Delete sale orders failed: $e');
      }

      try {
        await retry(
          () => supabase.from('snapshots').delete().eq('ticket_id', ticketId),
          operation: 'Delete snapshot',
        );
      } catch (e) {
        print('Delete snapshot failed: $e');
      }
    } catch (e) {
      print('Error during rollback: $e');
      throw Exception('Lỗi khi rollback dữ liệu: $e');
    }
  }

  Future<bool> _verifyData(
    String ticketId,
    List<String> allImeis,
    double totalAmount,
    double depositValue,
    double codAmount,
    Map<String, dynamic> snapshotData,
    double customerPricePerImei,
    Map<String, double> transporterPricePerImei,
  ) async {
    try {
      final supabase = widget.tenantClient;

      final saleOrders = await retry(
        () => supabase.from('sale_orders').select().eq('ticket_id', ticketId),
        operation: 'Verify sale orders',
      );

      if ((saleOrders as List<dynamic>).isEmpty) {
        print('No sale orders found for ticket $ticketId');
        return false;
      }

      final productsData = await retry(
        () => supabase
            .from('products')
            .select('imei, status, saleman, sale_price, customer_price, transporter_price, profit, customer')
            .inFilter('imei', allImeis),
        operation: 'Verify products',
      );

      for (var product in productsData as List<dynamic>) {
        if (product['status'] != 'Đã bán' || 
            product['saleman'] != widget.salesman ||
            product['customer'] != widget.customer) {
          print('Product ${product['imei']} not properly updated: status=${product['status']}, saleman=${product['saleman']}, customer=${product['customer']}');
          return false;
        }

        if (account == 'Ship COD') {
          final customerPrice = double.tryParse(product['customer_price'].toString()) ?? 0;
          final transporterPrice = double.tryParse(product['transporter_price'].toString()) ?? 0;
          final expectedTransporterPrice = transporterPricePerImei[product['imei']] ?? 0;

          if ((customerPrice - customerPricePerImei).abs() > 0.01 || (transporterPrice - expectedTransporterPrice).abs() > 0.01) {
            print(
                'Product ${product['imei']} COD prices mismatch: customer_price=$customerPrice (expected $customerPricePerImei), transporter_price=$transporterPrice (expected $expectedTransporterPrice)');
            return false;
          }
        }
      }

      if (account == 'Công nợ') {
        final customerData = await retry(
          () => supabase.from('customers').select('debt_vnd, debt_cny, debt_usd').eq('name', widget.customer).single(),
          operation: 'Verify customer debt',
        );

        final debtColumn = 'debt_${widget.currency.toLowerCase()}';
        final snapshotDebt = double.tryParse(snapshotData['customers'][debtColumn].toString()) ?? 0;
        final currentDebt = double.tryParse(customerData[debtColumn].toString()) ?? 0;

        if ((currentDebt - (snapshotDebt + totalAmount)).abs() > 0.01) {
          print('Customer debt mismatch for $debtColumn: current=$currentDebt, snapshot=$snapshotDebt, total=$totalAmount');
          return false;
        }
      } else if (account == 'Ship COD') {
        final customerData = await retry(
          () => supabase.from('customers').select('debt_vnd').eq('name', widget.customer).single(),
          operation: 'Verify customer COD debt',
        );

        final snapshotDebtVnd = double.tryParse(snapshotData['customers']['debt_vnd'].toString()) ?? 0;
        final currentDebtVnd = double.tryParse(customerData['debt_vnd'].toString()) ?? 0;

        if ((currentDebtVnd - (snapshotDebtVnd + depositValue)).abs() > 0.01) {
          print('Customer VND debt mismatch for COD: current=$currentDebtVnd, snapshot=$snapshotDebtVnd, deposit=$depositValue');
          return false;
        }

        final transporterData = await retry(
          () => supabase.from('transporters').select('debt').eq('name', transporter!).single(),
          operation: 'Verify transporter debt',
        );

        final snapshotTransporterDebt = double.tryParse(snapshotData['transporters']['debt'].toString()) ?? 0;
        final currentTransporterDebt = double.tryParse(transporterData['debt'].toString()) ?? 0;

        if ((currentTransporterDebt - (snapshotTransporterDebt - codAmount)).abs() > 0.01) {
          print('Transporter debt mismatch: current=$currentTransporterDebt, snapshot=$snapshotTransporterDebt, cod=$codAmount');
          return false;
        }
      } else if (account != null) {
        final accountData = await retry(
          () => supabase.from('financial_accounts').select('balance').eq('name', account!).eq('currency', widget.currency).single(),
          operation: 'Verify account balance',
        );

        final snapshotBalance = double.tryParse(snapshotData['financial_accounts']['balance'].toString()) ?? 0;
        final currentBalance = double.tryParse(accountData['balance'].toString()) ?? 0;

        if ((currentBalance - (snapshotBalance + totalAmount)).abs() > 0.01) {
          print('Account balance mismatch: current=$currentBalance, snapshot=$snapshotBalance, total=$totalAmount');
          return false;
        }
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
      return;
    }

    if (account == 'Ship COD' && transporter == null) {
      await showDialog(
        context: scaffoldContext,
        builder: (context) => AlertDialog(
          title: const Text('Thông báo'),
          content: const Text('Vui lòng chọn đơn vị vận chuyển nội địa khi chọn Ship COD!'),
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

    final imeiMap = <String, String>{};
    List<String> allImeis = [];
    for (var item in widget.ticketItems) {
      final imeiList = (item['imei'] as String).split(',').where((e) => e.trim().isNotEmpty).toList();
      for (var imei in imeiList) {
        if (imeiMap.containsKey(imei)) {
          await showDialog(
            context: scaffoldContext,
            builder: (context) => AlertDialog(
              title: const Text('Thông báo'),
              content: Text('IMEI "$imei" xuất hiện trong nhiều sản phẩm (ID: ${imeiMap[imei]} và ${item['product_id']}). Mỗi IMEI chỉ được phép thuộc một sản phẩm!'),
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
        imeiMap[imei] = item['product_id'] as String;
      }
      allImeis.addAll(imeiList);
    }

    if (allImeis.any((imei) => imei.trim().isEmpty)) {
      await showDialog(
        context: scaffoldContext,
        builder: (context) => AlertDialog(
          title: const Text('Thông báo'),
          content: const Text('Danh sách IMEI chứa giá trị không hợp lệ (rỗng hoặc khoảng trắng)!'),
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

    final totalAmount = _calculateTotalAmount();
    final totalImeiCount = _calculateTotalImeiCount();
    final firstProductName = _getFirstProductName();
    final depositValue = double.tryParse(deposit?.replaceAll('.', '') ?? '0') ?? 0;
    final codAmount = totalAmount - depositValue;

    if (account == 'Ship COD') {
      if (depositValue > customerDebt) {
        await showDialog(
          context: scaffoldContext,
          builder: (context) => AlertDialog(
            title: const Text('Thông báo'),
            content: const Text('Tiền cọc không được lớn hơn số tiền khách dư!'),
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
    }

    final supabase = widget.tenantClient;

    if (allImeis.isNotEmpty) {
      try {
        final response = await retry(
          () => supabase.from('products').select('imei, product_id, status').inFilter('imei', allImeis).eq('status', 'Tồn kho'),
          operation: 'Validate IMEIs',
        );

        final validImeis =
            (response as List<dynamic>).where((p) => widget.ticketItems.any((item) => item['product_id'] == p['product_id'])).map((p) => p['imei'] as String).toList();

        final invalidImeis = allImeis.where((imei) => !validImeis.contains(imei)).toList();
        if (invalidImeis.isNotEmpty) {
          await showDialog(
            context: scaffoldContext,
            builder: (context) => AlertDialog(
              title: const Text('Thông báo'),
              content: Text(
                  'Các IMEI sau không tồn tại, không thuộc sản phẩm đã chọn, hoặc không ở trạng thái Tồn kho: ${invalidImeis.take(10).join(', ')}${invalidImeis.length > 10 ? '...' : ''}'),
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
      } catch (e) {
        await showDialog(
          context: scaffoldContext,
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
        return;
      }
    }

    setState(() {
      isProcessing = true;
    });

    try {
      final now = DateTime.now();
      final ticketId = generateTicketId();

      final exchangeRate = await _getExchangeRate(widget.currency);
      if (exchangeRate == 1 && widget.currency != 'VND') {
        throw Exception('Vui lòng tạo phiếu đổi tiền để cập nhật tỉ giá');
      }

      List<Map<String, dynamic>> productsDataBeforeUpdate = [];
      if (allImeis.isNotEmpty) {
        final response = await retry(
          () => supabase.from('products').select('imei, product_id, cost_price, warehouse_id, warehouse_name').inFilter('imei', allImeis),
          operation: 'Fetch products data',
        );
        productsDataBeforeUpdate = response as List<Map<String, dynamic>>;
      }

      final snapshotData = await retry(
        () => _createSnapshot(ticketId, allImeis),
        operation: 'Create snapshot',
      );

      try {
        await retry(
          () => supabase.from('snapshots').insert({
            'ticket_id': ticketId,
            'ticket_table': 'sale_orders',
            'snapshot_data': snapshotData,
            'created_at': now.toIso8601String(),
          }),
          operation: 'Insert snapshot',
        );
      } catch (e) {
        throw Exception('Failed to insert snapshot: $e');
      }

      double customerPricePerImei = 0;
      final Map<String, double> transporterPricePerImei = {};
      if (account == 'Ship COD') {
        customerPricePerImei = totalImeiCount > 0 ? depositValue / totalImeiCount : 0;
        for (var item in widget.ticketItems) {
          final imeiList = (item['imei'] as String).split(',').where((e) => e.trim().isNotEmpty).toList();
          final itemPrice = item['price'] as double;
          for (var imei in imeiList) {
            transporterPricePerImei[imei] = itemPrice - customerPricePerImei;
          }
        }
      }

      final saleOrders = widget.ticketItems.map((item) {
        final imeiList = (item['imei'] as String).split(',').where((e) => e.trim().isNotEmpty).toList();
        final imeiCount = imeiList.length;
        final productData = productsDataBeforeUpdate.where((data) => imeiList.contains(data['imei'])).toList();
        final warehouseId = productData.isNotEmpty ? productData.first['warehouse_id'] as String? ?? '' : '';
        final warehouseName = productData.isNotEmpty ? productData.first['warehouse_name'] as String? ?? '' : '';
        return {
          'ticket_id': ticketId,
          'customer': widget.customer,
          'product_id': item['product_id'],
          'product_name': item['product_name'],
          'warehouse_id': warehouseId,
          'warehouse_name': warehouseName,
          'imei': item['imei'],
          'quantity': imeiCount,
          'price': item['price'],
          'currency': item['currency'],
          'account': account,
          'note': item['note'],
          'created_at': now.toIso8601String(),
          if (account == 'Ship COD') ...{
            'customer_price': depositValue,
            'transporter_price': codAmount,
            'transporter': transporter,
          },
        };
      }).toList();

      try {
        for (var item in saleOrders) {
          final imeiList = item['imei'].toString().split(',').where((e) => e.trim().isNotEmpty).toList();
          final amount = item['price'] as double;

          final profitResponse = await retry(
            () => supabase.from('products').select('profit').inFilter('imei', imeiList),
            operation: 'Fetch products profit',
          );

          final totalProfit =
              profitResponse.map((e) => (e['profit'] as num?)?.toDouble() ?? 0.0).fold<double>(0.0, (sum, profit) => sum + profit);

          await retry(
            () => supabase.from('sale_orders').insert({
              'ticket_id': ticketId,
              'customer': item['customer'],
              'product_id': item['product_id'],
              'warehouse_id': item['warehouse_id'],
              'imei': item['imei'],
              'quantity': item['quantity'],
              'price': amount,
              'currency': item['currency'],
              'account': item['account'],
              'note': item['note'],
              'saleman': widget.salesman,
              'profit': totalProfit,
              'created_at': item['created_at'],
              if (account == 'Ship COD') ...{
                'customer_price': item['customer_price'],
                'transporter_price': item['transporter_price'],
                'transporter': item['transporter'],
              },
            }),
            operation: 'Insert sale order',
          );
        }
      } catch (e) {
        await _rollbackChanges(snapshotData, ticketId);
        throw Exception('Failed to insert sale orders: $e');
      }

      for (var item in widget.ticketItems) {
        final imeiList = (item['imei'] as String).split(',').where((e) => e.trim().isNotEmpty).toList();
        final salePriceInVND = item['currency'] == 'CNY'
            ? (item['price'] as double) * exchangeRate
            : item['currency'] == 'USD'
                ? (item['price'] as double) * exchangeRate
                : item['price'] as double;

        for (int i = 0; i < imeiList.length; i += maxBatchSize) {
          final batchImeis = imeiList.sublist(i, math.min(i + maxBatchSize, imeiList.length));
          final batchProductData = productsDataBeforeUpdate.where((data) => batchImeis.contains(data['imei'])).toList();
          final costPrice = batchProductData.isNotEmpty ? (double.tryParse(batchProductData.first['cost_price'].toString()) ?? 0) : 0;
          try {
            await retry(
              () => supabase.from('products').update({
                'status': 'Đã bán',
                'sale_date': now.toIso8601String(),
                'saleman': widget.salesman,
                'sale_price': salePriceInVND,
                'profit': salePriceInVND - costPrice,
                'customer': widget.customer, // Add customer name to products table
                if (account == 'Ship COD') ...{
                  'customer_price': customerPricePerImei,
                  'transporter_price': transporterPricePerImei[batchImeis.first] ?? 0,
                  'transporter': transporter,
                },
              }).inFilter('imei', batchImeis),
              operation: 'Update products batch $i',
            );
          } catch (e) {
            await _rollbackChanges(snapshotData, ticketId);
            throw Exception('Failed to update products batch $i: $e');
          }
        }
      }

      if (account == 'Công nợ') {
        try {
          final currentCustomer = await retry(
            () => supabase.from('customers').select('debt_vnd, debt_cny, debt_usd').eq('name', widget.customer).single(),
            operation: 'Fetch current customer debt',
          );
          String debtColumn;
          if (widget.currency == 'VND') {
            debtColumn = 'debt_vnd';
          } else if (widget.currency == 'CNY') {
            debtColumn = 'debt_cny';
          } else if (widget.currency == 'USD') {
            debtColumn = 'debt_usd';
          } else {
            throw Exception('Loại tiền tệ không được hỗ trợ: ${widget.currency}');
          }
          final currentDebt = double.tryParse(currentCustomer[debtColumn].toString()) ?? 0;
          final updatedDebt = currentDebt + totalAmount;
          await retry(
            () => supabase.from('customers').update({debtColumn: updatedDebt}).eq('name', widget.customer),
            operation: 'Update customer debt',
          );
        } catch (e) {
          await _rollbackChanges(snapshotData, ticketId);
          throw Exception('Failed to update customer debt: $e');
        }
      } else if (account == 'Ship COD') {
        try {
          final currentCustomer = await retry(
            () => supabase.from('customers').select('debt_vnd').eq('name', widget.customer).single(),
            operation: 'Fetch current customer debt for Ship COD',
          );
          final currentCustomerDebt = double.tryParse(currentCustomer['debt_vnd'].toString()) ?? 0;
          final updatedCustomerDebt = currentCustomerDebt + depositValue;
          await retry(
            () => supabase.from('customers').update({'debt_vnd': updatedCustomerDebt}).eq('name', widget.customer),
            operation: 'Update customer debt for Ship COD',
          );

          final currentTransporter = await supabase.from('transporters').select('debt').eq('name', transporter!).single();
          final currentTransporterDebt = double.tryParse(currentTransporter['debt'].toString()) ?? 0;
          final updatedTransporterDebt = currentTransporterDebt - codAmount;

          await supabase.from('transporters').update({'debt': updatedTransporterDebt}).eq('name', transporter!);
        } catch (e) {
          await _rollbackChanges(snapshotData, ticketId);
          throw Exception('Failed to update financial data for Ship COD: $e');
        }
      } else {
        try {
          final selectedAccount = accounts.firstWhere((acc) => acc['name'] == account);
          final currentBalance = double.tryParse(selectedAccount['balance'].toString()) ?? 0;
          final updatedBalance = currentBalance + totalAmount;
          await retry(
            () => supabase
                .from('financial_accounts')
                .update({'balance': updatedBalance})
                .eq('name', account!)
                .eq('currency', widget.currency),
            operation: 'Update financial account balance',
          );
        } catch (e) {
          await _rollbackChanges(snapshotData, ticketId);
          throw Exception('Failed to update financial account: $e');
        }
      }

      final isDataValid = await _verifyData(
        ticketId,
        allImeis,
        totalAmount,
        depositValue,
        codAmount,
        snapshotData,
        customerPricePerImei,
        transporterPricePerImei,
      );
      if (!isDataValid) {
        await _rollbackChanges(snapshotData, ticketId);
        throw Exception('Dữ liệu không khớp sau khi cập nhật. Đã rollback thay đổi.');
      }

      await NotificationService.showNotification(
        138,
        "Phiếu Bán Hàng Đã Tạo",
        "Đã bán hàng \"$firstProductName\" số lượng ${formatNumberLocal(totalImeiCount)} chiếc",
        'sale_created',
      );

      if (mounted) {
        setState(() {
          isProcessing = false;
        });
        ScaffoldMessenger.of(scaffoldContext).showSnackBar(
          SnackBar(
            content: Text(
              'Đã bán hàng "$firstProductName" số lượng ${formatNumberLocal(totalImeiCount)} chiếc',
              style: const TextStyle(color: Colors.white),
            ),
            backgroundColor: Colors.black,
            behavior: SnackBarBehavior.floating,
            margin: const EdgeInsets.all(8),
            duration: const Duration(seconds: 3),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
          ),
        );
        Navigator.pop(context);
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          isProcessing = false;
        });
        await showDialog(
          context: scaffoldContext,
          builder: (context) => AlertDialog(
            title: const Text('Thông báo'),
            content: Text('Lỗi khi tạo phiếu bán hàng: $e'),
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

  Widget wrapField(Widget child, {bool isImeiField = false}) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      margin: const EdgeInsets.symmetric(vertical: 4),
      height: isImeiField ? 80 : 40,
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
    final totalImeiCount = _calculateTotalImeiCount();
    final firstProductName = _getFirstProductName();
    final depositValue = double.tryParse(deposit?.replaceAll('.', '') ?? '0') ?? 0;
    codAmount = totalAmount - depositValue;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Danh sách sản phẩm', style: TextStyle(color: Colors.white)),
        backgroundColor: Colors.black,
        iconTheme: const IconThemeData(color: Colors.white),
      ),
      body: Stack(
        children: [
          Column(
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
                            final imeiCount = (item['imei'] as String).split(',').where((e) => e.trim().isNotEmpty).length;
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
                                          Text('Số IMEI: $imeiCount'),
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
                                                builder: (context) => SaleForm(
                                                  tenantClient: widget.tenantClient,
                                                  initialCustomer: widget.customer,
                                                  initialProductId: item['product_id'] as String,
                                                  initialProductName: item['product_name'] as String,
                                                  initialPrice: (item['price'] as double).toString(),
                                                  initialImei: item['imei'] as String,
                                                  initialNote: item['note'] as String?,
                                                  initialSalesman: widget.salesman,
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
                        'Tổng tiền: ${formatNumberLocal(totalAmount)} ${widget.currency}',
                        style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                      ),
                      const SizedBox(height: 8),
                      Text('Nhân viên bán: ${widget.salesman}'),
                      const SizedBox(height: 8),
                      Text('Khách hàng: ${widget.customer}'),
                      const SizedBox(height: 8),
                      wrapField(
                        DropdownButtonFormField<String>(
                          value: account,
                          items: accountNames.map((e) => DropdownMenuItem(value: e, child: Text(e))).toList(),
                          hint: const Text('Tài khoản'),
                          onChanged: (val) {
                            setState(() {
                              account = val;
                              transporter = null;
                              deposit = null;
                              depositController.text = '';
                              codAmount = totalAmount;
                              depositError = null;
                            });
                          },
                          decoration: const InputDecoration(
                            border: InputBorder.none,
                            isDense: true,
                          ),
                        ),
                      ),
                      if (account == 'Ship COD') ...[
                        Row(
                          children: [
                            Expanded(
                              child: wrapField(
                                Row(
                                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                  children: [
                                    const Text(
                                      'Khách dư',
                                      style: TextStyle(fontSize: 14, color: Colors.black54),
                                    ),
                                    Text(
                                      formatNumberLocal(customerDebt),
                                      style: const TextStyle(fontSize: 14, color: Colors.black),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: wrapField(
                                TextFormField(
                                  controller: depositController,
                                  keyboardType: TextInputType.number,
                                  onChanged: (val) {
                                    final cleanedValue = val.replaceAll(RegExp(r'[^0-9]'), '');
                                    if (cleanedValue.isNotEmpty) {
                                      final parsedValue = double.tryParse(cleanedValue);
                                      if (parsedValue != null) {
                                        final formattedValue = numberFormat.format(parsedValue);
                                        depositController.value = TextEditingValue(
                                          text: formattedValue,
                                          selection: TextSelection.collapsed(offset: formattedValue.length),
                                        );
                                        setState(() {
                                          deposit = cleanedValue;
                                          final depositValue = double.tryParse(deposit!) ?? 0;
                                          if (depositValue > customerDebt) {
                                            depositError = 'Tiền cọc không được lớn hơn khách dư!';
                                          } else if (depositValue < 0) {
                                            depositError = 'Tiền cọc không được nhỏ hơn 0!';
                                          } else {
                                            depositError = null;
                                          }
                                          codAmount = totalAmount - depositValue;
                                        });
                                      }
                                    } else {
                                      setState(() {
                                        deposit = null;
                                        depositError = null;
                                        codAmount = totalAmount;
                                      });
                                    }
                                  },
                                  decoration: InputDecoration(
                                    labelText: 'Tiền cọc',
                                    border: InputBorder.none,
                                    isDense: true,
                                    errorText: depositError,
                                  ),
                                ),
                              ),
                            ),
                          ],
                        ),
                        Row(
                          children: [
                            Expanded(
                              child: wrapField(
                                Row(
                                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                  children: [
                                    const Text(
                                      'Tiền COD',
                                      style: TextStyle(fontSize: 14, color: Colors.black54),
                                    ),
                                    Text(
                                      formatNumberLocal(codAmount),
                                      style: const TextStyle(fontSize: 14, color: Colors.black),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: wrapField(
                                DropdownButtonFormField<String>(
                                  value: transporter,
                                  items: localTransporters.map((e) => DropdownMenuItem(value: e, child: Text(e))).toList(),
                                  hint: const Text('Đơn vị vận chuyển'),
                                  onChanged: (val) => setState(() => transporter = val),
                                  decoration: const InputDecoration(
                                    border: InputBorder.none,
                                    isDense: true,
                                  ),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ],
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
                              builder: (context) => SaleForm(
                                tenantClient: widget.tenantClient,
                                initialCustomer: widget.customer,
                                initialSalesman: widget.salesman,
                                ticketItems: widget.ticketItems,
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
          if (isProcessing)
            Container(
              color: Colors.black.withOpacity(0.5),
              child: const Center(
                child: CircularProgressIndicator(
                  color: Colors.white,
                ),
              ),
            ),
        ],
      ),
    );
  }
}