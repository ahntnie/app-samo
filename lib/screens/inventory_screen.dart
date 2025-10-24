import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:excel/excel.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:open_file/open_file.dart';
import 'dart:io';
import 'dart:async';

// Cache utility class
class CacheUtil {
  static final Map<String, String> productNameCache = {};
  static final Map<String, String> warehouseNameCache = {};
  static final Map<String, String> supplierNameCache = {};
  static final Map<String, String> fixerNameCache = {};

  static void cacheProductName(String id, String name) => productNameCache[id] = name;
  static void cacheWarehouseName(String id, String name) => warehouseNameCache[id] = name;
  static void cacheSupplierName(String id, String name) => supplierNameCache[id] = name;
  static void cacheFixerName(String id, String name) => fixerNameCache[id] = name;
  static String getProductName(String? id) => id != null ? productNameCache[id] ?? 'Không xác định' : 'Không xác định';
  static String getWarehouseName(String? id) => id != null ? warehouseNameCache[id] ?? 'Không xác định' : 'Không xác định';
  static String getSupplierName(String? id) => id != null ? supplierNameCache[id] ?? 'Không xác định' : 'Không xác định';
  static String getFixerName(String? id) => id != null ? fixerNameCache[id] ?? 'Không xác định' : 'Không xác định';
}

class InventoryScreen extends StatefulWidget {
  final List<String> permissions;
  final SupabaseClient tenantClient;

  const InventoryScreen({super.key, required this.permissions, required this.tenantClient});

  @override
  State<InventoryScreen> createState() => _InventoryScreenState();
}

class _InventoryScreenState extends State<InventoryScreen> {
  final TextEditingController searchController = TextEditingController();
  String selectedFilter = 'Tất cả';
  List<String> filterOptions = ['Tất cả'];
  String? selectedWarehouse = 'Tất cả';
  List<String> warehouseOptions = ['Tất cả'];
  List<Map<String, dynamic>> inventoryData = [];
  List<Map<String, dynamic>> filteredInventoryData = [];
  bool isLoading = true;
  bool isLoadingMore = false;
  bool isSearching = false;
  String? errorMessage;
  bool isExporting = false;
  int pageSize = 20;
  int currentPage = 0;
  bool hasMoreData = true;
  final ScrollController _scrollController = ScrollController();
  Timer? _debounceTimer;

  Map<int, bool> isEditingNote = {};
  Map<int, TextEditingController> noteControllers = {};

  @override
  void initState() {
    super.initState();
    _fetchInventoryData();

    _scrollController.addListener(() {
      if (_scrollController.position.pixels >= _scrollController.position.maxScrollExtent - 200 &&
          !isLoadingMore &&
          hasMoreData &&
          searchController.text.isEmpty &&
          selectedFilter == 'Tất cả' &&
          selectedWarehouse == 'Tất cả') {
        _loadMoreData();
      }
    });

    searchController.addListener(_onSearchChanged);
  }

  void _onSearchChanged() {
    if (_debounceTimer?.isActive ?? false) {
      _debounceTimer!.cancel();
    }

    _debounceTimer = Timer(const Duration(milliseconds: 300), () {
      setState(() {
        filteredInventoryData = [];
        hasMoreData = false;
        isSearching = true;
      });
      _fetchFilteredData();
    });
  }

  @override
  void dispose() {
    _debounceTimer?.cancel();
    _scrollController.dispose();
    noteControllers.forEach((_, controller) => controller.dispose());
    searchController.dispose();
    super.dispose();
  }

