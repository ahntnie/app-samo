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

class CostForm extends StatefulWidget {
  final SupabaseClient tenantClient;

  const CostForm({super.key, required this.tenantClient});

  @override
  State<CostForm> createState() => _CostFormState();
}

class _CostFormState extends State<CostForm> {
  double? amount;
  String? currency;
  String? account;
  String? note;

  List<String> currencies = [];
  List<String> accounts = [];

  final TextEditingController amountController = TextEditingController();

  @override
  void initState() {
    super.initState();
    loadCurrencies();
    amountController.text = amount?.toString() ?? '';
  }

  @override
  void dispose() {
    amountController.dispose();
    super.dispose();
  }

  Future<void> loadCurrencies() async {
    final response = await widget.tenantClient
        .from('financial_accounts')
        .select('currency')
        .neq('currency', '');
    final uniqueCurrencies =
        response
            .map((e) => e['currency'] as String?)
            .where((e) => e != null && e.isNotEmpty)
            .cast<String>()
            .toSet()
            .toList();

    setState(() {
      currencies = uniqueCurrencies;
      currency = currencies.isNotEmpty ? currencies.first : null;
      fetchAccounts();
    });
  }

  Future<void> fetchAccounts() async {
    if (currency == null) {
      setState(() {
        accounts = [];
        account = null;
      });
      return;
    }

    final res = await widget.tenantClient
        .from('financial_accounts')
        .select('name')
        .eq('currency', currency!);

    setState(() {
      accounts =
          res
              .map((e) => e['name'] as String?)
              .where((e) => e != null)
              .cast<String>()
              .toList();
      account = accounts.isNotEmpty ? accounts.first : null;
    });
  }

  Future<Map<String, dynamic>> _createSnapshot(String ticketId) async {
    final snapshotData = <String, dynamic>{};

    final accountData =
        await widget.tenantClient
            .from('financial_accounts')
            .select()
            .eq('name', account!)
            .eq('currency', currency!)
            .single();
    snapshotData['financial_accounts'] = accountData;

    return snapshotData;
  }

  Future<void> showConfirm() async {
    if (amount == null || amount! <= 0 || currency == null || account == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Vui lòng nhập đầy đủ thông tin hợp lệ')),
      );
      return;
    }

    final acc =
        await widget.tenantClient
            .from('financial_accounts')
            .select('balance')
            .eq('name', account!)
            .eq('currency', currency!)
            .maybeSingle();

    if (acc == null) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Tài khoản không tồn tại')));
      return;
    }

    final balance = acc['balance'] ?? 0;
    if (balance < amount!) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Tài khoản không đủ tiền')));
      return;
    }

    showDialog(
      context: context,
      builder:
          (_) => AlertDialog(
            title: const Text('Xác nhận chi phí'),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Số tiền: ${formatNumberLocal(amount!)} $currency'),
                Text('Tài khoản: $account'),
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
                  try {
                    final financialOrderResponse =
                        await widget.tenantClient
                            .from('financial_orders')
                            .insert({
                              'type': 'cost',
                              'amount': amount,
                              'currency': currency,
                              'account': account,
                              'note': note,
                              'created_at': DateTime.now().toIso8601String(),
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
                      128, // Unique ID for this type of notification
                      "Phiếu Chi Phí Đã Tạo",
                      "Đã tạo phiếu chi phí cho $account với số tiền ${formatNumberLocal(amount!)} $currency",
                      'cost_created',
                    );

                    final newBalance = balance - amount!;
                    await widget.tenantClient
                        .from('financial_accounts')
                        .update({'balance': newBalance})
                        .eq('name', account!)
                        .eq('currency', currency!);

                    if (mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('Đã tạo phiếu chi phí')),
                      );

                      setState(() {
                        amount = null;
                        amountController.text = '';
                        currency =
                            currencies.isNotEmpty ? currencies.first : null;
                        account = null;
                        note = null;
                        fetchAccounts();
                      });
                    }
                  } catch (e) {
                    if (mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(
                          content: Text('Lỗi khi tạo phiếu chi phí: $e'),
                        ),
                      );
                    }
                  }
                },
                child: const Text('Tạo phiếu'),
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
    return GestureDetector(
      onHorizontalDragEnd: (details) {
        if (details.primaryVelocity != null && details.primaryVelocity! > 0) {
          Navigator.pop(context);
        }
      },
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Chi phí', style: TextStyle(color: Colors.white)),
          backgroundColor: Colors.black,
          iconTheme: const IconThemeData(color: Colors.white),
        ),
        body: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            children: [
              wrapField(
                TextFormField(
                  controller: amountController,
                  keyboardType: TextInputType.number,
                  inputFormatters: [ThousandsFormatterLocal()],
                  decoration: const InputDecoration(
                    labelText: 'Số tiền',
                    border: InputBorder.none,
                    isDense: true,
                  ),
                  onChanged: (val) {
                    final raw = val.replaceAll('.', '');
                    amount = double.tryParse(raw);
                    setState(() {});
                  },
                  validator: (val) {
                    if (val == null ||
                        val.isEmpty ||
                        double.tryParse(val.replaceAll('.', '')) == null ||
                        double.parse(val.replaceAll('.', '')) <= 0) {
                      return 'Vui lòng nhập số tiền hợp lệ';
                    }
                    return null;
                  },
                ),
              ),
              wrapField(
                DropdownButtonFormField(
                  value: currency,
                  items:
                      currencies
                          .map(
                            (e) => DropdownMenuItem(value: e, child: Text(e)),
                          )
                          .toList(),
                  onChanged: (val) {
                    setState(() {
                      currency = val!;
                      fetchAccounts();
                    });
                  },
                  decoration: const InputDecoration(
                    labelText: 'Đơn vị tiền',
                    border: InputBorder.none,
                    isDense: true,
                  ),
                ),
              ),
              wrapField(
                DropdownButtonFormField(
                  value: account,
                  items:
                      accounts
                          .map(
                            (e) => DropdownMenuItem(value: e, child: Text(e)),
                          )
                          .toList(),
                  onChanged: (val) => setState(() => account = val),
                  decoration: const InputDecoration(
                    labelText: 'Tài khoản',
                    border: InputBorder.none,
                    isDense: true,
                  ),
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
