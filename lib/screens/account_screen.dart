import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:bcrypt/bcrypt.dart';

class SubAccount {
  String id;
  String username;
  List<String> permissions;

  SubAccount({
    required this.id,
    required this.username,
    required this.permissions,
  });

  factory SubAccount.fromMap(Map<String, dynamic> map) {
    return SubAccount(
      id: map['id'] ?? '',
      username: map['username'] ?? '',
      permissions: List<String>.from(map['permissions'] ?? []),
    );
  }
}

class AccountScreen extends StatefulWidget {
  final SupabaseClient tenantClient;

  const AccountScreen({super.key, required this.tenantClient});

  @override
  _AccountScreenState createState() => _AccountScreenState();
}

class _AccountScreenState extends State<AccountScreen> {
  final List<Map<String, String>> availablePermissions = [
    {'value': 'admin', 'display': 'Quyền quản trị viên (toàn quyền)'},
    {'value': 'access_import_form', 'display': 'Truy cập phiếu nhập hàng'},
    {'value': 'access_return_form', 'display': 'Truy cập phiếu trả hàng'},
    {'value': 'access_sale_form', 'display': 'Truy cập phiếu bán hàng'},
    {'value': 'access_fix_send_form', 'display': 'Truy cập phiếu gửi sửa'},
    {'value': 'access_fix_receive_form', 'display': 'Truy cập phiếu nhận sửa'},
    {'value': 'access_reimport_form', 'display': 'Truy cập phiếu nhập lại hàng'},
    {'value': 'access_transfer_local_form', 'display': 'Truy cập phiếu chuyển nội địa'},
    {'value': 'access_transfer_global_form', 'display': 'Truy cập phiếu chuyển quốc tế'},
    {'value': 'access_transfer_receive_form', 'display': 'Truy cập phiếu nhập kho vận chuyển'},
    {'value': 'access_transfer_fee_form', 'display': 'Truy cập phiếu cước vận chuyển'},
    {'value': 'access_warehouse_form', 'display': 'Truy cập phiếu thêm/sửa kho'},
    {'value': 'access_payment_form', 'display': 'Truy cập phiếu chi đối tác'},
    {'value': 'access_receive_form', 'display': 'Truy cập phiếu thu đối tác'},
    {'value': 'access_income_other_form', 'display': 'Truy cập phiếu thu nhập khác'},
    {'value': 'access_cost_form', 'display': 'Truy cập phiếu chi phí'},
    {'value': 'access_exchange_form', 'display': 'Truy cập phiếu đổi tiền'},
    {'value': 'access_transfer_fund_form', 'display': 'Truy cập phiếu chuyển quỹ'},
    {'value': 'access_financial_account_form', 'display': 'Truy cập phiếu tài khoản thanh toán'},
    {'value': 'access_customers_screen', 'display': 'Truy cập màn hình khách hàng'},
    {'value': 'access_suppliers_screen', 'display': 'Truy cập màn hình nhà cung cấp'},
    {'value': 'access_transporters_screen', 'display': 'Truy cập màn hình đơn vị vận chuyển'},
    {'value': 'access_fixers_screen', 'display': 'Truy cập màn hình đơn vị sửa chữa'},
    {'value': 'access_crm_screen', 'display': 'Truy cập màn hình CRM'},
    {'value': 'access_orders_screen', 'display': 'Truy cập màn hình khách đặt hàng'},
    {'value': 'access_history_screen', 'display': 'Truy cập màn hình lịch sử phiếu'},
    {'value': 'view_import_price', 'display': 'Xem giá nhập'},
    {'value': 'view_cost_price', 'display': 'Xem giá vốn'},
    {'value': 'view_supplier', 'display': 'Xem nhà cung cấp'},
    {'value': 'view_sale_price', 'display': 'Xem giá bán'},
    {'value': 'view_customer', 'display': 'Xem khách hàng'},
    {'value': 'create_transaction', 'display': 'Tạo giao dịch'},
    {'value': 'edit_transaction', 'display': 'Sửa giao dịch'},
    {'value': 'cancel_transaction', 'display': 'Hủy giao dịch'},
    {'value': 'manage_accounts', 'display': 'Quản lý tài khoản phụ'},
    {'value': 'view_company_value', 'display': 'Xem giá trị công ty'},
    {'value': 'view_profit', 'display': 'Xem lợi nhuận'},
    {'value': 'view_finance', 'display': 'Xem tab tài chính'},
    {'value': 'access_excel_report', 'display': 'Nhập xuất báo cáo tổng hợp'},
  ];