  Future<void> _fetchInventoryData() async {
    setState(() {
      isLoading = true;
      errorMessage = null;
      inventoryData = [];
      filteredInventoryData = [];
      currentPage = 0;
      hasMoreData = true;
    });

    try {
      // Fetch product name cache
      final productResponse = await widget.tenantClient.from('products_name').select('id, products');
      for (var product in productResponse) {
        CacheUtil.cacheProductName(product['id'].toString(), product['products'] as String);
      }

      // Fetch warehouse name cache and update warehouse options
      final warehouseResponse = await widget.tenantClient.from('warehouses').select('id, name');
      List<String> warehouseNames = ['Tất cả'];
      for (var warehouse in warehouseResponse) {
        final id = warehouse['id'].toString();
        final name = warehouse['name'] as String;
        CacheUtil.cacheWarehouseName(id, name);
        warehouseNames.add(name);
      }
      
      // Fetch supplier name cache
      final supplierResponse = await widget.tenantClient.from('suppliers').select('id, name');
      for (var supplier in supplierResponse) {
        final id = supplier['id'].toString();
        final name = supplier['name'] as String;
        CacheUtil.cacheSupplierName(id, name);
      }
      
      // Fetch fixer name cache
      final fixerResponse = await widget.tenantClient.from('fix_units').select('id, name');
      for (var fixer in fixerResponse) {
        final id = fixer['id'].toString();
        final name = fixer['name'] as String;
        CacheUtil.cacheFixerName(id, name);
      }
      
      setState(() {
        warehouseOptions = warehouseNames;
      });

      await _loadMoreData();
    } catch (e) {
      setState(() {
        errorMessage = 'Không thể tải dữ liệu từ Supabase: $e';
        isLoading = false;
      });
    }
  }

  Future<void> _loadMoreData() async {
    if (!hasMoreData || isLoadingMore) return;

    setState(() {
      isLoadingMore = true;
    });

    try {
      final start = currentPage * pageSize;
      final end = start + pageSize - 1;

      final response = await widget.tenantClient
          .from('products')
          .select('id, product_id, imei, status, import_date, return_date, fix_price, send_fix_date, transport_fee, transporter, send_transfer_date, import_transfer_date, sale_price, customer_price, transporter_price, sale_date, saleman, note, import_price, import_currency, warehouse_id, customer, cost_price, supplier_id')
          .range(start, end);

      setState(() {
        List<Map<String, dynamic>> newData = response.cast<Map<String, dynamic>>();
        inventoryData.addAll(newData);
        filteredInventoryData = _filterInventory(inventoryData);

        if (newData.length < pageSize) {
          hasMoreData = false;
        }

        currentPage++;
        isLoading = false;
        isLoadingMore = false;
      });

      _updateFilterOptions();
    } catch (e) {
      setState(() {
        errorMessage = 'Không thể tải thêm dữ liệu: $e';
        isLoadingMore = false;
      });
    }
  }

  Future<void> _fetchFilteredData() async {
    if (searchController.text.isEmpty && selectedFilter == 'Tất cả' && selectedWarehouse == 'Tất cả') {
      if (inventoryData.isEmpty) {
        await _fetchInventoryData();
      } else {
        setState(() {
          filteredInventoryData = _filterInventory(inventoryData);
          hasMoreData = true;
          isSearching = false;
        });
      }
      return;
    }

    try {
      var query = widget.tenantClient
          .from('products')
          .select('id, product_id, imei, status, import_date, return_date, fix_price, send_fix_date, transport_fee, transporter, send_transfer_date, import_transfer_date, sale_price, customer_price, transporter_price, sale_date, saleman, note, import_price, import_currency, warehouse_id, customer, cost_price, supplier_id');

      final queryText = searchController.text.toLowerCase();
      
      // Tìm kiếm theo tên sản phẩm từ cache
      List<String> matchingProductIds = [];
      if (queryText.isNotEmpty) {
        // Tìm tất cả product_id có tên chứa queryText
        CacheUtil.productNameCache.forEach((id, name) {
          if (name.toLowerCase().contains(queryText)) {
            matchingProductIds.add(id);
          }
        });
      }

      if (queryText.isNotEmpty) {
        // Kết hợp tìm kiếm theo IMEI, note, hoặc product_id (từ tên sản phẩm)
        if (matchingProductIds.isNotEmpty) {
          // Nếu tìm thấy sản phẩm theo tên, thêm điều kiện tìm theo product_id
          final productIdConditions = matchingProductIds.map((id) => 'product_id.eq.$id').join(',');
          query = query.or('imei.ilike.%$queryText%,note.ilike.%$queryText%,$productIdConditions');
        } else {
          // Chỉ tìm theo IMEI và note nếu không tìm thấy tên sản phẩm
          query = query.or('imei.ilike.%$queryText%,note.ilike.%$queryText%');
        }
      }

      if (filterOptions.contains(selectedFilter) &&
          selectedFilter != 'Tất cả' &&
          selectedFilter != 'Tồn kho mới nhất' &&
          selectedFilter != 'Tồn kho lâu nhất') {
        query = query.eq('status', selectedFilter);
      }

      if (selectedWarehouse != 'Tất cả') {
        final warehouseId = CacheUtil.warehouseNameCache.entries
            .firstWhere((entry) => entry.value == selectedWarehouse, orElse: () => MapEntry('', ''))
            .key;
        if (warehouseId.isNotEmpty) {
          query = query.eq('warehouse_id', warehouseId);
        }
      }

      final response = await query;
      List<Map<String, dynamic>> allData = response.cast<Map<String, dynamic>>();

      setState(() {
        filteredInventoryData = _filterInventory(allData);
        isSearching = false;
      });

      _updateFilterOptions();
    } catch (e) {
      setState(() {
        errorMessage = 'Không thể tìm kiếm dữ liệu: $e';
        isSearching = false;
      });
    }
  }

