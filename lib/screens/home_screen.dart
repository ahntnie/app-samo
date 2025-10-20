import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:bcrypt/bcrypt.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'transactions/transaction_screen.dart';
import 'inventory_screen.dart';
import 'overview_screen.dart';
import 'customers_screen.dart';
import 'suppliers_screen.dart';
import 'fixers_screen.dart';
import 'transporters_screen.dart';
import 'history_screen.dart';
import 'account_screen.dart';
import 'initial_data_screen.dart';
import 'crm_screen.dart';
import 'notification_service.dart';
import 'excel_report_screen.dart';
import 'orders_screen.dart';
import 'categories_screen.dart';
import 'package:firebase_core/firebase_core.dart';

class HomeScreen extends StatefulWidget {
  final SupabaseClient tenantClient;

  const HomeScreen({super.key, required this.tenantClient});

  @override
  _HomeScreenState createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final usernameController = TextEditingController();
  final passwordController = TextEditingController();
  bool isLoading = false;
  String? errorText;
  List<String> permissions = [];
  bool isSubAccountLoggedIn = false;
  String? loggedInUsername;
  bool isPasswordHidden = true;
  bool rememberMe = true;

  final List<String> allPermissions = [
    'admin',
    'access_import_form',
    'access_return_form',
    'access_sale_form',
    'access_fix_send_form',
    'access_fix_receive_form',
    'access_reimport_form',
    'access_transfer_local_form',
    'access_transfer_global_form',
    'access_transfer_receive_form',
    'access_transfer_fee_form',
    'access_warehouse_form',
    'access_payment_form',
    'access_receive_form',
    'access_income_other_form',
    'access_cost_form',
    'access_exchange_form',
    'access_transfer_fund_form',
    'access_financial_account_form',
    'access_customers_screen',
    'access_suppliers_screen',
    'access_transporters_screen',
    'access_fixers_screen',
    'access_history_screen',
    'view_import_price',
    'view_supplier',
    'view_sale_price',
    'view_customer',
    'create_transaction',
    'edit_transaction',
    'cancel_transaction',
    'manage_accounts',
    'view_company_value',
    'view_profit',
    'view_finance',
    'access_crm_screen',
    'access_excel_report',
    'access_orders_screen',
  ];

  @override
  void initState() {
    super.initState();
    _initializeNotifications();
    _loadSavedPreferences();
    _checkAutoLogin();
  }

  Future<void> _initializeNotifications() async {
    print('Initializing NotificationService...');
    await Firebase.initializeApp();
    await NotificationService.init(widget.tenantClient);
  }

