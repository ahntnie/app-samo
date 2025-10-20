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

class ReceiveForm extends StatefulWidget {
  final SupabaseClient tenantClient;

  const ReceiveForm({super.key, required this.tenantClient});

  @override
  State<ReceiveForm> createState() => _ReceiveFormState();
}

class _ReceiveFormState extends State<ReceiveForm> {
  String? partnerType;
  String? partnerName;
  double? amount;
  String? currency;
  String? account;
  String? note;

  final _formKey = GlobalKey<FormState>();

  List<String> partnerTypes = [
    'Khách hàng',
    'Nhà cung cấp',
    'Đơn vị fix lỗi',
    'Đơn vị vận chuyển',
  ];
  List<String> partnerNames = [];
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
    if (!mounted) return;
    try {
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

      if (mounted) {
        setState(() {
          currencies = uniqueCurrencies;
          currency = currencies.isNotEmpty ? currencies.first : null;
          loadAccounts();
        });
      }
    } catch (e) {
      print('Error loading currencies: $e');
    }
  }

  Future<void> loadAccounts() async {
    if (!mounted) return;
    if (currency == null) {
      if (mounted) {
        setState(() {
          accounts = [];
          account = null;
        });
      }
      return;
    }

    try {
      final res = await widget.tenantClient
          .from('financial_accounts')
          .select('name')
          .eq('currency', currency!);
      if (mounted) {
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
    } catch (e) {
      print('Error loading accounts: $e');
    }
  }

  Future<void> loadPartnerNames(String type) async {
    if (!mounted) return;
    String table =
        type == 'Khách hàng'
            ? 'customers'
            : type == 'Nhà cung cấp'
            ? 'suppliers'
            : type == 'Đơn vị fix lỗi'
            ? 'fix_units'
            : 'transporters';
    try {
      final res = await widget.tenantClient.from(table).select('name');
      if (mounted) {
        setState(() {
          partnerNames =
              res
                  .map((e) => e['name'] as String?)
                  .where((e) => e != null)
                  .cast<String>()
                  .toList();
          partnerName = null;
        });
      }
    } catch (e) {
      print('Error loading partner names: $e');
    }
  }

  Future<void> addPartnerDialog() async {
    String name = '';
    String phone = '';
    String address = '';
    String note = '';
    String? transporterType;

    await showDialog(
      context: context,
      builder:
          (_) => AlertDialog(
            title: Text('Thêm ${partnerType?.toLowerCase()}'),
            content: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  TextField(
                    decoration: const InputDecoration(labelText: 'Tên'),
                    onChanged: (val) => name = val,
                  ),
                  TextField(
                    decoration: const InputDecoration(
                      labelText: 'Số điện thoại',
                    ),
                    keyboardType: TextInputType.phone,
                    onChanged: (val) => phone = val,
                  ),
                  TextField(
                    decoration: const InputDecoration(labelText: 'Địa chỉ'),
                    onChanged: (val) => address = val,
                  ),
                  TextField(
                    decoration: const InputDecoration(labelText: 'Ghi chú'),
                    onChanged: (val) => note = val,
                  ),
                  if (partnerType == 'Đơn vị vận chuyển') ...[
                    const SizedBox(height: 8),
                    DropdownButtonFormField<String>(
                      value: transporterType,
                      decoration: const InputDecoration(
                        labelText: 'Chủng loại',
                      ),
                      items: const [
                        DropdownMenuItem(
                          value: 'vận chuyển nội địa',
                          child: Text('Vận chuyển nội địa'),
                        ),
                        DropdownMenuItem(
                          value: 'vận chuyển quốc tế',
                          child: Text('Vận chuyển quốc tế'),
                        ),
                      ],
                      onChanged: (val) => transporterType = val,
                    ),
                  ],
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('Hủy'),
              ),
              ElevatedButton(
                onPressed: () async {
                  if (name.isNotEmpty) {
                    try {
                      final table = getTable(partnerType!);
                      final partnerData = {
                        'name': name,
                        'phone': phone.isNotEmpty ? phone : '',
                        'address': address.isNotEmpty ? address : '',
                        'note': note.isNotEmpty ? note : '',
                        'debt_vnd': 0,
                        'debt_cny': 0,
                        'debt_usd': 0,
                      };

                      if (partnerType == 'Đơn vị vận chuyển') {
                        partnerData['type'] = transporterType ?? '';
                      }

                      await widget.tenantClient.from(table).insert(partnerData);
                      await loadPartnerNames(partnerType!);
                      if (mounted) {
                        setState(() => partnerName = name);
                      }
                      Navigator.pop(context);
                    } catch (e) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(content: Text('Lỗi khi thêm đối tác: $e')),
                      );
                    }
                  } else {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(
                        content: Text('Tên đối tác không được để trống'),
                      ),
                    );
                  }
                },
                child: const Text('Lưu'),
              ),
            ],
          ),
    );
  }

  Future<Map<String, dynamic>> _createSnapshot(String ticketId) async {
    final snapshotData = <String, dynamic>{};

    try {
      if (account != null && currency != null) {
        final accountData =
            await widget.tenantClient
                .from('financial_accounts')
                .select()
                .eq('name', account!)
                .eq('currency', currency!)
                .single();
        snapshotData['financial_accounts'] = accountData;
      }

      if (partnerType != null && partnerName != null) {
        final table = getTable(partnerType!);
        final partnerData =
            await widget.tenantClient
                .from(table)
                .select()
                .eq('name', partnerName!)
                .single();
        snapshotData[table] = partnerData;
      }
    } catch (e) {
      print('Error creating snapshot: $e');
    }

    return snapshotData;
  }

  Future<void> submit() async {
    if (!_formKey.currentState!.validate()) return;
    if (partnerType == null ||
        partnerName == null ||
        currency == null ||
        account == null ||
        amount == null ||
        amount! <= 0) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Vui lòng điền đầy đủ thông tin hợp lệ')),
      );
      return;
    }

    final accData =
        await widget.tenantClient
            .from('financial_accounts')
            .select('balance')
            .eq('name', account!)
            .eq('currency', currency!)
            .maybeSingle();

    final balance = accData?['balance'] as num? ?? 0;

    final table = getTable(partnerType!);
    final partnerData =
        await widget.tenantClient
            .from(table)
            .select('debt_vnd, debt_cny, debt_usd')
            .eq('name', partnerName!)
            .single();

    String debtColumn;
    if (currency == 'VND') {
      debtColumn = 'debt_vnd';
    } else if (currency == 'CNY') {
      debtColumn = 'debt_cny';
    } else if (currency == 'USD') {
      debtColumn = 'debt_usd';
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Loại tiền tệ không được hỗ trợ: $currency')),
      );
      return;
    }

    final currentDebt =
        double.tryParse(partnerData[debtColumn]?.toString() ?? '0') ?? 0;
    final isCustomer = partnerType == 'Khách hàng';
    final newDebt = isCustomer ? currentDebt - amount! : currentDebt + amount!;

    showDialog(
      context: context,
      builder:
          (_) => AlertDialog(
            title: const Text('Xác nhận thu tiền đối tác'),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Loại đối tác: ${partnerType ?? "Không xác định"}'),
                Text('Tên đối tác: ${partnerName ?? "Không xác định"}'),
                Text(
                  'Số tiền: ${formatNumberLocal(amount!)} ${currency ?? "Không xác định"}',
                ),
                Text('Tài khoản: ${account ?? "Không xác định"}'),
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
                              'type': 'receive',
                              'partner_type': partnerType,
                              'partner_name': partnerName!,
                              'amount': amount,
                              'currency': currency!,
                              'account': account!,
                              'note': note ?? '',
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
                      134, // Unique ID for this type of notification
                      "Phiếu Thu Tiền Đã Tạo",
                      "Đã tạo phiếu thu tiền cho $partnerName với số tiền ${formatNumberLocal(amount!)} $currency",
                      'receive_created',
                    );

                    await widget.tenantClient
                        .from(table)
                        .update({debtColumn: newDebt})
                        .eq('name', partnerName!);

                    await widget.tenantClient
                        .from('financial_accounts')
                        .update({'balance': balance + amount!})
                        .eq('name', account!)
                        .eq('currency', currency!);

                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('Tạo phiếu thu thành công')),
                    );

                    if (mounted) {
                      setState(() {
                        partnerType = null;
                        partnerName = null;
                        amount = null;
                        amountController.text = '';
                        currency =
                            currencies.isNotEmpty ? currencies.first : null;
                        account = null;
                        note = null;
                        partnerNames = [];
                        loadAccounts();
                      });
                    }

                    Navigator.pop(context);
                  } catch (e) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(content: Text('Lỗi khi tạo phiếu thu: $e')),
                    );
                  }
                },
                child: const Text('Tạo phiếu'),
              ),
            ],
          ),
    );
  }

  String getTable(String type) {
    if (type == 'Khách hàng') return 'customers';
    if (type == 'Nhà cung cấp') return 'suppliers';
    if (type == 'Đơn vị fix lỗi') return 'fix_units';
    return 'transporters';
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
        if (details.primaryVelocity! > 0) Navigator.pop(context);
      },
      child: Scaffold(
        appBar: AppBar(
          backgroundColor: Colors.black,
          iconTheme: const IconThemeData(color: Colors.white),
          title: const Text(
            'Thu tiền đối tác',
            style: TextStyle(color: Colors.white),
          ),
        ),
        body: Padding(
          padding: const EdgeInsets.all(16),
          child: Form(
            key: _formKey,
            child: ListView(
              children: [
                wrapField(
                  DropdownButtonFormField(
                    value: partnerType,
                    decoration: const InputDecoration(
                      labelText: 'Loại đối tác',
                      border: InputBorder.none,
                      isDense: true,
                    ),
                    items:
                        partnerTypes
                            .map(
                              (e) => DropdownMenuItem(value: e, child: Text(e)),
                            )
                            .toList(),
                    onChanged: (val) {
                      if (mounted) {
                        setState(() {
                          partnerType = val;
                          loadPartnerNames(val!);
                        });
                      }
                    },
                  ),
                ),
                wrapField(
                  Row(
                    children: [
                      Expanded(
                        child: Autocomplete<String>(
                          optionsBuilder: (textEditingValue) {
                            final query = textEditingValue.text.toLowerCase();
                            return partnerNames
                                .where(
                                  (option) =>
                                      option.toLowerCase().contains(query),
                                )
                                .toList()
                              ..sort(
                                (a, b) => a
                                    .toLowerCase()
                                    .indexOf(query)
                                    .compareTo(b.toLowerCase().indexOf(query)),
                              )
                              ..take(3);
                          },
                          onSelected: (val) {
                            if (mounted) {
                              setState(() => partnerName = val);
                            }
                          },
                          fieldViewBuilder: (
                            context,
                            controller,
                            focusNode,
                            onFieldSubmitted,
                          ) {
                            return TextFormField(
                              controller: controller,
                              focusNode: focusNode,
                              decoration: const InputDecoration(
                                labelText: 'Tên đối tác',
                                border: InputBorder.none,
                                isDense: true,
                              ),
                            );
                          },
                        ),
                      ),
                      IconButton(
                        onPressed:
                            partnerType != null ? addPartnerDialog : null,
                        icon: const Icon(Icons.add_circle_outline),
                      ),
                    ],
                  ),
                ),
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
                      if (mounted) {
                        setState(() {});
                      }
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
                    decoration: const InputDecoration(
                      labelText: 'Đơn vị tiền tệ',
                      border: InputBorder.none,
                      isDense: true,
                    ),
                    items:
                        currencies
                            .map(
                              (e) => DropdownMenuItem(value: e, child: Text(e)),
                            )
                            .toList(),
                    onChanged: (val) {
                      if (mounted) {
                        setState(() {
                          currency = val;
                          loadAccounts();
                        });
                      }
                    },
                  ),
                ),
                wrapField(
                  DropdownButtonFormField(
                    value: account,
                    decoration: const InputDecoration(
                      labelText: 'Tài khoản',
                      border: InputBorder.none,
                      isDense: true,
                    ),
                    items:
                        accounts
                            .map(
                              (e) => DropdownMenuItem(value: e, child: Text(e)),
                            )
                            .toList(),
                    onChanged: (val) {
                      if (mounted) {
                        setState(() => account = val);
                      }
                    },
                  ),
                ),
                wrapField(
                  TextFormField(
                    decoration: const InputDecoration(
                      labelText: 'Ghi chú',
                      border: InputBorder.none,
                      isDense: true,
                    ),
                    onChanged: (val) {
                      if (mounted) {
                        setState(() => note = val);
                      }
                    },
                  ),
                ),
                const SizedBox(height: 20),
                ElevatedButton(
                  onPressed: submit,
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
      ),
    );
  }
}