  void _updateFilterOptions() {
    final uniqueStatuses = inventoryData
        .map((e) => e['status'] as String?)
        .where((e) => e != null && e.isNotEmpty)
        .cast<String>()
        .toSet()
        .toList();

    setState(() {
      filterOptions = [
        'Tất cả',
        ...uniqueStatuses,
        'Tồn kho mới nhất',
        'Tồn kho lâu nhất',
      ];
    });
  }

  List<Map<String, dynamic>> _filterInventory(List<Map<String, dynamic>> data) {
    var filtered = data.where((item) {
      if (item['product_id'] == null || item['imei'] == null) {
        return false;
      }
      return true;
    }).toList();

    if (selectedFilter == 'Tồn kho mới nhất') {
      filtered.sort((a, b) {
        final dateA = a['import_date'] != null ? DateTime.tryParse(a['import_date']) : null;
        final dateB = b['import_date'] != null ? DateTime.tryParse(b['import_date']) : null;
        if (dateA == null && dateB == null) return 0;
        if (dateA == null) return 1;
        if (dateB == null) return -1;
        return dateB.compareTo(dateA);
      });
    } else if (selectedFilter == 'Tồn kho lâu nhất') {
      filtered.sort((a, b) {
        final dateA = a['import_date'] != null ? DateTime.tryParse(a['import_date']) : null;
        final dateB = b['import_date'] != null ? DateTime.tryParse(b['import_date']) : null;
        if (dateA == null && dateB == null) return 0;
        if (dateA == null) return 1;
        if (dateB == null) return -1;
        return dateA.compareTo(dateB);
      });
    }

    return filtered;
  }

  List<Map<String, dynamic>> get filteredInventory {
    return filteredInventoryData;
  }

  int _calculateDaysInInventory(String? importDate) {
    if (importDate == null) return 0;
    final importDateParsed = DateTime.tryParse(importDate);
    if (importDateParsed == null) return 0;
    final currentDate = DateTime.now();
    return currentDate.difference(importDateParsed).inDays.abs();
  }

  Future<String?> _fetchCustomerFromSaleOrders(String productId, String imei) async {
    try {
      final productName = CacheUtil.getProductName(productId);
      final response = await widget.tenantClient
          .from('sale_orders')
          .select('customer, imei, product')
          .ilike('product', '%$productName%')
          .ilike('imei', '%$imei%')
          .maybeSingle();

      return response?['customer']?.toString();
    } catch (e) {
      return null;
    }
  }