  List<String> get allPermissions => availablePermissions.map((p) => p['value']!).toList();

  Future<List<SubAccount>> getSubAccounts() async {
    final response = await widget.tenantClient.from('sub_accounts').select('id, username, permissions');
    return (response as List<dynamic>).map((map) => SubAccount.fromMap(map)).toList();
  }

  void addSubAccount() {
    showDialog(
      context: context,
      builder: (context) => AddSubAccountDialog(
        availablePermissions: availablePermissions,
        onSave: (username, password, permissions) async {
          if (username.toLowerCase() == 'admin') {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('Không thể thêm tài khoản với tên "admin"')),
            );
            return;
          }
          try {
            final passwordHash = BCrypt.hashpw(password, BCrypt.gensalt());
            await widget.tenantClient.from('sub_accounts').insert({
              'username': username,
              'password_hash': passwordHash,
              'permissions': permissions,
            });
            setState(() {});
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('Thêm tài khoản phụ thành công')),
            );
          } catch (e) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text('Lỗi khi thêm tài khoản phụ: $e')),
            );
          }
        },
      ),
    );
  }

  void editSubAccount(SubAccount account) {
    final isAdmin = account.username.toLowerCase() == 'admin';
    showDialog(
      context: context,
      builder: (context) => EditSubAccountDialog(
        account: account,
        availablePermissions: availablePermissions,
        isAdmin: isAdmin,
        onSave: (username, password, permissions) async {
          try {
            final updateData = {
              if (!isAdmin) 'username': username,
              'permissions': isAdmin ? allPermissions : permissions,
            };
            if (password.isNotEmpty) {
              updateData['password_hash'] = BCrypt.hashpw(password, BCrypt.gensalt());
            }
            await widget.tenantClient.from('sub_accounts').update(updateData).eq('id', account.id);
            setState(() {});
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text(isAdmin ? 'Cập nhật mật khẩu admin thành công' : 'Sửa tài khoản phụ thành công')),
            );
          } catch (e) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text('Lỗi khi sửa tài khoản: $e')),
            );
          }
        },
      ),
    );
  }

  void deleteSubAccount(String id, String username) async {
    if (username.toLowerCase() == 'admin') {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Không thể xóa tài khoản admin')),
      );
      return;
    }
    try {
      await widget.tenantClient.from('sub_accounts').delete().eq('id', id);
      setState(() {});
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Xóa tài khoản phụ thành công')),
      );
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Lỗi khi xóa tài khoản phụ: $e')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Tài Khoản Phụ', style: TextStyle(color: Colors.white)),
        backgroundColor: Colors.grey[800],
        iconTheme: const IconThemeData(color: Colors.white),
      ),
      body: FutureBuilder<List<SubAccount>>(
        future: getSubAccounts(),
        builder: (context, snapshot) {
          if (snapshot.hasError) {
            return Center(child: Text('Lỗi: ${snapshot.error}'));
          }
          if (snapshot.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator());
          }
          final accounts = snapshot.data ?? [];
          return SingleChildScrollView(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                ElevatedButton(
                  onPressed: addSubAccount,
                  style: ElevatedButton.styleFrom(backgroundColor: Colors.blue),
                  child: const Text('Thêm Tài Khoản Phụ', style: TextStyle(color: Colors.white)),
                ),
                const SizedBox(height: 16),
                ListView.builder(
                  shrinkWrap: true,
                  physics: const NeverScrollableScrollPhysics(),
                  itemCount: accounts.length,
                  itemBuilder: (context, index) {
                    final account = accounts[index];
                    final isAdmin = account.username.toLowerCase() == 'admin';
                    final displayPermissions = isAdmin
                        ? availablePermissions.map((p) => p['display']!).toList()
                        : account.permissions.map((perm) {
                            final permission = availablePermissions.firstWhere(
                              (p) => p['value'] == perm,
                              orElse: () => {'value': perm, 'display': perm},
                            );
                            return permission['display']!;
                          }).toList();

                    return Card(
                      margin: const EdgeInsets.symmetric(vertical: 8),
                      child: Padding(
                        padding: const EdgeInsets.all(12),
                        child: Row(
                          children: [
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    'Tên: ${account.username}',
                                    style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                                  ),
                                  const SizedBox(height: 4),
                                  Text(
                                    'Quyền: ${displayPermissions.isEmpty ? 'Không có' : displayPermissions.join(', ')}',
                                    style: const TextStyle(fontSize: 14),
                                  ),
                                ],
                              ),
                            ),
                            Column(
                              children: [
                                IconButton(
                                  icon: const Icon(Icons.edit, color: Colors.blue),
                                  onPressed: () => editSubAccount(account),
                                ),
                                IconButton(
                                  icon: const Icon(Icons.delete, color: Colors.red),
                                  onPressed: isAdmin ? null : () => deleteSubAccount(account.id, account.username),
                                ),
                              ],
                            ),
                          ],
                        ),
                      ),
                    );
                  },
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}

