import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import '../../notification_service.dart';

class ThousandsFormatterLocal extends TextInputFormatter {
  @override
  TextEditingValue formatEditUpdate(
    TextEditingValue oldValue,
    TextEditingValue newValue,
  ) {
    String newText = newValue.text.replaceAll('.', '').replaceAll(',', '');
    if (newText.isEmpty) return newValue;
    final intValue = int.tryParse(newText);
    if (intValue == null) return newValue;
    final formatted = NumberFormat(
      '#,###',
      'vi_VN',
    ).format(intValue).replaceAll(',', '.');
    return TextEditingValue(
      text: formatted,
      selection: TextSelection.collapsed(offset: formatted.length),
    );
  }
}

String formatNumberLocal(num value) {
  return NumberFormat('#,###', 'vi_VN').format(value).replaceAll(',', '.');
}

class ExchangeForm extends StatefulWidget {
  final SupabaseClient tenantClient;

  const ExchangeForm({super.key, required this.tenantClient});

  @override
  State<ExchangeForm> createState() => _ExchangeFormState();
}

class _ExchangeFormState extends State<ExchangeForm> {
  double amount = 0;
  String? fromAccountName;
  String? toAccountName;
  double rate = 1;
  double receiveAmount = 0;
  String? note;
  List<Map<String, dynamic>> accounts = [];

  final TextEditingController amountController = TextEditingController();

  @override
  void initState() {
    super.initState();
    _fetchAccounts();
    amountController.text = ''; // Để trống ô nhập số tiền đổi
  }

  @override
  void dispose() {
    amountController.dispose();
    super.dispose();
  }

  Future<void> _fetchAccounts() async {
    try {
      final response =
          await widget.tenantClient.from('financial_accounts').select();
      setState(() {
        accounts = response.map((e) => Map<String, dynamic>.from(e)).toList();
      });
    } catch (e) {
      _showErrorDialog('Lỗi khi tải danh sách tài khoản: $e');
    }
  }

  Map<String, dynamic>? _getAccount(String name) {
    return accounts.firstWhere((acc) => acc['name'] == name, orElse: () => {});
  }

  void calculateReceiveAmount() {
    setState(() {
      receiveAmount = rate > 0 ? amount / rate : 0;
    });
  }

  Future<void> checkBalance() async {
    if (fromAccountName == null || amount <= 0) return;

    final fromAcc = _getAccount(fromAccountName!);
    if (fromAcc == null || fromAcc.isEmpty) {
      _showErrorDialog('Tài khoản thanh toán không tồn tại');
      return;
    }

    final balance = fromAcc['balance'] ?? 0;
    if (balance < amount) {
      _showErrorDialog('Tài khoản không đủ tiền');
    }
  }

  Future<Map<String, dynamic>> _createSnapshot(String ticketId) async {
    final snapshotData = <String, dynamic>{};
    final financialAccounts = <String, dynamic>{};

    if (fromAccountName != null) {
      final fromAccountData =
          await widget.tenantClient
              .from('financial_accounts')
              .select()
              .eq('name', fromAccountName!)
              .single();
      financialAccounts['from_account'] = fromAccountData;
    }

    if (toAccountName != null) {
      final toAccountData =
          await widget.tenantClient
              .from('financial_accounts')
              .select()
              .eq('name', toAccountName!)
              .single();
      financialAccounts['to_account'] = toAccountData;
    }

    snapshotData['financial_accounts'] = financialAccounts;
    return snapshotData;
  }

