import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:intl/intl.dart';
import 'package:url_launcher/url_launcher.dart';
import '../helpers/cache_helper.dart';

// Cache manager cho CRM
class CRMCacheManager {
  static final CRMCacheManager _instance = CRMCacheManager._internal();
  factory CRMCacheManager() => _instance;
  CRMCacheManager._internal();

  // Cache cho products
  List<Map<String, dynamic>>? _cachedProducts;
  DateTime? _productsLastFetched;
  
  // Cache cho customers và dữ liệu liên quan
  List<Map<String, dynamic>>? _cachedCustomers;
  DateTime? _customersLastFetched;
  Map<String, List<Map<String, dynamic>>>? _cachedCustomerTransactions;
  
  // Thời gian cache hết hạn (5 phút cho products, 2 phút cho customers)
  static const Duration productsExpiration = Duration(minutes: 5);
  static const Duration customersExpiration = Duration(minutes: 2);

  bool get hasValidProductsCache {
    if (_cachedProducts == null || _productsLastFetched == null) return false;
    return DateTime.now().difference(_productsLastFetched!) < productsExpiration;
  }

  bool get hasValidCustomersCache {
    if (_cachedCustomers == null || _customersLastFetched == null) return false;
    return DateTime.now().difference(_customersLastFetched!) < customersExpiration;
  }

  void cacheProducts(List<Map<String, dynamic>> products) {
    _cachedProducts = products;
    _productsLastFetched = DateTime.now();
  }

  void cacheCustomers(List<Map<String, dynamic>> customers) {
    _cachedCustomers = customers;
    _customersLastFetched = DateTime.now();
  }

  List<Map<String, dynamic>>? getCachedProducts() {
    if (!hasValidProductsCache) return null;
    return _cachedProducts;
  }

  List<Map<String, dynamic>>? getCachedCustomers() {
    if (!hasValidCustomersCache) return null;
    return _cachedCustomers;
  }

  void clearCache() {
    _cachedProducts = null;
    _productsLastFetched = null;
    _cachedCustomers = null;
    _customersLastFetched = null;
    _cachedCustomerTransactions = null;
  }

  // Cache cho giao dịch của từng khách hàng
  void cacheCustomerTransactions(String customerName, List<Map<String, dynamic>> transactions) {
    _cachedCustomerTransactions ??= {};
    _cachedCustomerTransactions![customerName] = transactions;
  }

  List<Map<String, dynamic>>? getCachedCustomerTransactions(String customerName) {
    return _cachedCustomerTransactions?[customerName];
  }
}

class CRMScreen extends StatefulWidget {
  final List<String> permissions;
  final SupabaseClient tenantClient;

  const CRMScreen({super.key, required this.permissions, required this.tenantClient});

  @override
  _CRMScreenState createState() => _CRMScreenState();
}

class _CRMScreenState extends State<CRMScreen> {
  final _crmCache = CRMCacheManager();

  DateTime? startDate;
  DateTime? endDate;
  String? productIdFilter; // Changed to store product_id
  String? productNameFilter; // For display in TextField
  String? searchQuery;
  String selectedFilter = 'Không lọc';
  List<String> filterOptions = [
    'Không lọc',
    'Số lượng mua nhiều tới ít',
    'Số lượng mua ít tới nhiều',
    'Thời gian mua gần nhất',
    'Thời gian mua xa nhất',
    'Sinh nhật hôm nay',
  ];
  List<Map<String, dynamic>> customers = [];
  List<Map<String, dynamic>> filteredCustomers = [];
  List<bool> selectedCustomers = [];
  bool selectAll = false;
  bool isLoading = false;

  // Danh sách sản phẩm từ bảng products_name
  List<Map<String, dynamic>> products = []; // Store both id and name

  final TextEditingController nameController = TextEditingController();
  final TextEditingController phoneController = TextEditingController();
  final TextEditingController socialLinkController = TextEditingController();
  final TextEditingController addressController = TextEditingController();
  final TextEditingController noteController = TextEditingController();
  final TextEditingController productFilterController = TextEditingController();
  final TextEditingController messageController = TextEditingController();
  final TextEditingController searchController = TextEditingController();

