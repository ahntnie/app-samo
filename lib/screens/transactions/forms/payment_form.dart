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

class PaymentForm extends StatefulWidget {
  final SupabaseClient tenantClient;

  const PaymentForm({super.key, required this.tenantClient});

  @override
  State<PaymentForm> createState() => _PaymentFormState();
}

class _PaymentFormState extends State<PaymentForm> {
  String partnerType = 'suppliers';
  String? partnerName;
  double amount = 0;
  String? currency;
  String? account;
  String? note;
  bool isLoading = true;
  String? errorMessage;

  List<String> currencies = [];
  List<String> accounts = [];
  List<String> partnerSuggestions = [];

  final Map<String, String> partnerTypeLabels = {
    'suppliers': 'Nhà cung cấp',
    'fix_units': 'Đơn vị fix lỗi',
    'transporters': 'Đơn vị vận chuyển',
  };

  final TextEditingController amountController = TextEditingController();

  @override
  void initState() {
    super.initState();
    _loadInitialData();
  }

  @override
  void dispose() {
    amountController.dispose();
    super.dispose();
  }

  Future<void> _loadInitialData() async {
    setState(() {
      isLoading = true;
      errorMessage = null;
    });

    try {
      await Future.wait([loadCurrencies(), loadPartners()]);
    } catch (e) {
      setState(() {
        errorMessage = 'Không thể tải dữ liệu: $e';
      });
    } finally {
      setState(() {
        isLoading = false;
      });
    }
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
      loadAccounts();
    });
  }

  Future<void> loadAccounts() async {
    if (currency == null) {
      setState(() {
        accounts = [];
        account = null;
      });
      return;
    }

    final response = await widget.tenantClient
        .from('financial_accounts')
        .select('name')
        .eq('currency', currency!);
    setState(() {
      accounts =
          response
              .map((e) => e['name'] as String?)
              .where((e) => e != null)
              .cast<String>()
              .toList();
      account = accounts.isNotEmpty ? accounts.first : null;
    });
  }

  Future<void> loadPartners() async {
    try {
      final response = await widget.tenantClient
          .from(partnerType)
          .select('name');
      setState(() {
        partnerSuggestions =
            response
                .map((e) => e['name'] as String?)
                .where((e) => e != null)
                .cast<String>()
                .toList();
        partnerName = null;
      });
    } catch (e) {
      setState(() {
        partnerSuggestions = [];
        errorMessage = 'Không thể tải danh sách đối tác: $e';
      });
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
            title: Text(
              'Thêm ${partnerTypeLabels[partnerType]?.toLowerCase()}',
            ),
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
                  if (partnerType == 'transporters') ...[
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
                      final partnerData = {
                        'name': name,
                        'phone': phone.isNotEmpty ? phone : null,
                        'address': address.isNotEmpty ? address : null,
                        'note': note.isNotEmpty ? note : null,
                        'debt_vnd': 0,
                        'debt_cny': 0,
                        'debt_usd': 0,
                      };

                      if (partnerType == 'transporters') {
                        partnerData['type'] = transporterType;
                      }

                      await widget.tenantClient
                          .from(partnerType)
                          .insert(partnerData);
                      await loadPartners();
                      setState(() => partnerName = name);
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

    if (partnerName != null) {
      final partnerData =
          await widget.tenantClient
              .from(partnerType)
              .select()
              .eq('name', partnerName!)
              .single();
      snapshotData[partnerType] = partnerData;
    }

    return snapshotData;
  }

  Future<void> showConfirm() async {
    if (partnerName == null ||
        currency == null ||
        account == null ||
        amount <= 0) {
      await showDialog(
        context: context,
        builder:
            (context) => AlertDialog(
              title: const Text('Thông báo'),
              content: const Text('Vui lòng điền đầy đủ thông tin hợp lệ'),
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

    final balanceData =
        await widget.tenantClient
            .from('financial_accounts')
            .select('balance')
            .eq('name', account!)
            .eq('currency', currency!)
            .single();

    final currentBalance = balanceData['balance'] ?? 0;

    if (currentBalance < amount) {
      await showDialog(
        context: context,
        builder:
            (context) => AlertDialog(
              title: const Text('Thông báo'),
              content: const Text('Tài khoản không đủ tiền'),
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

    String debtColumn;
    double currentDebt;
    if (partnerType == 'transporters') {
      final partnerData =
          await widget.tenantClient
              .from(partnerType)
              .select('debt')
              .eq('name', partnerName!)
              .single();

      debtColumn = 'debt';
      currentDebt = double.tryParse(partnerData[debtColumn].toString()) ?? 0;
    } else {
      final partnerData =
          await widget.tenantClient
              .from(partnerType)
              .select('debt_vnd, debt_cny, debt_usd')
              .eq('name', partnerName!)
              .single();

      if (currency == 'VND') {
        debtColumn = 'debt_vnd';
      } else if (currency == 'CNY') {
        debtColumn = 'debt_cny';
      } else if (currency == 'USD') {
        debtColumn = 'debt_usd';
      } else {
        throw Exception('Loại tiền tệ không được hỗ trợ: $currency');
      }

      currentDebt = double.tryParse(partnerData[debtColumn].toString()) ?? 0;
    }

    showDialog(
      context: context,
      builder:
          (_) => AlertDialog(
            title: const Text('Xác nhận phiếu chi'),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Loại đối tác: ${partnerTypeLabels[partnerType]}'),
                Text('Tên đối tác: $partnerName'),
                Text('Số tiền: ${formatNumberLocal(amount)} $currency'),
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
                  try {
                    final financialOrderResponse =
                        await widget.tenantClient
                            .from('financial_orders')
                            .insert({
                              'type': 'payment',
                              'partner_type': partnerType,
                              'partner_name': partnerName,
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

                    print('Attempting to show payment notification');
                    // Show notification for successful snapshot creation
                    try {
                      await NotificationService.showNotification(
                        134, // Unique ID for this type of notification
                        "Phiếu Chi Đã Tạo",
                        "Đã tạo phiếu chi với số tiền ${formatNumberLocal(amount)} $currency",
                        'payment_created',
                      );
        
                    } catch (e) {
                      print('Error showing payment notification: $e');
                    }

                    double updatedDebt = currentDebt - amount;

                    await widget.tenantClient
                        .from(partnerType)
                        .update({debtColumn: updatedDebt})
                        .eq('name', partnerName!);

                    await widget.tenantClient
                        .from('financial_accounts')
                        .update({'balance': currentBalance - amount})
                        .eq('name', account!)
                        .eq('currency', currency!);

                    if (mounted) {
                      Navigator.pop(context);
                      await showDialog(
                        context: context,
                        builder:
                            (context) => AlertDialog(
                              title: const Text('Thông báo'),
                              content: const Text(
                                'Đã tạo phiếu chi thành công',
                              ),
                              actions: [
                                TextButton(
                                  onPressed: () => Navigator.pop(context),
                                  child: const Text('Đóng'),
                                ),
                              ],
                            ),
                      );

                      setState(() {
                        partnerType = 'suppliers';
                        partnerName = null;
                        amount = 0;
                        amountController.text = '';
                        currency =
                            currencies.isNotEmpty ? currencies.first : null;
                        account = null;
                        note = null;
                        loadPartners();
                        loadAccounts();
                      });
                    }
                  } catch (e) {
                    if (mounted) {
                      Navigator.pop(context);
                      await showDialog(
                        context: context,
                        builder:
                            (context) => AlertDialog(
                              title: const Text('Lỗi'),
                              content: Text('Lỗi khi tạo phiếu chi: $e'),
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
                onPressed: _loadInitialData,
                child: const Text('Thử lại'),
              ),
            ],
          ),
        ),
      );
    }

    return GestureDetector(
      onHorizontalDragEnd: (details) {
        if (details.primaryVelocity! > 0) Navigator.pop(context);
      },
      child: Scaffold(
        appBar: AppBar(
          title: const Text(
            'Chi thanh toán đối tác',
            style: TextStyle(color: Colors.white),
          ),
          backgroundColor: Colors.black,
          iconTheme: const IconThemeData(color: Colors.white),
        ),
        body: Padding(
          padding: const EdgeInsets.all(16),
          child: SingleChildScrollView(
            child: Column(
              children: [
                wrapField(
                  DropdownButtonFormField(
                    value: partnerType,
                    items:
                        partnerTypeLabels.entries
                            .map(
                              (e) => DropdownMenuItem(
                                value: e.key,
                                child: Text(e.value),
                              ),
                            )
                            .toList(),
                    onChanged: (val) async {
                      setState(() {
                        partnerType = val!;
                      });
                      await loadPartners();
                    },
                    decoration: const InputDecoration(
                      labelText: 'Loại đối tác',
                      border: InputBorder.none,
                      isDense: true,
                    ),
                  ),
                ),
                wrapField(
                  Row(
                    children: [
                      Expanded(
                        child: Autocomplete<String>(
                          optionsBuilder: (textEditingValue) {
                            final query = textEditingValue.text.toLowerCase();
                            return partnerSuggestions
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
                          onSelected:
                              (val) => setState(() => partnerName = val),
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
                        onPressed: addPartnerDialog,
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
                    onChanged: (val) {
                      final raw = val.replaceAll('.', '');
                      amount = double.tryParse(raw) ?? 0;
                    },
                    decoration: const InputDecoration(
                      labelText: 'Số tiền',
                      border: InputBorder.none,
                      isDense: true,
                    ),
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
                    onChanged:
                        (val) => setState(() {
                          currency = val!;
                          loadAccounts();
                        }),
                    decoration: const InputDecoration(
                      labelText: 'Đơn vị tiền tệ',
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
                    onChanged: (val) => setState(() => account = val!),
                    decoration: const InputDecoration(
                      labelText: 'Tài khoản',
                      border: InputBorder.none,
                      isDense: true,
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
      ),
    );
  }
}