  Future<String?> _fetchSupplierFromImportOrders(String productId, String imei) async {
    try {
      final productName = CacheUtil.getProductName(productId);
      final response = await widget.tenantClient
          .from('import_orders')
          .select('supplier, imei, product')
          .ilike('product', '%$productName%')
          .ilike('imei', '%$imei%')
          .maybeSingle();

      return response?['supplier']?.toString();
    } catch (e) {
      return null;
    }
  }

  Future<Map<String, String?>> _fetchCustomersForItems(List<Map<String, dynamic>> items) async {
    if (!widget.permissions.contains('view_customer')) return {};

    Map<String, String?> customerMap = {};
    const batchSize = 50;
    final batches = <List<Map<String, dynamic>>>[];
    for (var i = 0; i < items.length; i += batchSize) {
      batches.add(items.sublist(i, i + batchSize > items.length ? items.length : i + batchSize));
    }

    for (var batch in batches) {
      try {
        for (var item in batch) {
          final productId = item['product_id']?.toString() ?? '';
          final imei = item['imei']?.toString() ?? '';
          final cacheKey = '$productId|$imei';
          final customer = item['customer']?.toString() ?? await _fetchCustomerFromSaleOrders(productId, imei);
          customerMap[cacheKey] = customer;
        }
      } catch (e) {}
    }

    for (var item in items) {
      final productId = item['product_id']?.toString() ?? '';
      final imei = item['imei']?.toString() ?? '';
      final cacheKey = '$productId|$imei';
      customerMap.putIfAbsent(cacheKey, () => null);
    }

    return customerMap;
  }

  Future<Map<String, String?>> _fetchSuppliersForItems(List<Map<String, dynamic>> items) async {
    if (!widget.permissions.contains('view_supplier')) return {};

    Map<String, String?> supplierMap = {};
    const batchSize = 50;
    final batches = <List<Map<String, dynamic>>>[];
    for (var i = 0; i < items.length; i += batchSize) {
      batches.add(items.sublist(i, i + batchSize > items.length ? items.length : i + batchSize));
    }

    for (var batch in batches) {
      try {
        for (var item in batch) {
          final productId = item['product_id']?.toString() ?? '';
          final imei = item['imei']?.toString() ?? '';
          final cacheKey = '$productId|$imei';
          final supplier = await _fetchSupplierFromImportOrders(productId, imei);
          supplierMap[cacheKey] = supplier;
        }
      } catch (e) {}
    }

    for (var item in items) {
      final productId = item['product_id']?.toString() ?? '';
      final imei = item['imei']?.toString() ?? '';
      final cacheKey = '$productId|$imei';
      supplierMap.putIfAbsent(cacheKey, () => null);
    }

    return supplierMap;
  }