  @override
  void initState() {
    super.initState();
    if (widget.permissions.contains('access_crm_screen')) {
      fetchProducts();
      fetchCustomers();
    }
  }

  @override
  void dispose() {
    nameController.dispose();
    phoneController.dispose();
    socialLinkController.dispose();
    addressController.dispose();
    noteController.dispose();
    productFilterController.dispose();
    messageController.dispose();
    searchController.dispose();
    super.dispose();
  }

  Future<void> fetchProducts() async {
    try {
      // Kiểm tra cache trước
      final cachedProducts = _crmCache.getCachedProducts();
      if (cachedProducts != null) {
        setState(() {
          products = cachedProducts;
        });
        return;
      }

      final response = await widget.tenantClient.from('products_name').select('id, products');
      final productsList = response
          .map<Map<String, dynamic>>((product) => {
                'id': product['id'].toString(),
                'name': product['products'] as String,
              })
          .toList();

      // Lưu vào cache và cập nhật state
      _crmCache.cacheProducts(productsList);
      setState(() {
        products = productsList;
      });
    } catch (e) {
      print('Error fetching products: $e');
      await showDialog(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Lỗi'),
          content: Text('Lỗi khi tải danh sách sản phẩm: $e'),
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

  Future<void> fetchCustomers() async {
    setState(() {
      isLoading = true;
    });

    try {
      // Kiểm tra cache trước
      final cachedCustomers = _crmCache.getCachedCustomers();
      if (cachedCustomers != null && !_shouldRefreshData()) {
        setState(() {
          customers = cachedCustomers;
          filteredCustomers = List.from(customers);
          applyFilter();
          selectedCustomers = List<bool>.filled(filteredCustomers.length, false);
          selectAll = false;
          isLoading = false;
        });
        return;
      }

      // Query sale_orders trước để lấy tất cả khách hàng đã mua sản phẩm
      // ✅ Sử dụng customer_id làm khóa chính thay vì tên khách hàng
      var saleQuery = widget.tenantClient
          .from('sale_orders')
          .select('customer_id, product_id, quantity, created_at')
          .eq('iscancelled', false);

      if (startDate != null) {
        saleQuery = saleQuery.gte('created_at', startDate!.toIso8601String());
      }
      if (endDate != null) {
        saleQuery = saleQuery.lte('created_at', endDate!.toIso8601String());
      }
      if (productIdFilter != null && productIdFilter!.isNotEmpty) {
        saleQuery = saleQuery.eq('product_id', productIdFilter!);
      }

      final saleResponse = await saleQuery;

      // ✅ Nếu có productIdFilter, tạo customerList từ sale_orders trước
      List<Map<String, dynamic>> customerList = [];
      
      if (productIdFilter != null && productIdFilter!.isNotEmpty) {
        // ✅ Nhóm khách hàng từ sale_orders theo customer_id (khóa chính)
        final Map<String, Map<String, dynamic>> customerMap = {};
        
        for (var order in saleResponse) {
          final customerId = order['customer_id']?.toString();
          final quantity = order['quantity'] as int? ?? 0;
          final purchaseDate = order['created_at'] != null ? DateTime.parse(order['created_at']) : null;

          if (customerId == null || customerId.isEmpty || purchaseDate == null) continue;

          if (!customerMap.containsKey(customerId)) {
            customerMap[customerId] = {
              'id': customerId,
              'name': '',
              'phone': '',
              'note': '',
              'birthday': '',
              'total_quantity': 0,
              'latest_purchase': purchaseDate,
            };
          }

          customerMap[customerId]!['total_quantity'] = 
              (customerMap[customerId]!['total_quantity'] as int) + quantity;
          
          final currentLatest = customerMap[customerId]!['latest_purchase'] as DateTime;
          if (purchaseDate.isAfter(currentLatest)) {
            customerMap[customerId]!['latest_purchase'] = purchaseDate;
          }
        }

        customerList = customerMap.values.toList();

        // ✅ Bổ sung thông tin từ bảng customers bằng customer_id
        if (customerList.isNotEmpty) {
          final customerIds = customerList.map((c) => c['id'] as String).toList();
          try {
            final customerResponse = await widget.tenantClient
                .from('customers')
                .select('id, name, phone, note, birthday')
                .inFilter('id', customerIds);

            final customerInfoMap = <String, Map<String, dynamic>>{};
            for (var customer in customerResponse) {
              final id = customer['id']?.toString() ?? '';
              if (id.isNotEmpty) {
                customerInfoMap[id] = {
                  'name': customer['name']?.toString() ?? '',
                  'phone': customer['phone']?.toString() ?? '',
                  'note': customer['note']?.toString() ?? '',
                  'birthday': customer['birthday']?.toString() ?? '',
                };
              }
            }

            // Cập nhật thông tin cho từng khách hàng
            for (var customer in customerList) {
              final id = customer['id'] as String;
              if (customerInfoMap.containsKey(id)) {
                customer['name'] = customerInfoMap[id]!['name'];
                customer['phone'] = customerInfoMap[id]!['phone'];
                customer['note'] = customerInfoMap[id]!['note'];
                customer['birthday'] = customerInfoMap[id]!['birthday'];
              }
            }
          } catch (e) {
            print('Error fetching customer details: $e');
            // Tiếp tục với thông tin từ sale_orders nếu lỗi
          }
        }
      } else {
        // ✅ Không có productIdFilter, lấy từ bảng customers như cũ
        final customerResponse = await widget.tenantClient
            .from('customers')
            .select('id, name, phone, note, birthday');

        customerList = customerResponse.map((customer) {
          return {
            'id': customer['id']?.toString() ?? '',
            'name': customer['name']?.toString() ?? '',
            'phone': customer['phone']?.toString() ?? '',
            'note': customer['note']?.toString() ?? '',
            'birthday': customer['birthday']?.toString() ?? '',
            'total_quantity': 0,
            'latest_purchase': null,
          };
        }).toList();

        // ✅ Cập nhật total_quantity từ sale_orders bằng customer_id
        for (var order in saleResponse) {
          final customerId = order['customer_id']?.toString();
          final quantity = order['quantity'] as int? ?? 0;
          final purchaseDate = order['created_at'] != null ? DateTime.parse(order['created_at']) : null;

          if (customerId == null || purchaseDate == null) continue;

          final customerIndex = customerList.indexWhere((c) => c['id'] == customerId);
          if (customerIndex != -1) {
            customerList[customerIndex]['total_quantity'] += quantity;
            if (customerList[customerIndex]['latest_purchase'] == null ||
                purchaseDate.isAfter(customerList[customerIndex]['latest_purchase'])) {
              customerList[customerIndex]['latest_purchase'] = purchaseDate;
            }
          }
        }
      }

      // Lưu vào cache nếu không có filter
      if (startDate == null && endDate == null && (productIdFilter == null || productIdFilter!.isEmpty)) {
        _crmCache.cacheCustomers(customerList);
      }

      setState(() {
        customers = customerList;
        filteredCustomers = List.from(customers);
        applyFilter();
        selectedCustomers = List<bool>.filled(filteredCustomers.length, false);
        selectAll = false;
        isLoading = false;
      });
    } catch (e) {
      print('Error fetching customers: $e');
      setState(() {
        isLoading = false;
      });
      await showDialog(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Lỗi'),
          content: Text('Lỗi khi tải dữ liệu: $e'),
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

  void applyFilter() {
    List<Map<String, dynamic>> tempCustomers = List.from(customers);

    if (selectedFilter == 'Số lượng mua nhiều tới ít') {
      tempCustomers.sort((a, b) => b['total_quantity'].compareTo(a['total_quantity']));
    } else if (selectedFilter == 'Số lượng mua ít tới nhiều') {
      tempCustomers.sort((a, b) => a['total_quantity'].compareTo(b['total_quantity']));
    } else if (selectedFilter == 'Thời gian mua gần nhất') {
      tempCustomers.sort((a, b) {
        final dateA = a['latest_purchase'] as DateTime?;
        final dateB = b['latest_purchase'] as DateTime?;
        if (dateA == null && dateB == null) return 0;
        if (dateA == null) return 1;
        if (dateB == null) return -1;
        return dateB.compareTo(dateA);
      });
    } else if (selectedFilter == 'Thời gian mua xa nhất') {
      tempCustomers.sort((a, b) {
        final dateA = a['latest_purchase'] as DateTime?;
        final dateB = b['latest_purchase'] as DateTime?;
        if (dateA == null && dateB == null) return 0;
        if (dateA == null) return 1;
        if (dateB == null) return -1;
        return dateA.compareTo(dateB);
      });
    } else if (selectedFilter == 'Sinh nhật hôm nay') {
      final today = DateTime.now();
      final todayFormat = '${today.day.toString().padLeft(2, '0')}-${today.month.toString().padLeft(2, '0')}';
      tempCustomers = tempCustomers.where((customer) {
        final birthday = customer['birthday'] as String?;
        return birthday != null && birthday == todayFormat;
      }).toList();
    }

    setState(() {
      filteredCustomers = tempCustomers;
      selectedCustomers = List<bool>.filled(filteredCustomers.length, false);
      selectAll = false;
    });

    if (searchQuery != null && searchQuery!.isNotEmpty) {
      searchCustomers(searchQuery!);
    }
  }

  void searchCustomers(String query) {
    setState(() {
      searchQuery = query;
      if (query.isEmpty) {
        filteredCustomers = List.from(customers);
        applyFilter();
      } else {
        filteredCustomers = customers.where((customer) {
          final name = customer['name']?.toLowerCase() ?? '';
          final phone = customer['phone']?.toLowerCase() ?? '';
          final note = customer['note']?.toLowerCase() ?? '';
          final searchLower = query.toLowerCase();
          return name.contains(searchLower) || phone.contains(searchLower) || note.contains(searchLower);
        }).toList();
      }
      selectedCustomers = List<bool>.filled(filteredCustomers.length, false);
      selectAll = false;
    });
  }

  Future<void> _selectDate(BuildContext context, bool isStart) async {
    final DateTime? picked = await showDatePicker(
      context: context,
      initialDate: DateTime.now(),
      firstDate: DateTime(2000),
      lastDate: DateTime.now(),
    );
    if (picked != null) {
      setState(() {
        if (isStart) {
          startDate = picked;
        } else {
          endDate = picked;
        }
      });
      await fetchCustomers();
    }
  }

  Future<List<String>> _getSelectedCustomerPhones() async {
    List<String> selectedCustomerNames = [];
    for (int i = 0; i < filteredCustomers.length; i++) {
      if (selectedCustomers[i]) {
        selectedCustomerNames.add(filteredCustomers[i]['name']);
      }
    }

    if (selectedCustomerNames.isEmpty) {
      return [];
    }

    final response = await widget.tenantClient
        .from('customers')
        .select('phone')
        .inFilter('name', selectedCustomerNames);

    return response
        .map((customer) => (customer['phone'] as String?)?.trim())
        .where((phone) => phone != null && phone.isNotEmpty)
        .cast<String>()
        .toList();
  }

  Future<void> _sendSMS(List<String> phones, String message) async {
    if (phones.isEmpty) {
      await showDialog(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Lỗi'),
          content: const Text('Không tìm thấy số điện thoại để gửi SMS!'),
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
      final smsUri = Uri(
        scheme: 'sms',
        path: phones.join(';'),
        queryParameters: {'body': message},
      );

      if (await canLaunchUrl(smsUri)) {
        await launchUrl(
          smsUri,
          mode: LaunchMode.externalApplication,
        );
      } else {
        await showDialog(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('Lỗi'),
            content: const Text(
              'Không thể mở ứng dụng SMS. Vui lòng kiểm tra xem thiết bị có hỗ trợ gửi SMS không hoặc cài đặt ứng dụng nhắn tin mặc định.',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('Đóng'),
              ),
            ],
          ),
        );
      }
    } catch (e) {
      await showDialog(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Lỗi'),
          content: Text('Lỗi khi mở ứng dụng SMS: $e'),
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


  void addCustomerDialog() {
    String day = '';
    String month = '';
    String? birthdayError;

    showDialog(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text('Thêm Khách Hàng'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: nameController,
                  decoration: const InputDecoration(labelText: 'Tên khách hàng'),
                ),
                TextField(
                  controller: phoneController,
                  decoration: const InputDecoration(labelText: 'Số điện thoại'),
                  keyboardType: TextInputType.phone,
                ),
                TextField(
                  controller: socialLinkController,
                  decoration: const InputDecoration(labelText: 'Link mạng xã hội'),
                ),
                TextField(
                  controller: addressController,
                  decoration: const InputDecoration(labelText: 'Địa chỉ'),
                ),
                TextField(
                  controller: noteController,
                  decoration: const InputDecoration(labelText: 'Ghi chú'),
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
              onPressed: () {
                Navigator.pop(context);
                nameController.clear();
                phoneController.clear();
                socialLinkController.clear();
                addressController.clear();
                noteController.clear();
              },
              child: const Text('Hủy'),
            ),
            ElevatedButton(
              onPressed: () async {
                if (nameController.text.isEmpty) {
                  await showDialog(
                    context: context,
                    builder: (context) => AlertDialog(
                      title: const Text('Lỗi'),
                      content: const Text('Tên khách hàng không được để trống!'),
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
                  final insertResponse = await widget.tenantClient.from('customers').insert({
                    'name': nameController.text,
                    'phone': phoneController.text,
                    'social_link': socialLinkController.text,
                    'address': addressController.text,
                    'note': noteController.text,
                    'debt_vnd': 0,
                    'debt_cny': 0,
                    'debt_usd': 0,
                    if (birthday != null) 'birthday': birthday,
                  }).select('id, name').single();
                  
                  // ✅ Cache customer ngay sau khi tạo
                  final newCustomerId = insertResponse['id'].toString();
                  final newCustomerName = insertResponse['name'] as String;
                  CacheHelper.cacheCustomer(newCustomerId, newCustomerName);

                  Navigator.pop(context);
                  await showDialog(
                    context: context,
                    builder: (context) => AlertDialog(
                      title: const Text('Thành công'),
                      content: const Text('Đã thêm khách hàng thành công'),
                      actions: [
                        TextButton(
                          onPressed: () => Navigator.pop(context),
                          child: const Text('Đóng'),
                        ),
                      ],
                    ),
                  );

                  nameController.clear();
                  phoneController.clear();
                  socialLinkController.clear();
                  addressController.clear();
                  noteController.clear();
                  await fetchCustomers();
                } catch (e) {
                  await showDialog(
                    context: context,
                    builder: (context) => AlertDialog(
                      title: const Text('Lỗi'),
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
              },
              child: const Text('Lưu'),
            ),
          ],
        ),
      ),
    );
  }

  void sendMessageDialog() {
    List<String> selectedCustomerNames = [];
    for (int i = 0; i < filteredCustomers.length; i++) {
      if (selectedCustomers[i]) {
        selectedCustomerNames.add(filteredCustomers[i]['name']);
      }
    }

    if (selectedCustomerNames.isEmpty) {
      showDialog(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Thông báo'),
          content: const Text('Vui lòng chọn ít nhất một khách hàng để gửi tin nhắn!'),
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

    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Gửi Tin Nhắn'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Gửi tới: ${selectedCustomerNames.join(', ')}'),
              const SizedBox(height: 16),
              TextField(
                controller: messageController,
                decoration: const InputDecoration(labelText: 'Nội dung tin nhắn'),
                maxLines: 3,
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () {
              Navigator.pop(context);
              messageController.clear();
            },
            child: const Text('Hủy'),
          ),
          ElevatedButton(
            onPressed: () async {
              if (messageController.text.isEmpty) {
                await showDialog(
                  context: context,
                  builder: (context) => AlertDialog(
                    title: const Text('Lỗi'),
                    content: const Text('Nội dung tin nhắn không được để trống!'),
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

              final phones = await _getSelectedCustomerPhones();
              Navigator.pop(context);
              await _sendSMS(phones, messageController.text);
              messageController.clear();
            },
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.blue,
              foregroundColor: Colors.white,
            ),
            child: const Text('Gửi tin nhắn'),
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
    if (!widget.permissions.contains('access_crm_screen')) {
      return const Scaffold(
        body: Center(
          child: Text('Bạn không có quyền truy cập màn hình này'),
        ),
      );
    }

    return Scaffold(
      appBar: AppBar(
        title: const Text('Quản lý khách hàng', style: TextStyle(color: Colors.white)),
        backgroundColor: Colors.black,
        iconTheme: const IconThemeData(color: Colors.white),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: refreshData,
            tooltip: 'Làm mới dữ liệu',
          ),
        ],
      ),
      body: isLoading
          ? const Center(child: CircularProgressIndicator())
          : RefreshIndicator(
              onRefresh: refreshData,
              child: Column(
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                    children: [
                      ElevatedButton(
                        onPressed: () => _selectDate(context, true),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: Colors.blue,
                          foregroundColor: Colors.white,
                        ),
                        child: Text(
                          startDate == null
                              ? 'Từ ngày'
                              : DateFormat('dd/MM/yyyy').format(startDate!),
                        ),
                      ),
                      ElevatedButton(
                        onPressed: () => _selectDate(context, false),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: Colors.blue,
                          foregroundColor: Colors.white,
                        ),
                        child: Text(
                          endDate == null
                              ? 'Đến ngày'
                              : DateFormat('dd/MM/yyyy').format(endDate!),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  wrapField(
                    Autocomplete<String>(
                      optionsBuilder: (TextEditingValue textEditingValue) {
                        final query = textEditingValue.text.toLowerCase();
                        if (query.isEmpty) {
                          return products.map((p) => p['name'] as String).take(3);
                        }
                        var filtered = products
                            .where((p) => (p['name'] as String).toLowerCase().contains(query))
                            .map((p) => p['name'] as String)
                            .toList();
                        filtered.sort((a, b) => a.toLowerCase().indexOf(query).compareTo(b.toLowerCase().indexOf(query)));
                        return filtered.take(3);
                      },
                      onSelected: (String selection) {
                        final selectedProduct = products.firstWhere((p) => p['name'] == selection);
                        setState(() {
                          productIdFilter = selectedProduct['id'];
                          productNameFilter = selection;
                          productFilterController.text = selection;
                        });
                        fetchCustomers();
                      },
                      fieldViewBuilder: (context, controller, focusNode, onFieldSubmitted) {
                        controller.text = productFilterController.text;
                        return TextField(
                          controller: productFilterController,
                          focusNode: focusNode,
                          onChanged: (value) {
                            if (value.isEmpty) {
                              setState(() {
                                productIdFilter = null;
                                productNameFilter = null;
                              });
                              fetchCustomers();
                            } else {
                              setState(() {
                                productNameFilter = value;
                                if (!products.any((p) => p['name'] == value)) {
                                  productIdFilter = null;
                                }
                              });
                            }
                          },
                          onEditingComplete: () {
                            onFieldSubmitted();
                            if (productNameFilter != null && productNameFilter!.isNotEmpty) {
                              final selectedProduct = products.firstWhere(
                                (p) => p['name'] == productNameFilter,
                                orElse: () => {'id': '', 'name': ''},
                              );
                              setState(() {
                                productIdFilter = selectedProduct['id'] != '' ? selectedProduct['id'] : null;
                              });
                              fetchCustomers();
                            } else {
                              setState(() {
                                productIdFilter = null;
                              });
                              fetchCustomers();
                            }
                          },
                          decoration: InputDecoration(
                            labelText: 'Tên sản phẩm',
                            border: InputBorder.none,
                            isDense: true,
                            suffixIcon: productFilterController.text.isNotEmpty
                                ? IconButton(
                                    icon: const Icon(Icons.clear),
                                    onPressed: () {
                                      setState(() {
                                        productFilterController.clear();
                                        productIdFilter = null;
                                        productNameFilter = null;
                                      });
                                      fetchCustomers();
                                    },
                                  )
                                : null,
                          ),
                        );
                      },
                    ),
                  ),
                  const SizedBox(height: 8),
                  wrapField(
                    TextField(
                      controller: searchController,
                      decoration: const InputDecoration(
                        labelText: 'Tìm kiếm (Tên, SĐT, Ghi chú)',
                        border: InputBorder.none,
                        isDense: true,
                      ),
                      onChanged: searchCustomers,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      ElevatedButton(
                        onPressed: addCustomerDialog,
                        style: ElevatedButton.styleFrom(
                          backgroundColor: Colors.green,
                          foregroundColor: Colors.white,
                        ),
                        child: const Text('Thêm Khách Hàng'),
                      ),
                      ElevatedButton(
                        onPressed: sendMessageDialog,
                        style: ElevatedButton.styleFrom(
                          backgroundColor: Colors.orange,
                          foregroundColor: Colors.white,
                        ),
                        child: const Text('Gửi Tin Nhắn'),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      Row(
                        children: [
                          Checkbox(
                            value: selectAll,
                            onChanged: (val) {
                              setState(() {
                                selectAll = val ?? false;
                                selectedCustomers = List<bool>.filled(filteredCustomers.length, selectAll);
                              });
                            },
                          ),
                          const Text('Chọn tất cả'),
                        ],
                      ),
                      const SizedBox(width: 16),
                      Expanded(
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
                          decoration: BoxDecoration(
                            color: Colors.grey.shade200,
                            borderRadius: BorderRadius.circular(8),
                            border: Border.all(
                              color: Colors.grey.shade700,
                              width: 0.5,
                            ),
                          ),
                          child: DropdownButtonFormField<String>(
                            value: selectedFilter,
                            items: filterOptions
                                .map((option) => DropdownMenuItem(
                                      value: option,
                                      child: Text(option),
                                    ))
                                .toList(),
                            onChanged: (value) {
                              setState(() {
                                selectedFilter = value!;
                                applyFilter();
                              });
                            },
                            decoration: const InputDecoration(
                              labelText: 'Lọc',
                              border: InputBorder.none,
                              isDense: true,
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                  Expanded(
                    child: ListView.builder(
                      itemCount: filteredCustomers.length,
                      itemBuilder: (context, index) {
                        final customer = filteredCustomers[index];
                        return Card(
                          elevation: 2,
                          margin: const EdgeInsets.symmetric(vertical: 4),
                          child: Padding(
                            padding: const EdgeInsets.all(8),
                            child: Row(
                              children: [
                                Checkbox(
                                  value: selectedCustomers[index],
                                  onChanged: (val) {
                                    setState(() {
                                      selectedCustomers[index] = val ?? false;
                                      selectAll = selectedCustomers.every((element) => element);
                                    });
                                  },
                                ),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        customer['name'],
                                        style: const TextStyle(
                                          fontWeight: FontWeight.bold,
                                          fontSize: 16,
                                        ),
                                      ),
                                      Text('SĐT: ${customer['phone']}'),
                                      Text('Số sản phẩm đã mua: ${customer['total_quantity']}'),
                                      if (customer['birthday'] != null && customer['birthday'].isNotEmpty)
                                        Text('Sinh nhật: ${customer['birthday']}'),
                                    ],
                                  ),
                                ),
                              ],
                            ),
                          ),
                        );
                      },
                    ),
                  ),
                ],
              ),
            ),
    );
  }

  // Kiểm tra xem có cần refresh data không
  bool _shouldRefreshData() {
    return startDate != null || 
           endDate != null || 
           (productIdFilter != null && productIdFilter!.isNotEmpty);
  }

  // Thêm phương thức refresh để người dùng có thể làm mới dữ liệu
  Future<void> refreshData() async {
    _crmCache.clearCache();
    await fetchProducts();
    await fetchCustomers();
  }
}