  Future<void> _loadSavedPreferences() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() {
      isPasswordHidden = prefs.getBool('home_isPasswordHidden') ?? true;
      rememberMe = prefs.getBool('home_rememberPassword') ?? true;
      if (rememberMe) {
        usernameController.text = prefs.getString('home_username') ?? '';
        passwordController.text = prefs.getString('home_password') ?? '';
      }
    });
  }

  Future<void> _checkAutoLogin() async {
    final prefs = await SharedPreferences.getInstance();
    final savedUsername = prefs.getString('home_username');
    final savedPassword = prefs.getString('home_password');
    final rememberPassword = prefs.getBool('home_rememberPassword') ?? false;
    final hasDatabaseSession = prefs.getBool('has_database_session') ?? false;

    if (savedUsername != null && savedPassword != null && rememberPassword && hasDatabaseSession) {
      // Tự động đăng nhập tài khoản nhân sự
      usernameController.text = savedUsername;
      passwordController.text = savedPassword;
      await loginSubAccount();
    }
  }

  Future<void> _savePreferences() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('home_isPasswordHidden', isPasswordHidden);
    await prefs.setBool('home_rememberPassword', rememberMe);
    if (rememberMe) {
      await prefs.setString('home_username', usernameController.text.trim());
      await prefs.setString('home_password', passwordController.text.trim());
    } else {
      await prefs.remove('home_username');
      await prefs.remove('home_password');
    }
  }

  Future<void> loginSubAccount() async {
    setState(() {
      isLoading = true;
      errorText = null;
    });
    try {
      final response = await widget.tenantClient
          .from('sub_accounts')
          .select('id, username, password_hash, permissions')
          .eq('username', usernameController.text.trim())
          .maybeSingle();

      if (response == null) {
        setState(() {
          errorText = 'Tài khoản không tồn tại';
          isLoading = false;
        });
        return;
      }

      final passwordHash = response['password_hash'] as String;
      final isPasswordValid = BCrypt.checkpw(passwordController.text.trim(), passwordHash);
      if (!isPasswordValid) {
        setState(() {
          errorText = 'Mật khẩu không đúng';
          isLoading = false;
        });
        return;
      }

      await _savePreferences();
      // Đánh dấu có session cơ sở dữ liệu
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool('has_database_session', true);
      
      setState(() {
        loggedInUsername = response['username'].toString();
        var rawPermissions = response['permissions'] ?? [];
        permissions = (rawPermissions as List<dynamic>).map((perm) => perm.toString()).toList();
        print('Permissions set for user $loggedInUsername: $permissions');
        isSubAccountLoggedIn = true;
        isLoading = false;
      });
    } catch (e) {
      setState(() {
        errorText = 'Lỗi khi đăng nhập: $e';
        isLoading = false;
      });
    }
  }

  Future<void> _logoutSubAccount() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('has_database_session', false);
    await prefs.remove('home_username');
    await prefs.remove('home_password');
    await prefs.setBool('home_rememberPassword', false);
    
    setState(() {
      isSubAccountLoggedIn = false;
      loggedInUsername = null;
      permissions = [];
      usernameController.clear();
      passwordController.clear();
    });
  }

  Future<void> _logoutCompletely() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('has_database_session', false);
    await prefs.remove('home_username');
    await prefs.remove('home_password');
    await prefs.setBool('home_rememberPassword', false);
    await prefs.remove('tenant_url');
    await prefs.remove('tenant_anon_key');
    await prefs.remove('login_email');
    await prefs.remove('login_password');
    await prefs.setBool('login_rememberPassword', false);
    
    setState(() {
      isSubAccountLoggedIn = false;
      loggedInUsername = null;
      permissions = [];
      usernameController.clear();
      passwordController.clear();
    });
    
    // Quay về màn hình login chính
    Navigator.pushReplacementNamed(context, '/');
  }

  Widget _buildIconButton(
    BuildContext context,
    IconData icon,
    String label,
    VoidCallback? onTap,
    Color bgColor,
  ) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(24),
      child: Container(
        decoration: BoxDecoration(
          color: bgColor,
          borderRadius: BorderRadius.circular(24),
          boxShadow: [
            BoxShadow(
              color: bgColor.withOpacity(0.4),
              blurRadius: 10,
              offset: const Offset(0, 4),
            )
          ],
        ),
        padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 16),
        child: FittedBox(
          fit: BoxFit.scaleDown,
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Icon(icon, size: 28, color: Colors.white),
              const SizedBox(height: 4),
              Text(
                label,
                textAlign: TextAlign.center,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                    fontSize: 12, color: Colors.white, fontWeight: FontWeight.w600),
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (!isSubAccountLoggedIn) {
      return Scaffold(
        backgroundColor: const Color(0xFF121826),
        body: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    IconButton(
                      onPressed: () async {
                        await _logoutCompletely();
                      },
                      icon: const Icon(Icons.arrow_back, color: Colors.white),
                      tooltip: 'Thoát hoàn toàn',
                    ),
                    const Expanded(
                      child: Text(
                        'Làm Việc Chăm Chỉ Nhé',
                        textAlign: TextAlign.center,
                        style: TextStyle(fontSize: 28, fontWeight: FontWeight.bold, color: Colors.white),
                      ),
                    ),
                    const SizedBox(width: 48), // Để cân bằng với nút back
                  ],
                ),
                const SizedBox(height: 8),
                const Text(
                  'Tài Khoản Nhân Sự',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: Colors.white70),
                ),
                const SizedBox(height: 24),
                TextField(
                  controller: usernameController,
                  style: const TextStyle(color: Colors.white),
                  decoration: InputDecoration(
                    hintText: 'Tên tài khoản',
                    hintStyle: const TextStyle(color: Colors.white54),
                    filled: true,
                    fillColor: const Color(0xFF1E293B),
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none),
                  ),
                ),
                const SizedBox(height: 16),
                TextField(
                  controller: passwordController,
                  obscureText: isPasswordHidden,
                  style: const TextStyle(color: Colors.white),
                  decoration: InputDecoration(
                    hintText: 'Mật khẩu',
                    hintStyle: const TextStyle(color: Colors.white54),
                    filled: true,
                    fillColor: const Color(0xFF1E293B),
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none),
                  ),
                ),
                const SizedBox(height: 8),
                CheckboxListTile(
                  title: const Text('Ẩn mật khẩu', style: TextStyle(color: Colors.white)),
                  value: isPasswordHidden,
                  onChanged: (value) {
                    setState(() {
                      isPasswordHidden = value ?? true;
                    });
                    _savePreferences();
                  },
                  activeColor: Colors.blue,
                  checkColor: Colors.white,
                  controlAffinity: ListTileControlAffinity.leading,
                  contentPadding: EdgeInsets.zero,
                ),
                CheckboxListTile(
                  title: const Text('Nhớ mật khẩu', style: TextStyle(color: Colors.white)),
                  value: rememberMe,
                  onChanged: (value) {
                    setState(() {
                      rememberMe = value ?? true;
                    });
                    _savePreferences();
                  },
                  activeColor: Colors.blue,
                  checkColor: Colors.white,
                  controlAffinity: ListTileControlAffinity.leading,
                  contentPadding: EdgeInsets.zero,
                ),
                const SizedBox(height: 16),
                ElevatedButton(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF2563EB),
                    foregroundColor: Colors.white,
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                    padding: const EdgeInsets.symmetric(vertical: 16),
                  ),
                  onPressed: isLoading ? null : loginSubAccount,
                  child: isLoading
                      ? const CircularProgressIndicator(color: Colors.white)
                      : const Text('Đăng nhập', style: TextStyle(fontSize: 16, color: Colors.white)),
                ),
                if (errorText != null) ...[
                  const SizedBox(height: 12),
                  Text(errorText!, style: const TextStyle(color: Colors.redAccent), textAlign: TextAlign.center),
                ],
              ],
            ),
          ),
        ),
      );
    }

    return Scaffold(
      backgroundColor: const Color(0xFFF6F9FF),
      appBar: AppBar(
        title: const Text(
            'Home',
            style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
        backgroundColor: Colors.black,
        iconTheme: const IconThemeData(color: Colors.white),
        elevation: 4,
        actions: [
          PopupMenuButton<String>(
            icon: const Icon(Icons.more_vert, color: Colors.white),
            onSelected: (value) async {
              if (value == 'logout_subaccount') {
                await _logoutSubAccount();
              } else if (value == 'logout_complete') {
                await _logoutCompletely();
              }
            },
            itemBuilder: (context) => [
              const PopupMenuItem(
                value: 'logout_subaccount',
                child: Row(
                  children: [
                    Icon(Icons.logout, color: Colors.orange),
                    SizedBox(width: 8),
                    Text('Thoát tài khoản nhân sự'),
                  ],
                ),
              ),
              const PopupMenuItem(
                value: 'logout_complete',
                child: Row(
                  children: [
                    Icon(Icons.exit_to_app, color: Colors.red),
                    SizedBox(width: 8),
                    Text('Thoát hoàn toàn'),
                  ],
                ),
              ),
            ],
          ),
        ],
      ),
      body: Center(
        child: GridView.count(
          padding: const EdgeInsets.all(16),
          crossAxisCount: 3,
          crossAxisSpacing: 16,
          mainAxisSpacing: 16,
          childAspectRatio: 1.0,
          shrinkWrap: true,
          children: [
            _buildIconButton(context, Icons.dashboard, 'Tổng quan', () {
              Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => OverviewScreen(
                    permissions: permissions,
                    tenantClient: widget.tenantClient,
                  ),
                ),
              );
            }, Colors.deepPurple),
            _buildIconButton(context, Icons.swap_horiz, 'Giao dịch', () {
              Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => TransactionScreen(
                    permissions: permissions,
                    tenantClient: widget.tenantClient,
                  ),
                ),
              );
            }, Colors.orange),
            _buildIconButton(context, Icons.store, 'Kho', () {
              Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => InventoryScreen(
                    permissions: permissions,
                    tenantClient: widget.tenantClient,
                  ),
                ),
              );
            }, Colors.teal),
            if (permissions.contains('access_customers_screen'))
              _buildIconButton(context, Icons.people, 'Khách hàng', () {
                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => CustomersScreen(
                      permissions: permissions,
                      tenantClient: widget.tenantClient,
                    ),
                  ),
                );
              }, Colors.pink),
            if (permissions.contains('access_suppliers_screen'))
              _buildIconButton(context, Icons.business, 'Nhà cung cấp', () {
                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => SuppliersScreen(
                      permissions: permissions,
                      tenantClient: widget.tenantClient,
                    ),
                  ),
                );
              }, Colors.blue),
            if (permissions.contains('access_fixers_screen'))
              _buildIconButton(context, Icons.build, 'Đơn vị fix lỗi', () {
                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => FixersScreen(
                      permissions: permissions,
                      tenantClient: widget.tenantClient,
                    ),
                  ),
                );
              }, Colors.green),
            if (permissions.contains('access_transporters_screen'))
              _buildIconButton(context, Icons.local_shipping, 'Đơn vị\nvận chuyển', () {
                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => TransportersScreen(
                      permissions: permissions,
                      tenantClient: widget.tenantClient,
                    ),
                  ),
                );
              }, Colors.indigo),
            if (permissions.contains('access_crm_screen'))
              _buildIconButton(context, Icons.support_agent, 'CRM', () {
                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => CRMScreen(
                      permissions: permissions,
                      tenantClient: widget.tenantClient,
                    ),
                  ),
                );
              }, Colors.red),
            if (permissions.contains('access_orders_screen'))
              _buildIconButton(context, Icons.shopping_cart, 'Khách\nĐặt Hàng', () {
                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => OrdersScreen(
                      permissions: permissions,
                      tenantClient: widget.tenantClient,
                    ),
                  ),
                );
              }, Colors.purple),
            _buildIconButton(context, Icons.category, 'Danh mục', () {
              Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => CategoriesScreen(
                    permissions: permissions,
                    tenantClient: widget.tenantClient,
                  ),
                ),
              );
            }, Colors.blueGrey),
            _buildIconButton(context, Icons.history, 'Lịch sử phiếu', () {
              print('Navigating to HistoryScreen with permissions: $permissions');
              Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => HistoryScreen(
                    permissions: permissions,
                    tenantClient: widget.tenantClient,
                  ),
                ),
              );
            }, Colors.lime),
            if (loggedInUsername != null && loggedInUsername!.toLowerCase() == 'admin')
              _buildIconButton(context, Icons.input, 'Nhập đầu kỳ', () {
                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => InitialDataScreen(tenantClient: widget.tenantClient),
                  ),
                );
              }, Colors.brown),
            if (permissions.contains('access_excel_report'))
              _buildIconButton(context, Icons.file_copy, 'Nhập Xuất\nExcel', () {
                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => ExcelReportScreen(
                      permissions: permissions,
                      tenantClient: widget.tenantClient,
                    ),
                  ),
                );
              }, Colors.amber),
            if (permissions.contains('manage_accounts'))
              _buildIconButton(context, Icons.account_circle, 'Tài khoản', () {
                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => AccountScreen(tenantClient: widget.tenantClient),
                  ),
                );
              }, Colors.cyan),
          ],
        ),
      ),
    );
  }
}