  Future<void> _updateNote(int productId, String newNote) async {
    try {
      await widget.tenantClient
          .from('products')
          .update({'note': newNote})
          .eq('id', productId);

      setState(() {
        final index = inventoryData.indexWhere((item) => item['id'] == productId);
        if (index != -1) {
          inventoryData[index]['note'] = newNote;
          filteredInventoryData = _filterInventory(inventoryData);
        }
      });
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Lỗi khi cập nhật ghi chú: $e')),
      );
    }
  }

  Future<void> _exportToExcel() async {
    if (isExporting) return;

    setState(() {
      isExporting = true;
    });

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: const [
            CircularProgressIndicator(),
            SizedBox(height: 16),
            Text(
              'Dữ liệu đang được xuất ra Excel. Vui lòng chờ tới khi hoàn tất và không đóng ứng dụng.',
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );

    await Future.delayed(Duration.zero);

    try {
      var status = await Permission.storage.request();
      if (!status.isGranted) {
        if (mounted) {
          Navigator.pop(context);
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Cần quyền lưu trữ để xuất file Excel')),
          );
        }
        setState(() {
          isExporting = false;
        });
        return;
      }

      var query = widget.tenantClient
          .from('products')
          .select('id, product_id, imei, status, import_date, return_date, fix_price, send_fix_date, transport_fee, transporter, send_transfer_date, import_transfer_date, sale_price, customer_price, transporter_price, sale_date, saleman, note, import_price, import_currency, warehouse_id, customer, cost_price, supplier_id');

      final queryText = searchController.text.toLowerCase();
      
      // Tìm kiếm theo tên sản phẩm từ cache
      List<String> matchingProductIds = [];
      if (queryText.isNotEmpty) {
        // Tìm tất cả product_id có tên chứa queryText
        CacheUtil.productNameCache.forEach((id, name) {
          if (name.toLowerCase().contains(queryText)) {
            matchingProductIds.add(id);
          }
        });
      }

      if (queryText.isNotEmpty) {
        // Kết hợp tìm kiếm theo IMEI, note, hoặc product_id (từ tên sản phẩm)
        if (matchingProductIds.isNotEmpty) {
          // Nếu tìm thấy sản phẩm theo tên, thêm điều kiện tìm theo product_id
          final productIdConditions = matchingProductIds.map((id) => 'product_id.eq.$id').join(',');
          query = query.or('imei.ilike.%$queryText%,note.ilike.%$queryText%,$productIdConditions');
        } else {
          // Chỉ tìm theo IMEI và note nếu không tìm thấy tên sản phẩm
          query = query.or('imei.ilike.%$queryText%,note.ilike.%$queryText%');
        }
      }

      if (filterOptions.contains(selectedFilter) &&
          selectedFilter != 'Tất cả' &&
          selectedFilter != 'Tồn kho mới nhất' &&
          selectedFilter != 'Tồn kho lâu nhất') {
        query = query.eq('status', selectedFilter);
      }

      if (selectedWarehouse != 'Tất cả') {
        final warehouseId = CacheUtil.warehouseNameCache.entries
            .firstWhere((entry) => entry.value == selectedWarehouse, orElse: () => MapEntry('', ''))
            .key;
        if (warehouseId.isNotEmpty) {
          query = query.eq('warehouse_id', warehouseId);
        }
      }

      final response = await query;
      List<Map<String, dynamic>> allItems = response.cast<Map<String, dynamic>>();

      allItems = _filterInventory(allItems);

      if (allItems.isEmpty) {
        if (mounted) {
          Navigator.pop(context);
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Không có dữ liệu để xuất')),
          );
        }
        setState(() {
          isExporting = false;
        });
        return;
      }

      Map<String, String?> customerMap = await _fetchCustomersForItems(allItems);
      Map<String, String?> supplierMap = await _fetchSuppliersForItems(allItems);

      var excel = Excel.createExcel();
      excel.delete('Sheet1');
      Sheet sheet = excel['TonKho'];

      List<TextCellValue> headers = [
        TextCellValue('Số thứ tự'),
        TextCellValue('Tên sản phẩm'),
        TextCellValue('IMEI'),
        if (widget.permissions.contains('view_import_price')) TextCellValue('Giá nhập'),
        if (widget.permissions.contains('view_import_price')) TextCellValue('Đơn vị tiền nhập'),
        if (widget.permissions.contains('view_cost_price')) TextCellValue('Giá vốn'),
        TextCellValue('Ngày gửi sửa'),
        TextCellValue('Trạng thái'),
        TextCellValue('Kho'),
        TextCellValue('Ngày nhập'),
        TextCellValue('Ngày trả hàng'),
        TextCellValue('Tiền fix lỗi'),
        TextCellValue('Cước vận chuyển'),
        TextCellValue('Đơn vị vận chuyển'),
        TextCellValue('Ngày chuyển kho'),
        TextCellValue('Ngày nhập kho'),
        if (widget.permissions.contains('view_sale_price')) TextCellValue('Giá bán'),
        if (widget.permissions.contains('view_customer')) TextCellValue('Khách hàng'),
        TextCellValue('Tiền cọc'),
        TextCellValue('Tiền COD'),
        TextCellValue('Ngày bán'),
        if (widget.permissions.contains('view_supplier')) TextCellValue('Nhà cung cấp'),
        TextCellValue('Ghi chú'),
      ];

      sheet.appendRow(headers);

      for (int i = 0; i < allItems.length; i++) {
        final item = allItems[i];
        final productId = item['product_id']?.toString() ?? '';
        final imei = item['imei']?.toString() ?? '';
        final cacheKey = '$productId|$imei';

        String? customer = customerMap[cacheKey];
        String? supplier = supplierMap[cacheKey];

        List<TextCellValue> row = [
          TextCellValue((i + 1).toString()),
          TextCellValue(CacheUtil.getProductName(productId)),
          TextCellValue(imei),
          if (widget.permissions.contains('view_import_price')) TextCellValue(item['import_price']?.toString() ?? ''),
          if (widget.permissions.contains('view_import_price')) TextCellValue(item['import_currency']?.toString() ?? ''),
          if (widget.permissions.contains('view_cost_price')) TextCellValue(item['cost_price']?.toString() ?? ''),
          TextCellValue(item['send_fix_date']?.toString() ?? ''),
          TextCellValue(item['status']?.toString() ?? ''),
          TextCellValue(CacheUtil.getWarehouseName(item['warehouse_id']?.toString())),
          TextCellValue(item['import_date']?.toString() ?? ''),
          TextCellValue(item['return_date']?.toString() ?? ''),
          TextCellValue(item['fix_price']?.toString() ?? ''),
          TextCellValue(item['transport_fee']?.toString() ?? ''),
          TextCellValue(item['transporter']?.toString() ?? ''),
          TextCellValue(item['send_transfer_date']?.toString() ?? ''),
          TextCellValue(item['import_transfer_date']?.toString() ?? ''),
          if (widget.permissions.contains('view_sale_price')) TextCellValue(item['sale_price']?.toString() ?? ''),
          if (widget.permissions.contains('view_customer')) TextCellValue(customer ?? ''),
          TextCellValue(item['customer_price']?.toString() ?? ''),
          TextCellValue(item['transporter_price']?.toString() ?? ''),
          TextCellValue(item['sale_date']?.toString() ?? ''),
          if (widget.permissions.contains('view_supplier')) TextCellValue(supplier ?? ''),
          TextCellValue(item['note']?.toString() ?? ''),
        ];

        sheet.appendRow(row);
      }

      Directory downloadsDir;
      if (Platform.isAndroid) {
        downloadsDir = Directory('/storage/emulated/0/Download');
        if (!await downloadsDir.exists()) {
          await downloadsDir.create(recursive: true);
        }
      } else {
        downloadsDir = await getTemporaryDirectory();
      }

      final now = DateTime.now();
      final filterName = selectedFilter.replaceAll(' ', '');
      final fileName = 'Báo Cáo Tồn Kho $filterName ${now.day}_${now.month}_${now.year} ${now.hour}_${now.minute}_${now.second}.xlsx';
      final filePath = '${downloadsDir.path}/$fileName';
      final file = File(filePath);

      final excelBytes = excel.encode();
      if (excelBytes == null) {
        throw Exception('Không thể tạo file Excel');
      }
      await file.writeAsBytes(excelBytes);

      if (mounted) {
        Navigator.pop(context);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Đã xuất file Excel: $filePath')),
        );

        final openResult = await OpenFile.open(filePath);
        if (openResult.type != ResultType.done) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Không thể mở file. File đã được lưu tại: $filePath')),
          );
        }
      }
    } catch (e) {
      if (mounted) {
        Navigator.pop(context);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Lỗi khi xuất file Excel: $e')),
        );
      }
    } finally {
      setState(() {
        isExporting = false;
      });
    }
  }

  void _showProductDetails(Map<String, dynamic> product) async {
    final productId = product['id'] as int;
    final productNameId = product['product_id']?.toString();
    final imei = product['imei']?.toString() ?? '';

    String? customer = product['customer']?.toString();
    String? supplier;

    if (widget.permissions.contains('view_supplier')) {
      final supplierId = product['supplier_id']?.toString();
      supplier = supplierId != null ? CacheUtil.getSupplierName(supplierId) : null;
    }

    final details = <String, String?>{
      'Tên sản phẩm': CacheUtil.getProductName(productNameId),
      'IMEI': product['imei']?.toString(),
      'Trạng thái': product['status']?.toString(),
      if (widget.permissions.contains('view_import_price'))
        'Giá nhập': product['import_price'] != null ? '${product['import_price']} ${product['import_currency'] ?? ''}' : null,
      if (widget.permissions.contains('view_cost_price'))
        'Giá vốn': product['cost_price'] != null ? product['cost_price'].toString() : null,
      'Ngày nhập': product['import_date']?.toString(),
      if (widget.permissions.contains('view_supplier') && supplier != null)
        'Nhà cung cấp': supplier,
      'Ngày trả hàng': product['return_date']?.toString(),
      'Tiền fix lỗi': product['fix_price']?.toString(),
      'Ngày gửi fix lỗi': product['send_fix_date']?.toString(),
      'Cước vận chuyển': product['transport_fee']?.toString(),
      'Đơn vị vận chuyển': product['transporter']?.toString(),
      'Ngày chuyển kho': product['send_transfer_date']?.toString(),
      'Ngày nhập kho': product['import_transfer_date']?.toString(),
      if (widget.permissions.contains('view_sale_price'))
        'Giá bán': product['sale_price']?.toString(),
      if (widget.permissions.contains('view_customer') && customer != null)
        'Khách hàng': customer,
      'Tiền cọc': product['customer_price'] != null && (product['customer_price'] as num) > 0
          ? product['customer_price'].toString()
          : null,
      'Tiền COD': product['transporter_price'] != null && (product['transporter_price'] as num) > 0
          ? product['transporter_price'].toString()
          : null,
      'Ngày bán': product['sale_date']?.toString(),
      'Nhân viên bán': product['saleman']?.toString(),
      'Ghi chú': product['note']?.toString(),
    };

    if (!isEditingNote.containsKey(productId)) {
      isEditingNote[productId] = false;
    }
    if (!noteControllers.containsKey(productId)) {
      noteControllers[productId] = TextEditingController(text: product['note']?.toString() ?? '');
    }

    showDialog(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text('Chi tiết sản phẩm'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                ...details.entries
                    .where((entry) => entry.value != null && entry.value!.isNotEmpty)
                    .map((entry) => Padding(
                          padding: const EdgeInsets.symmetric(vertical: 4.0),
                          child: Text('${entry.key}: ${entry.value}'),
                        )),
                const SizedBox(height: 8),
                if (isEditingNote[productId] ?? false)
                  TextField(
                    controller: noteControllers[productId],
                    decoration: const InputDecoration(
                      labelText: 'Ghi chú',
                      border: OutlineInputBorder(),
                    ),
                  ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () async {
                if (isEditingNote[productId] ?? false) {
                  final newNote = noteControllers[productId]!.text;
                  await _updateNote(productId, newNote);
                  setDialogState(() {
                    isEditingNote[productId] = false;
                  });
                } else {
                  setDialogState(() {
                    isEditingNote[productId] = true;
                  });
                }
              },
              child: Text(
                (isEditingNote[productId] ?? false) ? 'Xong' : 'Sửa',
                style: const TextStyle(color: Colors.blue),
              ),
            ),
            const SizedBox(width: 8),
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Đóng'),
            ),
          ],
        ),
      ),
    );
  }

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
                onPressed: _fetchInventoryData,
                child: const Text('Thử lại'),
              ),
            ],
          ),
        ),
      );
    }

    return Scaffold(
      backgroundColor: const Color(0xFFF6F9FF),
      appBar: AppBar(
        title: const Text('Kho hàng', style: TextStyle(color: Colors.white)),
        iconTheme: const IconThemeData(color: Colors.white),
        backgroundColor: Colors.black,
        elevation: 2,
      ),
      body: Stack(
        children: [
          Column(
            children: [
              Padding(
                padding: const EdgeInsets.all(12.0),
                child: Column(
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const Text(
                                'Tình trạng',
                                style: TextStyle(fontSize: 12, color: Colors.black54),
                              ),
                              const SizedBox(height: 4),
                              DropdownButton<String>(
                                value: selectedFilter,
                                borderRadius: BorderRadius.circular(12),
                                dropdownColor: Colors.white,
                                isExpanded: true,
                                items: filterOptions.map((option) {
                                  return DropdownMenuItem(
                                    value: option,
                                    child: Text(option),
                                  );
                                }).toList(),
                                onChanged: (value) => setState(() {
                                  selectedFilter = value!;
                                  _fetchFilteredData();
                                }),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const Text(
                                'Kho chi nhánh',
                                style: TextStyle(fontSize: 12, color: Colors.black54),
                              ),
                              const SizedBox(height: 4),
                              DropdownButton<String>(
                                value: selectedWarehouse,
                                borderRadius: BorderRadius.circular(12),
                                dropdownColor: Colors.white,
                                isExpanded: true,
                                items: warehouseOptions.map((option) {
                                  return DropdownMenuItem(
                                    value: option,
                                    child: Text(option),
                                  );
                                }).toList(),
                                onChanged: (value) => setState(() {
                                  selectedWarehouse = value!;
                                  _fetchFilteredData();
                                }),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    Stack(
                      alignment: Alignment.centerRight,
                      children: [
                        TextField(
                          controller: searchController,
                          decoration: InputDecoration(
                            hintText: 'Tìm theo tên, IMEI hoặc ghi chú',
                            prefixIcon: const Icon(Icons.search),
                            contentPadding: const EdgeInsets.symmetric(horizontal: 16),
                            border: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(12),
                            ),
                          ),
                        ),
                        if (isSearching)
                          const Padding(
                            padding: EdgeInsets.only(right: 16),
                            child: SizedBox(
                              width: 20,
                              height: 20,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            ),
                          ),
                      ],
                    ),
                  ],
                ),
              ),
              Expanded(
                child: ListView.builder(
                  controller: _scrollController,
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  itemCount: filteredInventory.length + (isLoadingMore ? 1 : 0),
                  itemBuilder: (context, index) {
                    if (index == filteredInventory.length && isLoadingMore) {
                      return const Center(child: CircularProgressIndicator());
                    }

                    final item = filteredInventory[index];
                    final daysInInventory = _calculateDaysInInventory(item['import_date']);
                    final isSold = item['status']?.toString().toLowerCase() == 'đã bán';
                    final showDaysInInventory = item['import_date'] != null && !isSold;

                    return Card(
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                      elevation: 2,
                      margin: const EdgeInsets.symmetric(vertical: 6),
                      child: ListTile(
                        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                        title: Text(
                          CacheUtil.getProductName(item['product_id']?.toString()),
                          style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                          overflow: TextOverflow.ellipsis,
                        ),
                        subtitle: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'IMEI: ${item['imei']?.toString() ?? ''}',
                              style: const TextStyle(fontSize: 14),
                              overflow: TextOverflow.ellipsis,
                            ),
                            if (showDaysInInventory) ...[
                              const SizedBox(height: 2),
                              Text(
                                'Tồn kho $daysInInventory ngày',
                                style: TextStyle(
                                  fontSize: 12,
                                  color: daysInInventory <= 7 ? Colors.green : Colors.red,
                                ),
                              ),
                            ],
                          ],
                        ),
                        trailing: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              item['status']?.toString() ?? '',
                              style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14),
                            ),
                            const SizedBox(width: 8),
                            IconButton(
                              icon: const Icon(Icons.visibility),
                              onPressed: () => _showProductDetails(item),
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
          Positioned(
            bottom: 16,
            right: 16,
            child: FloatingActionButton.extended(
              onPressed: _exportToExcel,
              label: const Text('Xuất Excel'),
              icon: const Icon(Icons.file_download),
              backgroundColor: Colors.blue,
              foregroundColor: Colors.white,
            ),
          ),
        ],
      ),
    );
  }
}