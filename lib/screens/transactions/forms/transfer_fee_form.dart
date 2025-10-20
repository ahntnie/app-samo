import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:intl/intl.dart';

class FeeEntry {
  String min;
  String max;
  String fee;
  TextEditingController minController;
  TextEditingController maxController;
  TextEditingController feeController;

  FeeEntry({
    required this.min,
    required this.max,
    required this.fee,
    required this.minController,
    required this.maxController,
    required this.feeController,
  });

  void dispose() {
    minController.dispose();
    maxController.dispose();
    feeController.dispose();
  }
}

class TransferFeeForm extends StatefulWidget {
  final SupabaseClient tenantClient;

  const TransferFeeForm({super.key, required this.tenantClient});

  @override
  State<TransferFeeForm> createState() => _TransferFeeFormState();
}

class _TransferFeeFormState extends State<TransferFeeForm> {
  String? transporter;
  List<String> transporterSuggestions = [];
  List<FeeEntry> fees = [];

  final currencyFormatter = NumberFormat('#,###', 'vi_VN');

  @override
  void initState() {
    super.initState();
    loadTransporters();
  }

  Future<void> loadTransporters() async {
    try {
      final response = await widget.tenantClient.from('transporters').select('name');
      setState(() {
        transporterSuggestions = response
            .map((e) => e['name'] as String?)
            .where((name) => name != null)
            .cast<String>()
            .toList();
      });
    } catch (e) {
      _showErrorDialog('Lỗi khi tải danh sách đơn vị vận chuyển: $e');
    }
  }

  Future<void> loadFees() async {
    if (transporter == null) return;
    try {
      final response = await widget.tenantClient
          .from('shipping_rates')
          .select()
          .eq('transporter', transporter!);
      setState(() {
        fees = response.map((item) {
          final minValue = currencyFormatter.format(item['min_value'] ?? 0);
          final maxValue = currencyFormatter.format(item['max_value'] ?? 0);
          final costValue = currencyFormatter.format(item['cost'] ?? 0);
          return FeeEntry(
            min: minValue,
            max: maxValue,
            fee: costValue,
            minController: TextEditingController(text: minValue),
            maxController: TextEditingController(text: maxValue),
            feeController: TextEditingController(text: costValue),
          );
        }).toList();
      });
    } catch (e) {
      _showErrorDialog('Lỗi khi tải ngưỡng cước: $e');
    }
  }

