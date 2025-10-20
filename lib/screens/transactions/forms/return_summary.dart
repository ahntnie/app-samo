import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:intl/intl.dart';
import '../../notification_service.dart';
import 'return_form.dart';
import 'dart:math' as math;

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
      final supplierData = await supabase
          .from('suppliers')
          .select()
          .eq('name', widget.supplier)
          .single();
      snapshotData['suppliers'] = supplierData;

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
          'supplier': widget.supplier,
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

    debugPrint('Validating supplier: ${widget.supplier}');
    final supplierResponse = await supabase
        .from('suppliers')
        .select('name')
        .eq('name', widget.supplier)
        .maybeSingle();
    if (supplierResponse == null) {
      debugPrint('Invalid supplier: ${widget.supplier}');
      return false;
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

  Future<void> _rollbackChanges(Map<String, dynamic> snapshot, String ticketId) async {
    final supabase = widget.tenantClient;
    
    try {
      // Rollback suppliers
      if (snapshot['suppliers'] != null) {
        await supabase
          .from('suppliers')
          .update(snapshot['suppliers'])
          .eq('name', widget.supplier);
      }

      // Rollback financial accounts
      if (snapshot['financial_accounts'] != null && account != null) {
        await supabase
          .from('financial_accounts')
          .update(snapshot['financial_accounts'])
          .eq('name', account!)
          .inFilter('currency', widget.ticketItems.map((e) => e['currency']).toList());
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

      // Delete created return orders
      await supabase
        .from('return_orders')
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
      // Verify supplier data
      final supplierData = await supabase
          .from('suppliers')
          .select()
          .eq('name', widget.supplier)
          .single();
      
      // Verify products data
      final productsData = await supabase
          .from('products')
          .select('status')
          .inFilter('imei', imeiList);
      
      // Verify return orders
      final returnOrders = await supabase
          .from('return_orders')
          .select()
          .eq('ticket_id', ticketId);

      // Verify all IMEIs are marked as returned
      for (var product in productsData) {
        if (product['status'] != 'Đã trả ncc') {
          return false;
        }
      }

      // Verify all return orders are created
      if (returnOrders.length != widget.ticketItems.length) {
        return false;
      }

      // Verify financial account if used
      if (account != null && account != 'Công nợ') {
        final accountData = await supabase
            .from('financial_accounts')
            .select()
            .eq('name', account!)
            .inFilter('currency', widget.ticketItems.map((e) => e['currency']).toList())
            .single();
      }

      return true;
    } catch (e) {
      print('Error during data verification: $e');
      return false;
    }
  }

  Future<void> _processTicket() async {
    if (isProcessing) return;

    setState(() {
      isProcessing = true;
      errorMessage = null;
    });

    final ticketId = DateTime.now().millisecondsSinceEpoch.toString();
    final allImeis = widget.ticketItems
        .expand((item) => (item['imei'] as String)
            .split(',')
            .where((e) => e.trim().isNotEmpty))
        .toList();

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
      // Existing processing logic here
      // ... (keep your current _processTicket implementation)

      // After all updates, verify the data
      final isDataValid = await _verifyData(ticketId, allImeis);
      if (!isDataValid) {
        // If data verification fails, rollback changes
        await _rollbackChanges(snapshot, ticketId);
        throw Exception('Dữ liệu không khớp sau khi cập nhật. Đã rollback thay đổi.');
      }

      // If everything is successful, show success message
      if (mounted) {
        Navigator.of(context).pop(true);
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
          'supplier': widget.supplier,
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
        final currentSupplier = await supabase
            .from('suppliers')
            .select('debt_vnd, debt_cny, debt_usd')
            .eq('name', widget.supplier)
            .single();

        for (var currency in currencies) {
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

          final totalAmount = widget.ticketItems
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
              .eq('name', widget.supplier);
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
        await showDialog(
          context: scaffoldContext,
          builder: (context) => AlertDialog(
            title: const Text('Thông báo'),
            content: Text('Lỗi tạo phiếu trả hàng: $e'),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('Đóng'),
              ),
            ],
          ),
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