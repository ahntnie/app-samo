// lib/screens/finance_screen.dart
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';

/// Formatter tự thêm dấu “.” sau đơn vị hàng nghìn.
class ThousandsFormatter extends TextInputFormatter {
  @override
  TextEditingValue formatEditUpdate(
      TextEditingValue oldValue, TextEditingValue newValue) {
    String newText = newValue.text.replaceAll('.', '').replaceAll(',', '');
    if (newText.isEmpty) return newValue;
    final intValue = int.tryParse(newText);
    if (intValue == null) return newValue;
    final formatted =
        NumberFormat('#,###', 'vi_VN').format(intValue).replaceAll(',', '.');
    return TextEditingValue(
      text: formatted,
      selection: TextSelection.collapsed(offset: formatted.length),
    );
  }
}

class FinanceScreen extends StatefulWidget {
  const FinanceScreen({super.key});

  @override
  _FinanceScreenState createState() => _FinanceScreenState();
}

class _FinanceScreenState extends State<FinanceScreen> {
  String selectedTicketType = 'pay-partner';
  final List<Map<String, String>> ticketTypeOptions = [
    {'value': 'pay-partner', 'display': 'Chi Thanh Toán Đối Tác'},
    {'value': 'receive-partner', 'display': 'Thu Tiền Đối Tác'},
    {'value': 'expense', 'display': 'Chi Phí'},
    {'value': 'income', 'display': 'Thu Nhập Khác'},
    {'value': 'exchange', 'display': 'Đổi Tiền'},
    {'value': 'transfer', 'display': 'Chuyển Quỹ'},
  ];

  String selectedPartnerType = 'supplier';
  final List<Map<String, String>> partnerTypeOptions = [
    {'value': 'supplier', 'display': 'Nhà Cung Cấp'},
    {'value': 'customer', 'display': 'Khách Hàng'},
    {'value': 'fixer', 'display': 'Đơn Vị Fix Lỗi'},
    {'value': 'transporter', 'display': 'Đơn Vị Vận Chuyển'},
  ];
  final List<String> partnerSuggestions = ['Đối Tác A', 'Đối Tác B', 'Đối Tác C'];
  String selectedPartner = '';

  final TextEditingController amountController = TextEditingController();
  String selectedCurrency = 'VND';
  final List<Map<String, String>> currencyOptions = [
    {'value': 'VND', 'display': 'VND'},
    {'value': 'CNY', 'display': 'CNY'},
  ];

  final List<String> allAccountOptions = [
    'techcombank',
    'vietcombank',
    'mbbank',
    'tiền mặt',
    'tiền tiết kiệm',
    'nhân dân tệ'
  ];
  String selectedAccount = '';

  String selectedTargetAccount = '';

  final TextEditingController exchangeRateController = TextEditingController();
  final TextEditingController cnyPreviewController =
      TextEditingController(text: "0 CNY");
  final TextEditingController descriptionController = TextEditingController();

  @override
  void initState() {
    super.initState();
    selectedAccount = allAccountOptions[0];
  }

  @override
  void dispose() {
    amountController.dispose();
    exchangeRateController.dispose();
    cnyPreviewController.dispose();
    descriptionController.dispose();
    super.dispose();
  }

