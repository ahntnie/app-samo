import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../../notification_service.dart';
import 'fix_send_form.dart';
import 'dart:math' as math;
import 'package:intl/intl.dart';

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

class FixSendSummary extends StatefulWidget {
  final SupabaseClient tenantClient;
  final List<Map<String, dynamic>> ticketItems;

  const FixSendSummary({
    super.key,
    required this.tenantClient,
    required this.ticketItems,
  });

  @override
  State<FixSendSummary> createState() => _FixSendSummaryState();
}

class _FixSendSummaryState extends State<FixSendSummary> {
  bool isLoading = false;
  bool isProcessing = false;
  String? errorMessage;
  final NumberFormat numberFormat = NumberFormat.decimalPattern('vi_VN');

  @override
  void initState() {
    super.initState();
  }

  String generateTicketId() {
    final now = DateTime.now();
    final dateFormat = DateFormat('yyyyMMdd-HHmmss');
    final randomNum = (100 + (DateTime.now().millisecondsSinceEpoch % 900)).toString();
    return 'FIXSEND-${dateFormat.format(now)}-$randomNum';
  }

  String formatNumberLocal(num value) {
    return NumberFormat('#,###', 'vi_VN').format(value).replaceAll(',', '.');
  }

  Future<Map<String, dynamic>> _createSnapshot(String ticketId, List<String> imeiList) async {
    final supabase = widget.tenantClient;
    final snapshotData = <String, dynamic>{};

    try {
      if (imeiList.isNotEmpty) {
        List<Map<String, dynamic>> productsData = [];
        for (int i = 0; i < imeiList.length; i += maxBatchSize) {
          final batchImeis = imeiList.sublist(i, math.min(i + maxBatchSize, imeiList.length));
          final response = await retry(
            () => supabase.from('products').select('imei, product_id, status, send_fix_date').inFilter('imei', batchImeis),
            operation: 'Fetch products snapshot batch ${i ~/ maxBatchSize + 1}',
          );
          productsData.addAll(response.cast<Map<String, dynamic>>());
        }
        snapshotData['products'] = productsData;
      }

      snapshotData['fix_send_orders'] = widget.ticketItems.map((item) {
        return {
          'ticket_id': ticketId,
          'fixer': item['fixer'],
          'product_id': item['product_id'],
          'product_name': item['product_name'],
          'imei': item['imei'],
          'quantity': item['quantity'],
          'note': item['note'],
        };
      }).toList();

      return snapshotData;
    } catch (e) {
      throw Exception('Failed to create snapshot: $e');
    }
  }