  void showConfirm() {
    if (fromAccountName == null || toAccountName == null) {
      _showErrorDialog('Tài khoản không hợp lệ');
      return;
    }

    final fromAcc = _getAccount(fromAccountName!);
    final toAcc = _getAccount(toAccountName!);

    if (fromAcc == null || fromAcc.isEmpty || toAcc == null || toAcc.isEmpty) {
      _showErrorDialog('Tài khoản không hợp lệ');
      return;
    }

    final fromCurrency = fromAcc['currency'] ?? '';
    final toCurrency = toAcc['currency'] ?? '';
    final fromBalance = fromAcc['balance'] ?? 0;

    if (fromBalance < amount) {
      _showErrorDialog('Tài khoản không đủ tiền');
      return;
    }

    Map<String, dynamic> rateData = {};
    if (fromCurrency == 'VND' && toCurrency == 'CNY') {
      rateData = {'rate_vnd_cny': rate};
    } else if (fromCurrency == 'VND' && toCurrency == 'USD') {
      rateData = {'rate_vnd_usd': rate};
    } else {
      _showErrorDialog('Chỉ hỗ trợ đổi từ VND sang CNY hoặc USD');
      return;
    }

    showDialog(
      context: context,
      builder:
          (_) => AlertDialog(
            title: const Text('Xác nhận đổi tiền'),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Số tiền đổi: ${formatNumberLocal(amount)}'),
                Text(
                  'Từ tài khoản: ${fromAcc['name']} (${fromAcc['currency']})',
                ),
                Text('Sang tài khoản: ${toAcc['name']} (${toAcc['currency']})'),
                Text('Tỉ giá: ${rate.toStringAsFixed(2)}'),
                Text('Nhận được: ${formatNumberLocal(receiveAmount)}'),
                Text('Ghi chú: ${note ?? "Không có"}'),
              ],
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('Sửa'),
              ),
              ElevatedButton(
                onPressed: () async {
                  Navigator.pop(context);
                  await _createExchangeTicket(
                    fromAcc,
                    toAcc,
                    fromBalance,
                    rateData,
                  );
                },
                child: const Text('Tạo phiếu'),
              ),
            ],
          ),
    );
  }

  Future<void> _createExchangeTicket(
    Map<String, dynamic> fromAcc,
    Map<String, dynamic> toAcc,
    num fromBalance,
    Map<String, dynamic> rateData,
  ) async {
    try {
      if (fromAccountName == null || toAccountName == null) {
        _showErrorDialog('Tài khoản không hợp lệ');
        return;
      }

      final fromAccountData =
          await widget.tenantClient
              .from('financial_accounts')
              .select()
              .eq('name', fromAccountName!)
              .single();

      final toAccountData =
          await widget.tenantClient
              .from('financial_accounts')
              .select()
              .eq('name', toAccountName!)
              .single();

      final financialOrderResponse =
          await widget.tenantClient
              .from('financial_orders')
              .insert({
                'type': 'exchange',
                'from_amount': amount,
                'from_currency': fromAcc['currency'] ?? '',
                'to_amount': receiveAmount,
                'to_currency': toAcc['currency'] ?? '',
                'from_account': fromAccountName,
                'to_account': toAccountName,
                'note': note,
                'created_at': DateTime.now().toIso8601String(),
                ...rateData,
              })
              .select()
              .single();

      final ticketId = financialOrderResponse['id'].toString();

      final snapshotData = await _createSnapshot(ticketId);
      await widget.tenantClient.from('snapshots').insert({
        'ticket_id': ticketId,
        'ticket_table': 'financial_orders',
        'snapshot_data': snapshotData,
        'created_at': DateTime.now().toIso8601String(),
      });

      await NotificationService.showNotification(
        129, // Unique ID for this type of notification
        "Phiếu Đổi Tiền Đã Tạo",
        "Đã tạo phiếu đổi tiền với số tiền ${formatNumberLocal(amount)} ${fromAcc['currency']}",
        'exchange_created',
      );

      await widget.tenantClient
          .from('financial_accounts')
          .update({'balance': fromBalance - amount})
          .eq('name', fromAccountName!);

      final toBalance = toAcc['balance'] ?? 0;
      await widget.tenantClient
          .from('financial_accounts')
          .update({'balance': toBalance + receiveAmount})
          .eq('name', toAccountName!);

      await showDialog(
        context: context,
        builder:
            (context) => AlertDialog(
              title: const Text('Thành công'),
              content: const Text('Tạo phiếu thành công'),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: const Text('Đóng'),
                ),
              ],
            ),
      );

      setState(() {
        amount = 0;
        amountController.text = '';
        fromAccountName = null;
        toAccountName = null;
        rate = 1;
        receiveAmount = 0;
        note = null;
        _fetchAccounts();
      });
    } catch (e) {
      _showErrorDialog('Lỗi khi tạo phiếu đổi tiền: $e');
    }
  }

  void _showErrorDialog(String message) {
    showDialog(
      context: context,
      builder:
          (context) => AlertDialog(
            title: const Text('Thông báo'),
            content: Text(message),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('Đóng'),
              ),
            ],
          ),
    );
  }

  Widget wrapField(Widget child) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      margin: const EdgeInsets.symmetric(vertical: 6),
      decoration: BoxDecoration(
        color: Colors.grey.shade200,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: Colors.grey.shade300),
      ),
      child: child,
    );
  }

  @override
  Widget build(BuildContext context) {
    String? fromCurrency;
    if (fromAccountName != null) {
      final account = _getAccount(fromAccountName!);
      fromCurrency = account != null ? account['currency'] as String? : null;
    }

    final filteredToAccounts =
        accounts.where((acc) {
          final accCurrency = acc['currency'];
          return fromCurrency == null || accCurrency != fromCurrency;
        }).toList();

    return GestureDetector(
      onHorizontalDragEnd: (details) {
        if (details.primaryVelocity != null && details.primaryVelocity! > 0) {
          Navigator.pop(context);
        }
      },
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Đổi tiền', style: TextStyle(color: Colors.white)),
          backgroundColor: Colors.black,
          iconTheme: const IconThemeData(color: Colors.white),
        ),
        body:
            accounts.isEmpty
                ? const Center(child: CircularProgressIndicator())
                : Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    children: [
                      wrapField(
                        DropdownButtonFormField<String>(
                          value: fromAccountName,
                          decoration: const InputDecoration(
                            labelText: 'Tài khoản thanh toán',
                            border: InputBorder.none,
                            isDense: true,
                          ),
                          items:
                              accounts
                                  .map(
                                    (e) => DropdownMenuItem<String>(
                                      value: e['name'] as String,
                                      child: Text(
                                        '${e['name']} (${e['currency']})',
                                      ),
                                    ),
                                  )
                                  .toList(),
                          onChanged:
                              (String? val) => setState(() {
                                fromAccountName = val;
                                toAccountName = null;
                                calculateReceiveAmount();
                                checkBalance();
                              }),
                        ),
                      ),
                      wrapField(
                        DropdownButtonFormField<String>(
                          value: toAccountName,
                          decoration: const InputDecoration(
                            labelText: 'Tài khoản nhận',
                            border: InputBorder.none,
                            isDense: true,
                          ),
                          items:
                              filteredToAccounts
                                  .map(
                                    (e) => DropdownMenuItem<String>(
                                      value: e['name'] as String,
                                      child: Text(
                                        '${e['name']} (${e['currency']})',
                                      ),
                                    ),
                                  )
                                  .toList(),
                          onChanged:
                              (String? val) =>
                                  setState(() => toAccountName = val),
                        ),
                      ),
                      wrapField(
                        TextFormField(
                          controller: amountController,
                          keyboardType: TextInputType.number,
                          inputFormatters: [ThousandsFormatterLocal()],
                          decoration: const InputDecoration(
                            labelText: 'Số tiền đổi',
                            border: InputBorder.none,
                            isDense: true,
                          ),
                          onChanged: (val) {
                            final raw = val.replaceAll('.', '');
                            amount = double.tryParse(raw) ?? 0;
                            calculateReceiveAmount();
                            checkBalance();
                          },
                        ),
                      ),
                      wrapField(
                        TextFormField(
                          keyboardType: const TextInputType.numberWithOptions(
                            decimal: true,
                          ),
                          decoration: const InputDecoration(
                            labelText: 'Tỉ giá',
                            border: InputBorder.none,
                            isDense: true,
                          ),
                          onChanged: (val) {
                            rate = double.tryParse(val) ?? 1;
                            calculateReceiveAmount();
                          },
                        ),
                      ),
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 8),
                        child: Text(
                          'Số tiền nhận được: ${formatNumberLocal(receiveAmount)}',
                        ),
                      ),
                      wrapField(
                        TextFormField(
                          decoration: const InputDecoration(
                            labelText: 'Ghi chú',
                            border: InputBorder.none,
                            isDense: true,
                          ),
                          onChanged: (val) => setState(() => note = val),
                        ),
                      ),
                      const SizedBox(height: 20),
                      ElevatedButton(
                        onPressed: showConfirm,
                        style: ElevatedButton.styleFrom(
                          backgroundColor: Colors.blue,
                          foregroundColor: Colors.white,
                          padding: const EdgeInsets.symmetric(
                            vertical: 14,
                            horizontal: 24,
                          ),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12),
                          ),
                        ),
                        child: const Text('Xác nhận'),
                      ),
                    ],
                  ),
                ),
      ),
    );
  }
}