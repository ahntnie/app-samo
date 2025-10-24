import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:collection/collection.dart';
import 'package:intl/intl.dart';
import 'transactions/forms/sale_form.dart' show CacheUtil, SaleForm;
import './notification_service.dart';

class Order {
  final int id;
  final String customer;
  final String productId;
  final String productName;
  final int quantity;
  final int importQuantity;
  final double price;
  final double customerPrice;
  final double transporterPrice;
  final DateTime createdAt;
  final String status;

  Order({
    required this.id,
    required this.customer,
    required this.productId,
    required this.productName,
    required this.quantity,
    required this.importQuantity,
    required this.price,
    required this.customerPrice,
    required this.transporterPrice,
    required this.createdAt,
    required this.status,
  });

  factory Order.fromMap(Map<String, dynamic> map) {
    return Order(
      id: map['id'] as int,
      customer: map['customers'] ?? '',
      productId: map['product_id'] as String? ?? '',
      productName: map['product_name'] as String? ?? map['products'] as String? ?? '',
      quantity: map['quantity'] as int? ?? 0,
      importQuantity: map['import_quantity'] as int? ?? 0,
      price: (map['price'] as num?)?.toDouble() ?? 0.0,
      customerPrice: (map['customer_price'] as num?)?.toDouble() ?? 0.0,
      transporterPrice: (map['transporter_price'] as num?)?.toDouble() ?? 0.0,
      createdAt: DateTime.parse(map['created_at'] ?? DateTime.now().toIso8601String()),
      status: map['status'] ?? 'Tiếp Nhận',
    );
  }
}

class OrdersScreen extends StatefulWidget {
  final List<String> permissions;
  final SupabaseClient tenantClient;

  const OrdersScreen({
    super.key,
    required this.permissions,
    required this.tenantClient,
  });

  @override
  _OrdersScreenState createState() => _OrdersScreenState();
}

class _OrdersScreenState extends State<OrdersScreen> with SingleTickerProviderStateMixin {
  late TabController _tabController;
  String? customer;
  String? customerId;
  String? categoryName;
  int? categoryId;
  String? productId;
  String? productName;
  int quantity = 1;
  double price = 0.0;
  double customerPrice = 0.0;
  double transporterPrice = 0.0;
  Map<String, dynamic>? selectedCustomerData;
  List<Map<String, dynamic>> customers = [];
  List<Map<String, dynamic>> categories = [];
  List<Map<String, dynamic>> products = [];
  List<Order> orders = [];
  String selectedSortOption = 'Không sắp xếp';
  List<String> sortOptions = ['Không sắp xếp', 'Đặt hàng xa nhất', 'Đặt hàng mới nhất'];
  String selectedStatusFilter = 'Tất cả';
  List<String> statusFilterOptions = ['Tất cả', 'Đã hoàn thành', 'Chưa hoàn thành', 'Đã Hủy'];
  bool isLoading = true;
  String? errorMessage;
  final int pageSize = 30;
  int currentPage = 0;
  bool hasMore = true;
  bool isLoadingMore = false;
  
