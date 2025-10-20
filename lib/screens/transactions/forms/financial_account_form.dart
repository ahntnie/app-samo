import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

class FinancialAccountForm extends StatefulWidget {
  final SupabaseClient tenantClient;

  const FinancialAccountForm({super.key, required this.tenantClient});

  @override
  State<FinancialAccountForm> createState() => _FinancialAccountFormState();
}

class _FinancialAccountFormState extends State<FinancialAccountForm> {
  List<Map<String, dynamic>> accounts = [];

  final currencies = ['VND', 'CNY', 'USD'];
  String? selectedCurrency;

  @override
  void initState() {
    super.initState();
    fetchAccounts();
  }

  Future<void> fetchAccounts() async {
    final data = await widget.tenantClient.from('financial_accounts').select();
    setState(() {
      accounts = data.map((e) => Map<String, dynamic>.from(e)).toList();
    });
  }

  Future<void> addAccount() async {
    String name = '';
    String currency = 'VND';
    await showDialog(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Thêm tài khoản'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              decoration: const InputDecoration(labelText: 'Tên tài khoản'),
              onChanged: (val) => name = val,
            ),
            DropdownButtonFormField<String>(
              value: currency,
              items: currencies.map((e) => DropdownMenuItem(value: e, child: Text(e))).toList(),
              onChanged: (val) => currency = val!,
              decoration: const InputDecoration(labelText: 'Loại tiền'),
            )
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Hủy')),
          ElevatedButton(
            onPressed: () async {
              await widget.tenantClient.from('financial_accounts').insert({
                'name': name,
                'balance': 0,
                'currency': currency,
              });
              Navigator.pop(context);
              fetchAccounts();
            },
            child: const Text('Lưu'),
          )
        ],
      ),
    );
  }

  Future<void> deleteAccount(int id) async {
    await widget.tenantClient.from('financial_accounts').delete().eq('id', id);
    fetchAccounts();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Tài khoản thanh toán', style: TextStyle(color: Colors.white)),
        backgroundColor: Colors.black,
        iconTheme: const IconThemeData(color: Colors.white),
        actions: [
          IconButton(
            onPressed: addAccount,
            icon: const Icon(Icons.add),
          )
        ],
      ),
      body: ListView.separated(
        padding: const EdgeInsets.all(16),
        separatorBuilder: (_, __) => const Divider(),
        itemCount: accounts.length,
        itemBuilder: (_, index) {
          final acc = accounts[index];
          return ListTile(
            title: Text(acc['name']),
            subtitle: Text('Số dư: ${acc['balance']} ${acc['currency']}'),
            trailing: IconButton(
              icon: const Icon(Icons.delete),
              onPressed: () => deleteAccount(acc['id']),
            ),
          );
        },
      ),
    );
  }
}