class AddSubAccountDialog extends StatefulWidget {
  final List<Map<String, String>> availablePermissions;
  final Future<void> Function(String username, String password, List<String> permissions) onSave;

  const AddSubAccountDialog({
    super.key,
    required this.availablePermissions,
    required this.onSave,
  });

  @override
  _AddSubAccountDialogState createState() => _AddSubAccountDialogState();
}

class _AddSubAccountDialogState extends State<AddSubAccountDialog> {
  final usernameController = TextEditingController();
  final passwordController = TextEditingController();
  final selectedPermissions = <String>{};

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Thêm Tài Khoản Phụ'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: usernameController,
              decoration: const InputDecoration(labelText: 'Tên tài khoản'),
            ),
            TextField(
              controller: passwordController,
              decoration: const InputDecoration(labelText: 'Mật khẩu'),
              obscureText: true,
            ),
            const SizedBox(height: 16),
            const Text('Quyền:', style: TextStyle(fontWeight: FontWeight.bold)),
            ...widget.availablePermissions.map((permission) => CheckboxListTile(
                  title: Text(permission['display']!),
                  value: selectedPermissions.contains(permission['value']),
                  onChanged: (value) {
                    setState(() {
                      if (value == true) {
                        selectedPermissions.add(permission['value']!);
                      } else {
                        selectedPermissions.remove(permission['value']);
                      }
                    });
                  },
                )),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Hủy'),
        ),
        TextButton(
          onPressed: () async {
            await widget.onSave(
              usernameController.text.trim(),
              passwordController.text.trim(),
              selectedPermissions.toList(),
            );
            Navigator.pop(context);
          },
          child: const Text('Lưu'),
        ),
      ],
    );
  }
}

class EditSubAccountDialog extends StatefulWidget {
  final SubAccount account;
  final List<Map<String, String>> availablePermissions;
  final bool isAdmin;
  final Future<void> Function(String username, String password, List<String> permissions) onSave;

  const EditSubAccountDialog({
    super.key,
    required this.account,
    required this.availablePermissions,
    required this.isAdmin,
    required this.onSave,
  });

  @override
  _EditSubAccountDialogState createState() => _EditSubAccountDialogState();
}

class _EditSubAccountDialogState extends State<EditSubAccountDialog> {
  final usernameController = TextEditingController();
  final passwordController = TextEditingController();
  final selectedPermissions = <String>{};

  @override
  void initState() {
    super.initState();
    usernameController.text = widget.account.username;
    selectedPermissions.addAll(widget.account.permissions);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.isAdmin ? 'Sửa Mật Khẩu Admin' : 'Sửa Tài Khoản Phụ'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (!widget.isAdmin)
              TextField(
                controller: usernameController,
                decoration: const InputDecoration(labelText: 'Tên tài khoản'),
              ),
            TextField(
              controller: passwordController,
              decoration: const InputDecoration(labelText: 'Mật khẩu mới (để trống nếu không đổi)'),
              obscureText: true,
            ),
            if (!widget.isAdmin) ...[
              const SizedBox(height: 16),
              const Text('Quyền:', style: TextStyle(fontWeight: FontWeight.bold)),
              ...widget.availablePermissions.map((permission) => CheckboxListTile(
                    title: Text(permission['display']!),
                    value: selectedPermissions.contains(permission['value']),
                    onChanged: (value) {
                      setState(() {
                        if (value == true) {
                          selectedPermissions.add(permission['value']!);
                        } else {
                          selectedPermissions.remove(permission['value']);
                        }
                      });
                    },
                  )),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Hủy'),
        ),
        TextButton(
          onPressed: () async {
            await widget.onSave(
              usernameController.text.trim(),
              passwordController.text.trim(),
              selectedPermissions.toList(),
            );
            Navigator.pop(context);
          },
          child: const Text('Lưu'),
        ),
      ],
    );
  }
}