  final TextEditingController priceController = TextEditingController();
  final TextEditingController customerPriceController = TextEditingController();
  final NumberFormat numberFormat = NumberFormat('#,###', 'vi_VN');

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this);
    _fetchInitialData();
  }

  @override
  void dispose() {
    _tabController.dispose();
    priceController.dispose();
    customerPriceController.dispose();
    super.dispose();
  }

  String _formatNumber(double value) {
    if (value == 0) return '';
    return numberFormat.format(value.toInt());
  }

  double _parseFormattedNumber(String text) {
    if (text.isEmpty) return 0.0;
    final cleaned = text.replaceAll('.', '').replaceAll(',', '');
    return double.tryParse(cleaned) ?? 0.0;
  }

  Future<void> _fetchInitialData() async {
    setState(() {
      isLoading = true;
      errorMessage = null;
      currentPage = 0;
      hasMore = true;
      orders = [];
    });

    try {
      final customerResponse = await widget.tenantClient.from('customers').select('id, name, phone, address');
      final customerList = customerResponse
          .map((e) => {
                'id': e['id']?.toString(),
                'name': e['name'] as String?,
                'phone': e['phone'] as String?,
                'address': e['address'] as String?,
              })
          .where((e) => e['name'] != null)
          .cast<Map<String, dynamic>>()
          .toList();

      final categoryResponse = await widget.tenantClient.from('categories').select('id, name');
      final categoryList = categoryResponse
          .map((e) => {
                'id': e['id'] as int,
                'name': e['name'] as String,
              })
          .toList();

      final productResponse = await widget.tenantClient.from('products_name').select('id, products');
      final productList = productResponse
          .map((e) => {
                'id': e['id'] as String,
                'name': e['products'] as String,
              })
          .toList();

      await _loadMoreOrders(customerList, productList);

      setState(() {
        customers = customerList;
        categories = categoryList;
        products = productList;
        isLoading = false;
        for (var product in productList) {
          CacheUtil.productNameCache[product['id'] as String] = product['name'] as String;
        }
      });
    } catch (e) {
      setState(() {
        errorMessage = 'Không thể tải dữ liệu: $e';
        isLoading = false;
      });
    }
  }

  Future<void> _loadMoreOrders([List<Map<String, dynamic>>? customerList, List<Map<String, dynamic>>? productList]) async {
    if (!hasMore || isLoadingMore) return;

    setState(() {
      isLoadingMore = true;
    });

    try {
      final start = currentPage * pageSize;
      final end = start + pageSize - 1;

      final orderResponse = await widget.tenantClient
          .from('orders')
          .select('id, customers, product_id, product_name, quantity, import_quantity, price, customer_price, transporter_price, created_at, status')
          .order('created_at', ascending: false)
          .range(start, end);

      final newOrders = orderResponse.map((map) => Order.fromMap(map)).toList();

      if (newOrders.isEmpty) {
        setState(() {
          hasMore = false;
          isLoadingMore = false;
        });
        return;
      }

      if (customerList != null && productList != null) {
        final missingCustomers = newOrders
            .where((order) => !customerList.any((c) => c['name'] == order.customer))
            .map((order) => order.customer)
            .toSet();

        final missingProducts = newOrders
            .where((order) => order.productId.isNotEmpty && !productList.any((p) => p['id'] == order.productId))
            .map((order) => order.productName)
            .toSet();

        if (missingCustomers.isNotEmpty) {
          print('Cảnh báo: Các khách hàng sau không tồn tại trong bảng customers: $missingCustomers');
        }
        if (missingProducts.isNotEmpty) {
          print('Cảnh báo: Các sản phẩm sau không tồn tại trong bảng products_name: $missingProducts');
        }
      }

      setState(() {
        orders.addAll(newOrders);
        orders.sort((a, b) => b.createdAt.compareTo(a.createdAt));
        currentPage++;
        isLoadingMore = false;
      });
    } catch (e) {
      setState(() {
        errorMessage = 'Không thể tải thêm dữ liệu: $e';
        isLoadingMore = false;
      });
    }
  }

  void addCustomerDialog() async {
    String name = '';
    String phone = '';
    String address = '';
    String socialLink = '';
    String day = '';
    String month = '';
    String? birthdayError;

    await showDialog(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text('Thêm Khách Hàng'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  decoration: const InputDecoration(labelText: 'Tên'),
                  onChanged: (val) => name = val,
                ),
                TextField(
                  decoration: const InputDecoration(labelText: 'Số điện thoại'),
                  onChanged: (val) => phone = val,
                ),
                TextField(
                  decoration: const InputDecoration(labelText: 'Địa chỉ'),
                  onChanged: (val) => address = val,
                ),
                TextField(
                  decoration: const InputDecoration(labelText: 'Link mạng xã hội'),
                  onChanged: (val) => socialLink = val,
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        decoration: const InputDecoration(
                          labelText: 'Ngày sinh (1-31)',
                          hintText: 'VD: 15',
                        ),
                        keyboardType: TextInputType.number,
                        onChanged: (val) {
                          day = val;
                          final dayInt = int.tryParse(day);
                          if (dayInt == null || dayInt < 1 || dayInt > 31) {
                            setDialogState(() {
                              birthdayError = 'Ngày phải từ 1 đến 31';
                            });
                          } else {
                            setDialogState(() {
                              birthdayError = null;
                            });
                          }
                        },
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: TextField(
                        decoration: const InputDecoration(
                          labelText: 'Tháng sinh (1-12)',
                          hintText: 'VD: 3',
                        ),
                        keyboardType: TextInputType.number,
                        onChanged: (val) {
                          month = val;
                          final monthInt = int.tryParse(month);
                          if (monthInt == null || monthInt < 1 || monthInt > 12) {
                            setDialogState(() {
                              birthdayError = 'Tháng phải từ 1 đến 12';
                            });
                          } else {
                            setDialogState(() {
                              birthdayError = null;
                            });
                          }
                        },
                      ),
                    ),
                  ],
                ),
                if (birthdayError != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 8.0),
                    child: Text(
                      birthdayError!,
                      style: const TextStyle(color: Colors.red, fontSize: 12),
                    ),
                  ),
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
                  final dayInt = int.tryParse(day);
                  final monthInt = int.tryParse(month);
                  String? birthday;
                  if (dayInt != null && monthInt != null) {
                    if (dayInt < 1 || dayInt > 31 || monthInt < 1 || monthInt > 12) {
                      return;
                    }
                    birthday = '${dayInt.toString().padLeft(2, '0')}-${monthInt.toString().padLeft(2, '0')}';
                  }

                  try {
                    await widget.tenantClient.from('customers').insert({
                      'name': name,
                      'phone': phone,
                      'address': address,
                      'social_link': socialLink,
                      'debt_vnd': 0,
                      'debt_cny': 0,
                      'debt_usd': 0,
                      if (birthday != null) 'birthday': birthday,
                    });
                    // Get the newly created customer id
                    final newCustomerResponse = await widget.tenantClient
                        .from('customers')
                        .select('id')
                        .eq('name', name)
                        .single();
                    final newCustomerId = newCustomerResponse['id']?.toString();
                    setState(() {
                      customers.add({
                        'id': newCustomerId,
                        'name': name,
                        'phone': phone,
                        'address': address,
                      });
                      customer = name;
                      customerId = newCustomerId;
                      selectedCustomerData = {
                        'id': newCustomerId,
                        'name': name,
                        'phone': phone,
                        'address': address,
                      };
                    });
                    Navigator.pop(context);
                  } catch (e) {
                    await showDialog(
                      context: context,
                      builder: (context) => AlertDialog(
                        title: const Text('Thông báo'),
                        content: Text('Lỗi khi thêm khách hàng: $e'),
                        actions: [
                          TextButton(
                            onPressed: () => Navigator.pop(context),
                            child: const Text('Đóng'),
                          ),
                        ],
                      ),
                    );
                  }
                } else {
                  await showDialog(
                    context: context,
                    builder: (context) => AlertDialog(
                      title: const Text('Thông báo'),
                      content: const Text('Tên khách hàng không được để trống!'),
                      actions: [
                        TextButton(
                          onPressed: () => Navigator.pop(context),
                          child: const Text('Đóng'),
                        ),
                      ],
                    ),
                  );
                }
              },
              child: const Text('Lưu'),
            ),
          ],
        ),
      ),
    );
  }

  void editCustomerDialog(Map<String, dynamic> customerData) async {
    String name = customerData['name'] as String;
    String phone = customerData['phone'] as String? ?? '';
    String address = customerData['address'] as String? ?? '';

    await showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Sửa Thông Tin Khách Hàng'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                decoration: const InputDecoration(labelText: 'Tên'),
                controller: TextEditingController(text: name),
                onChanged: (val) => name = val,
              ),
              TextField(
                decoration: const InputDecoration(labelText: 'Số điện thoại'),
                controller: TextEditingController(text: phone),
                onChanged: (val) => phone = val,
              ),
              TextField(
                decoration: const InputDecoration(labelText: 'Địa chỉ'),
                controller: TextEditingController(text: address),
                onChanged: (val) => address = val,
              ),
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
                  await widget.tenantClient
                      .from('customers')
                      .update({
                        'name': name,
                        'phone': phone,
                        'address': address,
                      })
                      .eq('name', customerData['name']);

                  setState(() {
                    final customerIndex = customers.indexWhere((c) => c['name'] == customerData['name']);
                    if (customerIndex != -1) {
                      customers[customerIndex] = {
                        'name': name,
                        'phone': phone,
                        'address': address,
                      };
                    }
                    if (customer == customerData['name']) {
                      customer = name;
                      selectedCustomerData = {
                        'id': customerData['id'],
                        'name': name,
                        'phone': phone,
                        'address': address,
                      };
                    }
                  });
                  Navigator.pop(context);
                } catch (e) {
                  await showDialog(
                    context: context,
                    builder: (context) => AlertDialog(
                      title: const Text('Thông báo'),
                      content: Text('Lỗi khi cập nhật thông tin khách hàng: $e'),
                      actions: [
                        TextButton(
                          onPressed: () => Navigator.pop(context),
                          child: const Text('Đóng'),
                        ),
                      ],
                    ),
                  );
                }
              } else {
                await showDialog(
                  context: context,
                  builder: (context) => AlertDialog(
                    title: const Text('Thông báo'),
                    content: const Text('Tên khách hàng không được để trống!'),
                    actions: [
                      TextButton(
                        onPressed: () => Navigator.pop(context),
                        child: const Text('Đóng'),
                      ),
                    ],
                  ),
                );
              }
            },
            child: const Text('Cập nhật'),
          ),
        ],
      ),
    );
  }

  void addCategoryDialog() async {
    String name = '';
    await showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Thêm chủng loại sản phẩm'),
        content: TextField(
          decoration: const InputDecoration(labelText: 'Tên chủng loại'),
          onChanged: (val) => name = val,
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
                  final response = await widget.tenantClient
                      .from('categories')
                      .insert({'name': name})
                      .select('id, name')
                      .single();

                  final newCategory = {
                    'id': response['id'] as int,
                    'name': response['name'] as String,
                  };

                  setState(() {
                    categories.add(newCategory);
                    categoryId = newCategory['id'] as int;
                    categoryName = newCategory['name'] as String;
                  });
                  Navigator.pop(context);
                } catch (e) {
                  await showDialog(
                    context: context,
                    builder: (context) => AlertDialog(
                      title: const Text('Thông báo'),
                      content: Text('Lỗi khi thêm chủng loại: $e'),
                      actions: [
                        TextButton(
                          onPressed: () => Navigator.pop(context),
                          child: const Text('Đóng'),
                        ),
                      ],
                    ),
                  );
                }
              } else {
                await showDialog(
                  context: context,
                  builder: (context) => AlertDialog(
                    title: const Text('Thông báo'),
                    content: const Text('Tên chủng loại không được để trống!'),
                    actions: [
                      TextButton(
                        onPressed: () => Navigator.pop(context),
                        child: const Text('Đóng'),
                      ),
                    ],
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

  void addProductDialog() async {
    String name = '';
    await showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Thêm sản phẩm'),
        content: TextField(
          decoration: const InputDecoration(labelText: 'Tên sản phẩm'),
          onChanged: (val) => name = val,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Hủy'),
          ),
          ElevatedButton(
            onPressed: () async {
              if (name.isEmpty) {
                await showDialog(
                  context: context,
                  builder: (context) => AlertDialog(
                    title: const Text('Thông báo'),
                    content: const Text('Tên sản phẩm không được để trống!'),
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
              if (categoryId == null) {
                await showDialog(
                  context: context,
                  builder: (context) => AlertDialog(
                    title: const Text('Thông báo'),
                    content: const Text('Vui lòng chọn chủng loại sản phẩm trước!'),
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
              try {
                final response = await widget.tenantClient
                    .from('products_name')
                    .insert({'products': name})
                    .select('id, products')
                    .single();
                setState(() {
                  products.add({
                    'id': response['id'] as String,
                    'name': name,
                  });
                  productId = response['id'] as String;
                  productName = name;
                });
                CacheUtil.productNameCache[response['id'] as String] = name;
                Navigator.pop(context);
                await showDialog(
                  context: context,
                  builder: (context) => AlertDialog(
                    title: const Text('Thông báo'),
                    content: const Text('Đã thêm sản phẩm thành công'),
                    actions: [
                      TextButton(
                        onPressed: () => Navigator.pop(context),
                        child: const Text('Đóng'),
                      ),
                    ],
                  ),
                );
              } catch (e) {
                await showDialog(
                  context: context,
                  builder: (context) => AlertDialog(
                    title: const Text('Thông báo'),
                    content: Text('Lỗi khi thêm sản phẩm: $e'),
                    actions: [
                      TextButton(
                        onPressed: () => Navigator.pop(context),
                        child: const Text('Đóng'),
                      ),
                    ],
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

  Future<void> showConfirmDialog(BuildContext scaffoldContext) async {
    if (customer == null || categoryId == null || productId == null || quantity <= 0 || price <= 0) {
      showDialog(
        context: scaffoldContext,
        builder: (context) => AlertDialog(
          title: const Text('Thông báo'),
          content: const Text('Vui lòng điền đầy đủ thông tin!'),
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

    final selectedCustomer = customers.firstWhere((c) => c['name'] == customer);
    final now = DateTime.now();

    showDialog(
      context: scaffoldContext,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Xác nhận đơn đặt hàng'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Khách hàng: $customer'),
              Text('Số điện thoại: ${selectedCustomer['phone'] ?? ''}'),
              Text('Chủng loại: $categoryName'),
              Text('Sản phẩm: $productName'),
              Text('Số lượng: $quantity'),
              Text('Giá tiền: $price'),
              Text('Số tiền cọc: $customerPrice'),
              Text('Tiền COD: $transporterPrice'),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('Sửa lại'),
          ),
          ElevatedButton(
            onPressed: () async {
              try {
                final response = await widget.tenantClient.from('orders').insert({
                  'customer_id': customerId,
                  'customers': customer,
                  'product_id': productId,
                  'product_name': productName,
                  'quantity': quantity,
                  'price': price,
                  'customer_price': customerPrice,
                  'transporter_price': transporterPrice,
                  'created_at': now.toIso8601String(),
                  'status': 'Tiếp Nhận',
                  'import_quantity': 0,
                }).select('id, customers, product_id, product_name, quantity, import_quantity, price, customer_price, transporter_price, created_at, status').single();

                setState(() {
                  orders.add(Order(
                    id: response['id'] as int,
                    customer: customer!,
                    productId: productId!,
                    productName: productName!,
                    quantity: quantity,
                    importQuantity: 0,
                    price: price,
                    customerPrice: customerPrice,
                    transporterPrice: transporterPrice,
                    createdAt: now,
                    status: 'Tiếp Nhận',
                  ));
                });

                await NotificationService.showNotification(
                  140,
                  'Đơn Order Mới',
                  'Có đơn order mới cho sản phẩm "$productName" số lượng $quantity',
                  'order_created',
                );

                ScaffoldMessenger.of(scaffoldContext).showSnackBar(
                  SnackBar(
                    content: Text(
                      'Có đơn order mới cho sản phẩm "$productName" số lượng $quantity',
                      style: const TextStyle(color: Colors.white),
                    ),
                    backgroundColor: Colors.black,
                    behavior: SnackBarBehavior.floating,
                    margin: const EdgeInsets.all(8),
                    duration: const Duration(seconds: 3),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                  ),
                );

                setState(() {
                  customer = null;
                  categoryId = null;
                  categoryName = null;
                  productId = null;
                  productName = null;
                  quantity = 1;
                  price = 0.0;
                  customerPrice = 0.0;
                  transporterPrice = 0.0;
                  selectedCustomerData = null;
                  priceController.clear();
                  customerPriceController.clear();
                });

                Navigator.pop(dialogContext);
              } catch (e) {
                Navigator.pop(dialogContext);
                await showDialog(
                  context: scaffoldContext,
                  builder: (context) => AlertDialog(
                    title: const Text('Thông báo'),
                    content: Text('Lỗi khi tạo đơn đặt hàng: $e'),
                    actions: [
                      TextButton(
                        onPressed: () => Navigator.pop(context),
                        child: const Text('Đóng'),
                      ),
                    ],
                  ),
                );
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
        color: Colors.grey.shade100,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: Colors.grey.shade300),
      ),
      child: child,
    );
  }

  int _calculateDaysSinceOrder(DateTime createdAt) {
    final currentDate = DateTime.now();
    return currentDate.difference(createdAt).inDays.abs();
  }

  Future<void> _changeOrderStatus(Order order) async {
    String? newStatus = order.status;
    int? newQuantity;
    int? newImportQuantity;
    bool isSentStatus = false;
    final scaffoldContext = context;

    await showDialog(
      context: scaffoldContext,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text('Chuyển Trạng Thái'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                DropdownButtonFormField<String>(
                  value: newStatus,
                  items: _statusList.map((status) => DropdownMenuItem(
                    value: status,
                    child: Text(status),
                  )).toList(),
                  onChanged: (val) {
                    setDialogState(() {
                      newStatus = val;
                      isSentStatus = (newStatus == 'Gửi Hàng');
                    });
                  },
                  decoration: const InputDecoration(
                    labelText: 'Trạng thái mới',
                    border: OutlineInputBorder(),
                  ),
                ),
                if (newStatus == 'Chốt Order' || order.status == 'Chốt Order') ...[
                  const SizedBox(height: 16),
                  TextField(
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(
                      labelText: 'Số lượng mới',
                      border: OutlineInputBorder(),
                    ),
                    onChanged: (val) {
                      newQuantity = int.tryParse(val) ?? order.quantity;
                    },
                    controller: TextEditingController(text: order.quantity.toString()),
                  ),
                ],
                if (newStatus == 'Đã Nhập Hàng' || newStatus == 'Liên Hệ Giao' || newStatus == 'Gửi Hàng' ||
                    order.status == 'Đã Nhập Hàng' || order.status == 'Liên Hệ Giao' || order.status == 'Gửi Hàng') ...[
                  const SizedBox(height: 16),
                  TextField(
                    keyboardType: TextInputType.number,
                    decoration: InputDecoration(
                      labelText: newStatus == 'Gửi Hàng' || order.status == 'Gửi Hàng' ? 'Số lượng gửi' : 'Số lượng đã nhập',
                      border: const OutlineInputBorder(),
                    ),
                    onChanged: (val) {
                      newImportQuantity = int.tryParse(val) ?? order.importQuantity;
                    },
                    controller: TextEditingController(text: order.importQuantity.toString()),
                  ),
                ],
                if (isSentStatus) ...[
                  const SizedBox(height: 16),
                  const Text(
                    'Đơn hàng đã chuyển sang trạng thái Gửi Hàng. Bạn có muốn tạo phiếu bán hàng không?',
                    style: TextStyle(fontSize: 14, color: Colors.black54),
                  ),
                ],
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: Text(isSentStatus ? 'Đóng' : 'Hủy'),
            ),
            if (!isSentStatus)
              TextButton(
                onPressed: () async {
                  if (newStatus != null) {
                    try {
                      final updateData = <String, dynamic>{
                        'status': newStatus,
                      };
                      if (newQuantity != null && newStatus == 'Chốt Order') {
                        updateData['quantity'] = newQuantity;
                      }
                      if (newImportQuantity != null &&
                          (newStatus == 'Đã Nhập Hàng' || newStatus == 'Liên Hệ Giao' || newStatus == 'Gửi Hàng')) {
                        updateData['import_quantity'] = newImportQuantity;
                      }

                      await widget.tenantClient
                          .from('orders')
                          .update(updateData)
                          .eq('id', order.id);

                      setState(() {
                        final index = orders.indexWhere((o) => o.id == order.id);
                        if (index != -1) {
                          orders[index] = Order(
                            id: order.id,
                            customer: order.customer,
                            productId: order.productId,
                            productName: order.productName,
                            quantity: newQuantity ?? order.quantity,
                            importQuantity: newImportQuantity ?? order.importQuantity,
                            price: order.price,
                            customerPrice: order.customerPrice,
                            transporterPrice: order.transporterPrice,
                            createdAt: order.createdAt,
                            status: newStatus!,
                          );
                        } else {
                          _fetchInitialData();
                        }
                      });

                      setDialogState(() {
                        isSentStatus = (newStatus == 'Gửi Hàng');
                      });

                      ScaffoldMessenger.of(scaffoldContext).showSnackBar(
                        const SnackBar(content: Text('Đã cập nhật trạng thái thành công')),
                      );

                      if (!isSentStatus) {
                        Navigator.pop(context);
                      }
                    } catch (e) {
                      Navigator.pop(context);
                      ScaffoldMessenger.of(scaffoldContext).showSnackBar(
                        SnackBar(content: Text('Lỗi khi cập nhật trạng thái: $e')),
                      );
                    }
                  }
                },
                child: const Text('Xác nhận'),
              ),
            if (isSentStatus)
              ElevatedButton(
                onPressed: () async {
                  try {
                    Navigator.pop(dialogContext);
                    Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (context) => SaleForm(
                          initialCustomer: order.customer,
                          initialProductId: order.productId.isNotEmpty ? order.productId : null,
                          initialProductName: order.productName,
                          initialPrice: order.price.toString(),
                          tenantClient: widget.tenantClient,
                        ),
                      ),
                    );
                  } catch (e) {
                    Navigator.pop(dialogContext);
                    ScaffoldMessenger.of(scaffoldContext).showSnackBar(
                      SnackBar(content: Text('Lỗi khi tạo phiếu bán hàng: $e')),
                    );
                  }
                },
                child: const Text('Tạo Phiếu Bán Hàng'),
              ),
          ],
        ),
      ),
    );
  }

  Future<void> _cancelOrder(Order order) async {
    final confirmCancel = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Xác nhận hủy đơn hàng'),
        content: const Text('Bạn có xác nhận khách hàng đã hủy đơn hàng không?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Đóng'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Xác nhận', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );

    if (confirmCancel != true) return;

    try {
      await widget.tenantClient
          .from('orders')
          .update({'status': 'Đã Hủy'})
          .eq('id', order.id);

      setState(() {
        final index = orders.indexWhere((o) => o.id == order.id);
        if (index != -1) {
          orders[index] = Order(
            id: order.id,
            customer: order.customer,
            productId: order.productId,
            productName: order.productName,
            quantity: order.quantity,
            importQuantity: order.importQuantity,
            price: order.price,
            customerPrice: order.customerPrice,
            transporterPrice: order.transporterPrice,
            createdAt: order.createdAt,
            status: 'Đã Hủy',
          );
        } else {
          _fetchInitialData();
        }
      });

      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Đã hủy đơn hàng thành công')),
      );
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Lỗi khi hủy đơn hàng: $e')),
      );
    }
  }

  List<Order> get filteredOrders {
    var tempOrders = List<Order>.from(orders);

    if (selectedSortOption == 'Đặt hàng xa nhất') {
      tempOrders.sort((a, b) => a.createdAt.compareTo(b.createdAt));
    } else if (selectedSortOption == 'Đặt hàng mới nhất') {
      tempOrders.sort((a, b) => b.createdAt.compareTo(a.createdAt));
    }

    if (selectedStatusFilter == 'Đã hoàn thành') {
      tempOrders = tempOrders.where((order) => order.status == 'Đã Giao').toList();
    } else if (selectedStatusFilter == 'Chưa hoàn thành') {
      tempOrders = tempOrders.where((order) => order.status != 'Đã Giao' && order.status != 'Đã Hủy').toList();
    } else if (selectedStatusFilter == 'Đã Hủy') {
      tempOrders = tempOrders.where((order) => order.status == 'Đã Hủy').toList();
    }

    return tempOrders;
  }

  final List<String> _statusList = [
    'Tiếp Nhận',
    'Chốt Order',
    'Đã Nhập Hàng',
    'Chuyển Kho',
    'Liên Hệ Giao',
    'Gửi Hàng',
    'Đã Giao',
  ];

  @override
  Widget build(BuildContext context) {
    if (isLoading) {
      return const Scaffold(
        body: Center(child: CircularProgressIndicator()),
      );
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
                onPressed: _fetchInitialData,
                child: const Text('Thử lại'),
              ),
            ],
          ),
        ),
      );
    }

    return Scaffold(
      appBar: AppBar(
        title: const Text('Khách Đặt Hàng', style: TextStyle(color: Colors.white)),
        backgroundColor: Colors.black,
        iconTheme: const IconThemeData(color: Colors.white),
        bottom: TabBar(
          controller: _tabController,
          labelColor: Colors.yellow,
          unselectedLabelColor: Colors.grey,
          indicatorColor: Colors.yellow,
          tabs: const [
            Tab(text: 'Tạo Đơn Orders'),
            Tab(text: 'Đơn Orders'),
          ],
        ),
      ),
      body: TabBarView(
        controller: _tabController,
        children: [
          SingleChildScrollView(
            padding: const EdgeInsets.all(16),
            child: Column(
              children: [
                Row(
                  children: [
                    Expanded(
                      child: wrapField(
                        Autocomplete<String>(
                          optionsBuilder: (textEditingValue) {
                            final query = textEditingValue.text.toLowerCase();
                            return customers
                                .map((e) => e['name'] as String)
                                .where((e) => e.toLowerCase().contains(query))
                                .toList()
                              ..sort((a, b) => a.toLowerCase().indexOf(query).compareTo(b.toLowerCase().indexOf(query)))
                              ..take(3);
                          },
                          onSelected: (val) {
                          setState(() {
                            customer = val;
                            final customerData = customers.firstWhere((c) => c['name'] == val);
                            customerId = customerData['id'] as String?;
                            selectedCustomerData = customerData;
                          });
                          },
                          fieldViewBuilder: (context, controller, focusNode, onSubmit) {
                            return TextField(
                              controller: controller,
                              focusNode: focusNode,
                              decoration: const InputDecoration(
                                labelText: 'Khách hàng',
                                border: InputBorder.none,
                                isDense: true,
                              ),
                            );
                          },
                        ),
                      ),
                    ),
                    IconButton(
                      onPressed: addCustomerDialog,
                      icon: const Icon(Icons.add_circle_outline),
                    ),
                  ],
                ),
                if (selectedCustomerData != null)
                  Card(
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
                                  'Tên khách: ${selectedCustomerData!['name']}',
                                  style: const TextStyle(fontWeight: FontWeight.bold),
                                ),
                                SelectableText('Số điện thoại: ${selectedCustomerData!['phone'] ?? ''}'),
                                SelectableText('Địa chỉ: ${selectedCustomerData!['address'] ?? ''}'),
                              ],
                            ),
                          ),
                          IconButton(
                            icon: const Icon(Icons.edit, color: Colors.blue),
                            onPressed: () => editCustomerDialog(selectedCustomerData!),
                          ),
                        ],
                      ),
                    ),
                  ),
                Row(
                  children: [
                    Expanded(
                      child: wrapField(
                        DropdownButtonFormField<int>(
                          value: categoryId,
                          items: categories.map((e) => DropdownMenuItem<int>(
                            value: e['id'] as int,
                            child: Text(e['name'] as String),
                          )).toList(),
                          decoration: const InputDecoration(
                            labelText: 'Chủng loại sản phẩm',
                            border: InputBorder.none,
                            isDense: true,
                          ),
                          onChanged: (val) {
                            final selectedCategory = categories.firstWhere((e) => e['id'] == val);
                            setState(() {
                              categoryId = val;
                              categoryName = selectedCategory['name'] as String;
                            });
                          },
                        ),
                      ),
                    ),
                    IconButton(
                      onPressed: addCategoryDialog,
                      icon: const Icon(Icons.add_circle_outline),
                    ),
                  ],
                ),
                Row(
                  children: [
                    Expanded(
                      child: wrapField(
                        Autocomplete<Map<String, dynamic>>(
                          optionsBuilder: (textEditingValue) {
                            final query = textEditingValue.text.toLowerCase();
                            final filtered = products
                                .where((e) => (e['name'] as String).toLowerCase().contains(query))
                                .toList();
                            filtered.sort((a, b) => (a['name'] as String).toLowerCase().indexOf(query).compareTo((b['name'] as String).toLowerCase().indexOf(query)));
                            return filtered.take(3).toList();
                          },
                          displayStringForOption: (option) => option['name'] as String,
                          onSelected: (val) {
                            setState(() {
                              productId = val['id'] as String;
                              productName = val['name'] as String;
                            });
                          },
                          fieldViewBuilder: (context, controller, focusNode, onSubmit) {
                            return TextField(
                              controller: controller,
                              focusNode: focusNode,
                              decoration: const InputDecoration(
                                labelText: 'Sản phẩm',
                                border: InputBorder.none,
                                isDense: true,
                              ),
                            );
                          },
                        ),
                      ),
                    ),
                    IconButton(
                      onPressed: addProductDialog,
                      icon: const Icon(Icons.add_circle_outline),
                    ),
                  ],
                ),
                wrapField(
                  TextFormField(
                    keyboardType: TextInputType.number,
                    onChanged: (val) {
                      setState(() {
                        quantity = int.tryParse(val) ?? 1;
                      });
                    },
                    decoration: const InputDecoration(
                      labelText: 'Số lượng',
                      border: InputBorder.none,
                      isDense: true,
                    ),
                  ),
                ),
                wrapField(
                  TextFormField(
                    controller: priceController,
                    keyboardType: TextInputType.number,
                    onChanged: (val) {
                      final numericValue = _parseFormattedNumber(val);
                      setState(() {
                        price = numericValue;
                        transporterPrice = price - customerPrice;
                      });
                      
                      final formatted = _formatNumber(numericValue);
                      if (val != formatted) {
                        priceController.value = TextEditingValue(
                          text: formatted,
                          selection: TextSelection.collapsed(offset: formatted.length),
                        );
                      }
                    },
                    decoration: const InputDecoration(
                      labelText: 'Giá tiền',
                      border: InputBorder.none,
                      isDense: true,
                    ),
                  ),
                ),
                Row(
                  children: [
                    Expanded(
                      child: wrapField(
                        TextFormField(
                          controller: customerPriceController,
                          keyboardType: TextInputType.number,
                          onChanged: (val) {
                            final numericValue = _parseFormattedNumber(val);
                            setState(() {
                              customerPrice = numericValue;
                              transporterPrice = price - customerPrice;
                            });
                            
                            final formatted = _formatNumber(numericValue);
                            if (val != formatted) {
                              customerPriceController.value = TextEditingValue(
                                text: formatted,
                                selection: TextSelection.collapsed(offset: formatted.length),
                              );
                            }
                          },
                          decoration: const InputDecoration(
                            labelText: 'Số tiền cọc',
                            border: InputBorder.none,
                            isDense: true,
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: wrapField(
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            const Text(
                              'Tiền COD',
                              style: TextStyle(fontSize: 14, color: Colors.black54),
                            ),
                            Text(
                              _formatNumber(transporterPrice),
                              style: const TextStyle(fontSize: 14, color: Colors.black),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 20),
                ElevatedButton(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.blue,
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 24),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  ),
                  onPressed: () => showConfirmDialog(context),
                  child: const Text('Xác nhận'),
                ),
              ],
            ),
          ),
          Column(
            children: [
              Padding(
                padding: const EdgeInsets.all(12.0),
                child: Row(
                  children: [
                    Expanded(
                      child: DropdownButtonFormField<String>(
                        value: selectedSortOption,
                        items: sortOptions.map((option) => DropdownMenuItem(
                          value: option,
                          child: Text(option),
                        )).toList(),
                        onChanged: (value) => setState(() => selectedSortOption = value!),
                        decoration: const InputDecoration(
                          labelText: 'Sắp xếp',
                          border: OutlineInputBorder(),
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: DropdownButtonFormField<String>(
                        value: selectedStatusFilter,
                        items: statusFilterOptions.map((option) => DropdownMenuItem(
                          value: option,
                          child: Text(option),
                        )).toList(),
                        onChanged: (value) => setState(() => selectedStatusFilter = value!),
                        decoration: const InputDecoration(
                          labelText: 'Trạng thái',
                          border: OutlineInputBorder(),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              Expanded(
                child: NotificationListener<ScrollNotification>(
                  onNotification: (ScrollNotification scrollInfo) {
                    if (!isLoadingMore && hasMore && 
                        scrollInfo.metrics.pixels > scrollInfo.metrics.maxScrollExtent - 500) {
                      _loadMoreOrders();
                    }
                    return true;
                  },
                  child: ListView.builder(
                    padding: const EdgeInsets.all(16),
                    itemCount: filteredOrders.length + (hasMore ? 1 : 0),
                    itemBuilder: (context, index) {
                      if (index >= filteredOrders.length) {
                        return Container(
                          padding: const EdgeInsets.symmetric(vertical: 16),
                          alignment: Alignment.center,
                          child: const CircularProgressIndicator(),
                        );
                      }

                      final order = filteredOrders[index];
                      final customerData = customers.firstWhereOrNull((c) => c['name'] == order.customer);
                      final daysSinceOrder = _calculateDaysSinceOrder(order.createdAt);
                      final isDelivered = order.status == 'Đã Giao';
                      final isCancelled = order.status == 'Đã Hủy';
                      final showDaysColor = daysSinceOrder <= 8 && !isDelivered ? Colors.green : Colors.red;
                      final hasDeposit = order.customerPrice > 0 || order.transporterPrice > 0;
                      final depositInK = order.customerPrice / 1000;
                      final codInK = order.transporterPrice / 1000;

                      return Card(
                        margin: const EdgeInsets.symmetric(vertical: 8),
                        child: Padding(
                          padding: const EdgeInsets.all(12),
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      'Tên khách: ${order.customer}',
                                      style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
                                    ),
                                    const SizedBox(height: 4),
                                    SelectableText(
                                      'Số điện thoại: ${customerData?['phone'] ?? 'Không có thông tin'}',
                                      style: const TextStyle(fontSize: 14),
                                    ),
                                    const SizedBox(height: 4),
                                    SelectableText(
                                      'Địa chỉ: ${customerData?['address'] ?? 'Không có thông tin'}',
                                      style: const TextStyle(fontSize: 14),
                                    ),
                                  ],
                                ),
                              ),
                              Column(
                                crossAxisAlignment: CrossAxisAlignment.end,
                                children: [
                                  Text('Sản phẩm: ${order.productName}', style: const TextStyle(fontSize: 14)),
                                  const SizedBox(height: 4),
                                  Text(
                                    'Đặt ${order.quantity} / Có ${order.importQuantity}',
                                    style: const TextStyle(fontSize: 14),
                                  ),
                                  const SizedBox(height: 4),
                                  Text('Giá tiền: ${order.price}', style: const TextStyle(fontSize: 14)),
                                  if (hasDeposit)
                                    Text(
                                      'Cọc ${depositInK}k / COD ${codInK}k',
                                      style: const TextStyle(fontSize: 14),
                                    ),
                                  const SizedBox(height: 4),
                                  if (!isDelivered && !isCancelled)
                                    Text(
                                      'Thời gian đặt: $daysSinceOrder ngày',
                                      style: TextStyle(fontSize: 14, color: showDaysColor),
                                    ),
                                  const SizedBox(height: 4),
                                  Text('Trạng thái: ${order.status}', style: const TextStyle(fontSize: 14)),
                                  const SizedBox(height: 8),
                                  Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      if (!isCancelled)
                                        ElevatedButton(
                                          onPressed: () => _changeOrderStatus(order),
                                          style: ElevatedButton.styleFrom(
                                            backgroundColor: Colors.blue,
                                            foregroundColor: Colors.white,
                                            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                                            shape: RoundedRectangleBorder(
                                              borderRadius: BorderRadius.circular(8),
                                            ),
                                          ),
                                          child: const Text('Chuyển trạng thái', style: TextStyle(fontSize: 12)),
                                        ),
                                      const SizedBox(width: 8),
                                      if (!isCancelled)
                                        ElevatedButton(
                                          onPressed: () => _cancelOrder(order),
                                          style: ElevatedButton.styleFrom(
                                            backgroundColor: Colors.red,
                                            foregroundColor: Colors.white,
                                            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                                            shape: RoundedRectangleBorder(
                                              borderRadius: BorderRadius.circular(8),
                                            ),
                                          ),
                                          child: const Text('Hủy Order', style: TextStyle(fontSize: 12)),
                                        ),
                                    ],
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
              ),
            ],
          ),
        ],
      ),
    );
  }
}