  Future<void> createTicket(BuildContext scaffoldContext) async {
    if (isProcessing) return;

    if (widget.ticketItems.isEmpty) {
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

    if (widget.ticketItems.length > maxTicketItems) {
      if (mounted) {
        showDialog(
          context: scaffoldContext,
          builder: (context) => AlertDialog(
            title: const Text('Thông báo'),
            content: Text('Số lượng mục gửi sửa (${widget.ticketItems.length}) vượt quá $maxTicketItems. Vui lòng giảm số mục để tối ưu hiệu suất.'),
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

    List<String> allImeis = [];
    for (var item in widget.ticketItems) {
      final imeiList = (item['imei'] as String).split(',').where((e) => e.trim().isNotEmpty).toList();
      allImeis.addAll(imeiList);
    }

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

    setState(() {
      isProcessing = true;
    });

    try {
      final supabase = widget.tenantClient;
      final now = DateTime.now();
      final ticketId = generateTicketId();

      // Validate IMEIs
      List<String> validImeis = [];
      for (int i = 0; i < allImeis.length; i += maxBatchSize) {
        final batchImeis = allImeis.sublist(i, math.min(i + maxBatchSize, allImeis.length));
        final response = await retry(
          () => supabase
              .from('products')
              .select('imei, product_id')
              .inFilter('imei', batchImeis),
          operation: 'Validate IMEIs batch ${i ~/ maxBatchSize + 1}',
        );

        validImeis.addAll(
          response
              .where((p) => widget.ticketItems.any((item) => p['product_id'] == item['product_id']))
              .map((p) => p['imei'] as String),
        );
      }

      final invalidImeis = allImeis.where((imei) => !validImeis.contains(imei)).toList();
      if (invalidImeis.isNotEmpty) {
        throw Exception('Các IMEI sau không hợp lệ: ${invalidImeis.take(10).join(', ')}${invalidImeis.length > 10 ? '...' : ''}');
      }

      // Create snapshot
      final snapshotData = await retry(
        () => _createSnapshot(ticketId, allImeis),
        operation: 'Create snapshot',
      );

      // Insert snapshot
      await retry(
        () => supabase.from('snapshots').insert({
          'ticket_id': ticketId,
          'ticket_table': 'fix_send_orders',
          'snapshot_data': snapshotData,
          'created_at': now.toIso8601String(),
        }),
        operation: 'Insert snapshot',
      );

      // Prepare and insert fix send orders
      final fixSendOrders = widget.ticketItems.map((item) {
        return {
          'ticket_id': ticketId,
          'fixer': item['fixer'],
          'product_id': item['product_id'],
          'imei': item['imei'],
          'quantity': item['quantity'],
          'note': item['note'],
          'created_at': now.toIso8601String(),
          'iscancelled': false,
        };
      }).toList();

      await retry(
        () => supabase.from('fix_send_orders').insert(fixSendOrders),
        operation: 'Insert fix_send_orders',
      );

      // Update products
      for (var item in widget.ticketItems) {
        final imeiList = (item['imei'] as String).split(',').where((e) => e.trim().isNotEmpty).toList();
        for (int i = 0; i < imeiList.length; i += maxBatchSize) {
          final batchImeis = imeiList.sublist(i, math.min(i + maxBatchSize, imeiList.length));
          await retry(
            () => supabase.from('products').update({
              'status': 'Đang sửa',
              'fix_unit': item['fixer'],
              'send_fix_date': now.toIso8601String(),
            }).inFilter('imei', batchImeis),
            operation: 'Update products batch ${i ~/ maxBatchSize + 1}',
          );
        }
      }

      await NotificationService.showNotification(
        131,
        "Phiếu Gửi Sửa Đã Tạo",
        "Đã tạo phiếu gửi sửa với ${formatNumberLocal(widget.ticketItems.length)} mục",
        'fix_send_created',
      );

      if (mounted) {
        setState(() {
          isProcessing = false;
        });
        await showDialog(
          context: scaffoldContext,
          builder: (context) => AlertDialog(
            title: const Text('Thông báo'),
            content: const Text('Đã tạo phiếu gửi sửa thành công'),
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
      if (mounted) {
        setState(() {
          isProcessing = false;
        });
        await showDialog(
          context: scaffoldContext,
          builder: (context) => AlertDialog(
            title: const Text('Thông báo'),
            content: Text('Lỗi khi tạo phiếu gửi sửa: $e'),
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
      height: isImeiField ? 80 : 48,
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
                onPressed: () => setState(() {
                  isLoading = true;
                  errorMessage = null;
                }),
                child: const Text('Thử lại'),
              ),
            ],
          ),
        ),
      );
    }

    return Scaffold(
      appBar: AppBar(
        title: const Text('Danh sách sản phẩm gửi sửa', style: TextStyle(color: Colors.white)),
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
                      itemCount: widget.ticketItems.length,
                      itemBuilder: (context, index) {
                        final item = widget.ticketItems[index];
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
                                      Text('Đơn vị sửa: ${item['fixer']}'),
                                      Text('Sản phẩm: ${item['product_name']}'),
                                      Text('Số lượng IMEI: ${formatNumberLocal(item['quantity'])}'),
                                      if (imeiList.length <= displayImeiLimit) ...[
                                        Text('IMEI:'),
                                        ...imeiList.map((imei) => Text('- $imei')),
                                      ] else
                                        Text('IMEI: ${imeiList.take(displayImeiLimit).join(', ')}... và ${formatNumberLocal(imeiList.length - displayImeiLimit)} IMEI khác'),
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
                                            builder: (context) => FixSendForm(
                                              tenantClient: widget.tenantClient,
                                              initialFixer: item['fixer'],
                                              initialProductId: item['product_id'],
                                              initialImei: item['imei'],
                                              initialNote: item['note'],
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
                                        if (mounted) {
                                          setState(() {
                                            widget.ticketItems.removeAt(index);
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
                          builder: (context) => FixSendForm(
                            tenantClient: widget.tenantClient,
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
    );
  }
}