  Widget buildFinanceForm() {
    return SizedBox(
      width: double.infinity,
      child: Card(
        elevation: 2,
        margin: const EdgeInsets.only(top: 12),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              DropdownButtonFormField<String>(
                decoration: InputDecoration(
                  labelText: 'Loại Phiếu',
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                  contentPadding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                ),
                value: selectedTicketType,
                items: ticketTypeOptions
                    .map((option) => DropdownMenuItem(
                          value: option['value'],
                          child: Text(option['display']!),
                        ))
                    .toList(),
                onChanged: (val) {
                  setState(() {
                    selectedTicketType = val ?? 'pay-partner';
                    if (selectedTicketType == 'transfer') {
                      selectedCurrency = 'VND';
                      if (selectedTargetAccount == 'nhân dân tệ') {
                        selectedTargetAccount = '';
                      }
                    }
                  });
                },
              ),
              const SizedBox(height: 12),
              if (selectedTicketType == 'pay-partner' || selectedTicketType == 'receive-partner') ...[
                Row(
                  children: [
                    Expanded(
                      child: DropdownButtonFormField<String>(
                        decoration: InputDecoration(
                          labelText: 'Loại Đối Tác',
                          border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                          contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                        ),
                        icon: const SizedBox.shrink(),
                        isDense: true,
                        value: selectedPartnerType,
                        items: partnerTypeOptions
                            .map((option) => DropdownMenuItem(
                                  value: option['value'],
                                  child: Text(option['display']!),
                                ))
                            .toList(),
                        onChanged: (val) {
                          setState(() {
                            selectedPartnerType = val ?? 'supplier';
                          });
                        },
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Autocomplete<String>(
                        optionsBuilder: (TextEditingValue textEditingValue) {
                          if (textEditingValue.text.isEmpty) {
                            return const Iterable<String>.empty();
                          }
                          return partnerSuggestions.where((option) => option
                              .toLowerCase()
                              .contains(textEditingValue.text.toLowerCase()));
                        },
                        onSelected: (String selection) {
                          setState(() {
                            selectedPartner = selection;
                          });
                        },
                        fieldViewBuilder: (context, textEditingController, focusNode, onFieldSubmitted) {
                          textEditingController.text = selectedPartner;
                          return TextFormField(
                            controller: textEditingController,
                            focusNode: focusNode,
                            decoration: InputDecoration(
                              labelText: 'Đối Tác',
                              border: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(12),
                              ),
                              contentPadding:
                                  const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                            ),
                          );
                        },
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
              ],
              Row(
                children: [
                  Expanded(
                    child: TextFormField(
                      controller: amountController,
                      keyboardType: TextInputType.number,
                      inputFormatters: [ThousandsFormatter()],
                      decoration: InputDecoration(
                        labelText: 'Số Tiền',
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                        contentPadding:
                            const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: DropdownButtonFormField<String>(
                      decoration: InputDecoration(
                        labelText: 'Loại Đơn Vị Tiền Tệ',
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                        contentPadding:
                            const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                      ),
                      value: selectedCurrency,
                      items: currencyOptions
                          .map((option) => DropdownMenuItem(
                                value: option['value'],
                                child: Text(option['display']!),
                              ))
                          .toList(),
                      onChanged: selectedTicketType == 'transfer' ? null : (val) {
                        setState(() {
                          selectedCurrency = val ?? 'VND';
                        });
                      },
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: DropdownButtonFormField<String>(
                      decoration: InputDecoration(
                        labelText: 'Tài Khoản',
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                        contentPadding:
                            const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                      ),
                      value: selectedAccount.isEmpty ? null : selectedAccount,
                      items: allAccountOptions
                          .map((account) => DropdownMenuItem(
                                value: account,
                                child: Text(account),
                              ))
                          .toList(),
                      onChanged: (val) {
                        setState(() {
                          selectedAccount = val ?? '';
                        });
                      },
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              if (selectedTicketType == 'transfer') ...[
                Row(
                  children: [
                    Expanded(
                      child: DropdownButtonFormField<String>(
                        decoration: InputDecoration(
                          labelText: 'Tài Khoản Đích',
                          border: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(12)),
                          contentPadding:
                              const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                        ),
                        value: selectedTargetAccount.isEmpty ? null : selectedTargetAccount,
                        items: allAccountOptions
                            .where((account) => account != 'nhân dân tệ')
                            .map((account) => DropdownMenuItem(
                                  value: account,
                                  child: Text(account),
                                ))
                            .toList(),
                        onChanged: (val) {
                          setState(() {
                            selectedTargetAccount = val ?? '';
                          });
                        },
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
              ],
              if (selectedTicketType == 'exchange') ...[
                Row(
                  children: [
                    Expanded(
                      child: TextFormField(
                        controller: exchangeRateController,
                        keyboardType: TextInputType.number,
                        decoration: InputDecoration(
                          labelText: 'Tỉ Giá (VND/CNY)',
                          border: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(12)),
                          contentPadding:
                              const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: InputDecorator(
                        decoration: InputDecoration(
                          labelText: 'Số Tiền CNY',
                          border: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(12)),
                          contentPadding:
                              const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                        ),
                        child: Text(cnyPreviewController.text),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
              ],
              TextFormField(
                controller: descriptionController,
                maxLines: 3,
                decoration: InputDecoration(
                  labelText: 'Mô Tả',
                  border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12)),
                  contentPadding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  void showReviewDialog() {
    showDialog(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text('Xem lại thông tin phiếu'),
          content: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text("Loại Phiếu: ${ticketTypeOptions.firstWhere((option) => option['value'] == selectedTicketType)['display']}"),
                if (selectedTicketType == 'pay-partner' || selectedTicketType == 'receive-partner')
                  Text("Loại Đối Tác: $selectedPartnerType"),
                if (selectedTicketType == 'pay-partner' || selectedTicketType == 'receive-partner')
                  Text("Đối Tác: $selectedPartner"),
                Text("Số Tiền: ${amountController.text}"),
                Text("Loại Tiền: $selectedCurrency"),
                Text("Tài Khoản: $selectedAccount"),
                if (selectedTicketType == 'transfer')
                  Text("Tài Khoản Đích: $selectedTargetAccount"),
                if (selectedTicketType == 'exchange')
                  Text("Tỉ Giá: ${exchangeRateController.text}"),
                Text("Mô Tả: ${descriptionController.text}"),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () {
                Navigator.pop(context);
              },
              child: const Text('Chỉnh sửa'),
            ),
            ElevatedButton(
              onPressed: () {
                Navigator.pop(context);
                // Gọi repository/logic để lưu dữ liệu phiếu lên Firebase
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('Tạo phiếu thành công!')),
                );
              },
              child: const Text('Tạo Phiếu'),
            )
          ],
        );
      },
    );
  }

  Widget buildFinanceActionButton() {
    return Center(
      child: ElevatedButton(
        onPressed: showReviewDialog,
        style: ElevatedButton.styleFrom(
          backgroundColor: Colors.yellow,
          padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 10),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        ),
        child: const Text(
          'Thêm Vào Phiếu',
          style: TextStyle(fontSize: 16, color: Colors.black),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        backgroundColor: Colors.grey[900],
        iconTheme: const IconThemeData(color: Colors.white),
        title: const Text('Tài chính', style: TextStyle(color: Colors.white)),
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(12),
        child: Column(
          children: [
            buildFinanceForm(),
            const SizedBox(height: 12),
            buildFinanceActionButton(),
          ],
        ),
      ),
    );
  }
}