  Future<void> saveFees() async {
    if (transporter == null || fees.isEmpty) {
      _showErrorDialog('Vui lòng chọn đơn vị vận chuyển và thêm ít nhất một ngưỡng cước');
      return;
    }

    try {
      await widget.tenantClient.from('shipping_rates').delete().eq('transporter', transporter!);

      for (final fee in fees) {
        await widget.tenantClient.from('shipping_rates').insert({
          'transporter': transporter,
          'min_value': int.tryParse(fee.min.replaceAll('.', '')) ?? 0,
          'max_value': int.tryParse(fee.max.replaceAll('.', '')) ?? 0,
          'cost': int.tryParse(fee.fee.replaceAll('.', '')) ?? 0,
        });
      }

      await showDialog(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Thành công'),
          content: const Text('Đã lưu ngưỡng cước thành công'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Đóng'),
            ),
          ],
        ),
      );
    } catch (e) {
      _showErrorDialog('Lỗi khi lưu ngưỡng cước: $e');
    }
  }

  Future<void> addTransporterDialog() async {
    String name = '';
    String? type;
    String phone = '';
    String address = '';
    String note = '';

    await showDialog(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Thêm đơn vị vận chuyển'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                decoration: const InputDecoration(labelText: 'Tên đơn vị'),
                onChanged: (val) => name = val,
              ),
              const SizedBox(height: 8),
              DropdownButtonFormField<String>(
                value: type,
                decoration: const InputDecoration(labelText: 'Chủng loại'),
                items: const [
                  DropdownMenuItem(
                      value: 'vận chuyển nội địa', child: Text('Vận chuyển nội địa')),
                  DropdownMenuItem(
                      value: 'vận chuyển quốc tế', child: Text('Vận chuyển quốc tế')),
                ],
                onChanged: (val) => type = val,
              ),
              const SizedBox(height: 8),
              TextField(
                decoration: const InputDecoration(labelText: 'Số điện thoại'),
                keyboardType: TextInputType.phone,
                onChanged: (val) => phone = val,
              ),
              const SizedBox(height: 8),
              TextField(
                decoration: const InputDecoration(labelText: 'Địa chỉ'),
                onChanged: (val) => address = val,
              ),
              const SizedBox(height: 8),
              TextField(
                decoration: const InputDecoration(labelText: 'Ghi chú'),
                onChanged: (val) => note = val,
              ),
            ],
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Huỷ')),
          ElevatedButton(
            onPressed: () async {
              if (name.isNotEmpty) {
                try {
                  await widget.tenantClient.from('transporters').insert({
                    'name': name,
                    'type': type,
                    'phone': phone.isNotEmpty ? phone : null,
                    'address': address.isNotEmpty ? address : null,
                    'note': note.isNotEmpty ? note : null,
                  });
                  await loadTransporters();
                  setState(() => transporter = name);
                  Navigator.pop(context);
                } catch (e) {
                  _showErrorDialog('Lỗi thêm đơn vị vận chuyển: $e');
                }
              } else {
                _showErrorDialog('Vui lòng nhập tên đơn vị vận chuyển');
              }
            },
            child: const Text('Lưu'),
          ),
        ],
      ),
    );
  }

  void addFee() {
    setState(() {
      final initialValue = currencyFormatter.format(0);
      fees.add(FeeEntry(
        min: initialValue,
        max: initialValue,
        fee: initialValue,
        minController: TextEditingController(text: initialValue),
        maxController: TextEditingController(text: initialValue),
        feeController: TextEditingController(text: initialValue),
      ));
    });
  }

  void removeFee(int index) {
    setState(() {
      fees[index].dispose();
      fees.removeAt(index);
    });
  }

  void _showErrorDialog(String message) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
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

  Widget feeInput(int index) {
    final item = fees[index];
    return Row(
      children: [
        Expanded(
          child: TextFormField(
            controller: item.minController,
            keyboardType: TextInputType.number,
            decoration: const InputDecoration(labelText: 'Từ giá'),
            onChanged: (val) {
              final rawValue = val.replaceAll('.', '');
              setState(() {
                item.min = rawValue;
                item.minController.text =
                    currencyFormatter.format(int.tryParse(rawValue) ?? 0);
                item.minController.selection = TextSelection.fromPosition(
                  TextPosition(offset: item.minController.text.length),
                );
              });
            },
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: TextFormField(
            controller: item.maxController,
            keyboardType: TextInputType.number,
            decoration: const InputDecoration(labelText: 'Đến giá'),
            onChanged: (val) {
              final rawValue = val.replaceAll('.', '');
              setState(() {
                item.max = rawValue;
                item.maxController.text =
                    currencyFormatter.format(int.tryParse(rawValue) ?? 0);
                item.maxController.selection = TextSelection.fromPosition(
                  TextPosition(offset: item.maxController.text.length),
                );
              });
            },
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: TextFormField(
            controller: item.feeController,
            keyboardType: TextInputType.number,
            decoration: const InputDecoration(labelText: 'Cước phí'),
            onChanged: (val) {
              final rawValue = val.replaceAll('.', '');
              setState(() {
                item.fee = rawValue;
                item.feeController.text =
                    currencyFormatter.format(int.tryParse(rawValue) ?? 0);
                item.feeController.selection = TextSelection.fromPosition(
                  TextPosition(offset: item.feeController.text.length),
                );
              });
            },
          ),
        ),
        IconButton(
          onPressed: () => removeFee(index),
          icon: const Icon(Icons.delete, color: Colors.red),
        )
      ],
    );
  }

  Widget transporterInput() {
    final controller = TextEditingController(text: transporter);
    return Row(
      children: [
        Expanded(
          child: Autocomplete<String>(
            optionsBuilder: (textEditingValue) => transporterSuggestions
                .where((option) =>
                    option.toLowerCase().contains(textEditingValue.text.toLowerCase())),
            onSelected: (selection) {
              setState(() => transporter = selection);
              loadFees();
            },
            fieldViewBuilder: (context, fieldController, focusNode, onSubmit) {
              fieldController.text = transporter ?? '';
              return TextField(
                controller: fieldController,
                focusNode: focusNode,
                decoration: const InputDecoration(labelText: 'Đơn vị vận chuyển'),
                onSubmitted: (_) {
                  setState(() {
                    transporter = fieldController.text;
                    loadFees();
                  });
                },
              );
            },
          ),
        ),
        IconButton(
            onPressed: addTransporterDialog,
            icon: const Icon(Icons.add_circle_outline))
      ],
    );
  }

  @override
  void dispose() {
    for (var fee in fees) {
      fee.dispose();
    }
    super.dispose();
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
          title: const Text('Đơn vị vận chuyển / Chỉnh cước',
              style: TextStyle(color: Colors.white)),
          backgroundColor: Colors.black,
          iconTheme: const IconThemeData(color: Colors.white),
        ),
        body: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              transporterInput(),
              const SizedBox(height: 16),
              if (transporter != null) ...[
                const Text('Ngưỡng cước:',
                    style: TextStyle(fontWeight: FontWeight.bold)),
                const SizedBox(height: 8),
                ...fees.asMap().entries.map((e) => feeInput(e.key)),
                const SizedBox(height: 16),
                ElevatedButton.icon(
                  onPressed: addFee,
                  icon: const Icon(Icons.add),
                  label: const Text('Thêm ngưỡng cước'),
                ),
                const SizedBox(height: 20),
                ElevatedButton(
                  onPressed: saveFees,
                  style: ElevatedButton.styleFrom(backgroundColor: Colors.green),
                  child: const Text('Xác nhận', style: TextStyle(color: Colors.white)),
                )
              ]
            ],
          ),
        ),
      ),
    );
  }
}