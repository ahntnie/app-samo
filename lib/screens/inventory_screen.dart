import 'package:flutter/material.dart' hide Border, BorderStyle;
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:excel/excel.dart';
import 'package:open_file/open_file.dart';
import 'dart:io';
import 'dart:async';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';
import 'package:barcode/barcode.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:intl/intl.dart';
import 'package:flutter/services.dart' show rootBundle, Clipboard, ClipboardData;
import '../helpers/global_cache_manager.dart';
import '../helpers/storage_helper.dart';
import '../helpers/excel_style_helper.dart';
import '../helpers/bluetooth_print_helper.dart';
import 'customers_screen.dart';
import 'suppliers_screen.dart';
import 'transporters_screen.dart';
import 'fixers_screen.dart';

// Backward compatibility alias
class CacheUtil {
  static Map<String, String> get productNameCache => GlobalCacheManager().productNameCache;
  static Map<String, String> get warehouseNameCache => GlobalCacheManager().warehouseNameCache;
  static Map<String, String> get supplierNameCache => GlobalCacheManager().supplierNameCache;
  static Map<String, String> get fixerNameCache => GlobalCacheManager().fixerNameCache;
  
  static void cacheProductName(String id, String name) => GlobalCacheManager().cacheProductName(id, name);
  static void cacheWarehouseName(String id, String name) => GlobalCacheManager().cacheWarehouseName(id, name);
  static void cacheSupplierName(String id, String name) => GlobalCacheManager().cacheSupplierName(id, name);
  static void cacheFixerName(String id, String name) => GlobalCacheManager().cacheFixerName(id, name);
  
  static String getProductName(String? id) => GlobalCacheManager().getProductName(id);
  static String getWarehouseName(String? id) => GlobalCacheManager().getWarehouseName(id);
  static String getSupplierName(String? id) => GlobalCacheManager().getSupplierName(id);
  static String getFixerName(String? id) => GlobalCacheManager().getFixerName(id);
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
  
  // Lưu lựa chọn mặc định
  String _defaultPrintType = 'a4'; // 'a4', 'thermal', hoặc 'bluetooth'
  int _defaultLabelsPerRow = 1; // 1, 2, hoặc 3
  int _defaultLabelHeight = 30; // 20, 25, 30, 40mm
  bool _hasDefaultSettings = false; // Đã có cài đặt mặc định chưa

  @override
  void initState() {
    super.initState();
    _initializeAsync();
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
  
  /// Khởi tạo các cài đặt async (settings và Bluetooth)
  Future<void> _initializeAsync() async {
    await _loadPrintSettings();
    // Khởi tạo BluetoothPrint sớm để tránh lỗi method channel khi bấm in
    await _initializeBluetoothPrint();
  }

  /// Khởi tạo BluetoothPrint sớm (trong initState) để tránh lỗi method channel
  Future<void> _initializeBluetoothPrint() async {
    try {
      // Trên iOS, không khởi tạo Bluetooth do package có bug
      if (Platform.isIOS) {
        debugPrint('⚠️ [Inventory] iOS detected - Skipping Bluetooth initialization');
        return;
      }
      
      // Chỉ thử khởi tạo nếu print type là bluetooth
      if (_defaultPrintType == 'bluetooth') {
        debugPrint('🔵 [Inventory] Pre-initializing BluetoothPrint...');
        // Reset trước khi thử lại
        BluetoothPrintHelper.resetInitialization();
        // Gọi một method đơn giản để trigger initialization
        await BluetoothPrintHelper.isConnected();
        debugPrint('✅ [Inventory] BluetoothPrint pre-initialized successfully');
      }
    } catch (e) {
      debugPrint('⚠️ [Inventory] BluetoothPrint pre-initialization failed (will retry later): $e');
      // Không throw error ở đây, để user vẫn có thể dùng app
      // Sẽ retry khi user thực sự bấm in
    }
  }

  Future<void> _loadPrintSettings() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      setState(() {
        _defaultPrintType = prefs.getString('default_print_type') ?? 'a4';
        _defaultLabelsPerRow = prefs.getInt('default_labels_per_row') ?? 1;
        _defaultLabelHeight = prefs.getInt('default_label_height') ?? 30;
        _hasDefaultSettings = prefs.getBool('has_default_print_settings') ?? false;
      });
    } catch (e) {
      // Ignore errors, use defaults
    }
  }
  
  Future<void> _savePrintSettings(String printType, int labelsPerRow, int labelHeight) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('default_print_type', printType);
      await prefs.setInt('default_labels_per_row', labelsPerRow);
      await prefs.setInt('default_label_height', labelHeight);
      await prefs.setBool('has_default_print_settings', true);
      setState(() {
        _hasDefaultSettings = true;
      });
    } catch (e) {
      // Ignore errors
    }
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
      // Sử dụng GlobalCacheManager - tự động skip nếu đã có cache
      final cacheManager = GlobalCacheManager();
      await Future.wait([
        cacheManager.fetchAndCacheProducts(widget.tenantClient),
        cacheManager.fetchAndCacheWarehouses(widget.tenantClient),
        cacheManager.fetchAndCacheSuppliers(widget.tenantClient),
        cacheManager.fetchAndCacheFixers(widget.tenantClient),
      ]);

      // Build warehouse options từ cache
      List<String> warehouseNames = ['Tất cả'];
      warehouseNames.addAll(cacheManager.warehouseNameCache.values);
      
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
          .select('id, product_id, imei, status, import_date, return_date, fix_price, send_fix_date, transport_fee, transporter, send_transfer_date, import_transfer_date, sale_price, customer_price, transporter_price, sale_date, saleman, note, import_price, import_currency, warehouse_id, customer, customer_id, cost_price, supplier_id, fix_unit, fix_unit_id')
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
          .select('id, product_id, imei, status, import_date, return_date, fix_price, send_fix_date, transport_fee, transporter, send_transfer_date, import_transfer_date, sale_price, customer_price, transporter_price, sale_date, saleman, note, import_price, import_currency, warehouse_id, customer, customer_id, cost_price, supplier_id, fix_unit, fix_unit_id');

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

    // ✅ Thêm các trạng thái chuẩn vào danh sách filter (CHÍNH XÁC theo DB)
    final standardStatuses = <String>[
      'Tồn kho',
      'Đang sửa',           // ✅ Chữ hoa D
      'đang vận chuyển',    // ✅ Chữ thường d (khớp với DB)
      'Đã bán',
    ];
    
    // Kết hợp: giữ các trạng thái chuẩn + thêm các trạng thái khác từ DB (nếu có)
    final allStatuses = <String>{...standardStatuses};
    allStatuses.addAll(uniqueStatuses);
    
    setState(() {
      filterOptions = [
        'Tất cả',
        ...allStatuses.toList()..sort(),
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

  // ✅ ĐÃ XÓA: 
  // - _fetchCustomerFromSaleOrders()
  // - _fetchSupplierFromImportOrders()
  // - _fetchCustomersForItems() 
  // - _fetchSuppliersForItems()
  // Lý do: Customer/Supplier đã có sẵn trong products table
  // - Customer: lấy từ products.customer
  // - Supplier: lấy từ products.supplier_id qua CacheUtil.getSupplierName()
  // Việc query thêm từ sale_orders/import_orders gây chậm nghiêm trọng (N+1 problem)

  Future<void> _updateNote(int productId, String newNote) async {
    try {
      await widget.tenantClient
          .from('products')
          .update({'note': newNote})
          .eq('id', productId);

      setState(() {
        // Cập nhật trong danh sách inventory gốc
        final index = inventoryData.indexWhere((item) => item['id'] == productId);
        if (index != -1) {
          final updatedItem = Map<String, dynamic>.from(inventoryData[index]);
          updatedItem['note'] = newNote;
          inventoryData[index] = updatedItem;
        }

        // Cập nhật trong danh sách đã lọc (trường hợp đang tìm kiếm / lọc)
        final filteredIndex =
            filteredInventoryData.indexWhere((item) => item['id'] == productId);
        if (filteredIndex != -1) {
          final updatedFilteredItem =
              Map<String, dynamic>.from(filteredInventoryData[filteredIndex]);
          updatedFilteredItem['note'] = newNote;
          filteredInventoryData[filteredIndex] = updatedFilteredItem;
        }

        if (noteControllers.containsKey(productId)) {
          noteControllers[productId]!.text = newNote;
        }
      });
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Lỗi khi cập nhật ghi chú: $e')),
      );
    }
  }

  // Helper function để load font hỗ trợ Unicode
  // Sử dụng font mặc định của package pdf (hỗ trợ Unicode)
  // Nếu có font trong assets thì load từ đó, nếu không thì dùng font mặc định
  Future<pw.Font?> _loadUnicodeFont() async {
    try {
      // Thử load font từ assets nếu có
      final fontData = await rootBundle.load('assets/fonts/Roboto-Regular.ttf');
      return pw.Font.ttf(fontData);
    } catch (e) {
      // Nếu không có font trong assets, trả về null để dùng font mặc định
      // Package pdf 3.11.1 có hỗ trợ Unicode với font mặc định
      return null;
    }
  }

  Future<pw.Font?> _loadUnicodeFontBold() async {
    try {
      final fontData = await rootBundle.load('assets/fonts/Roboto-Bold.ttf');
      return pw.Font.ttf(fontData);
    } catch (e) {
      // Trả về null để dùng font mặc định
      return null;
    }
  }

  Future<void> _printLabels({bool showSettings = false}) async {
    String printType;
    int labelsPerRow;
    int labelHeight;
    bool saveAsDefault = false;

    // Nếu đã có cài đặt mặc định và không bắt buộc hiển thị settings, dùng luôn
    if (_hasDefaultSettings && !showSettings) {
      printType = _defaultPrintType;
      labelsPerRow = _defaultLabelsPerRow;
      labelHeight = _defaultLabelHeight;
    } else {
      // Hiển thị dialog cài đặt
    final result = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Cài đặt in tem'),
        content: SingleChildScrollView(
          child: _PrintSettingsDialog(
            defaultPrintType: _defaultPrintType,
            defaultLabelsPerRow: _defaultLabelsPerRow,
            defaultLabelHeight: _defaultLabelHeight,
          ),
        ),
      ),
    );

    if (result == null) return;

      printType = result['printType'] as String;
      labelsPerRow = result['labelsPerRow'] as int;
      labelHeight = result['labelHeight'] as int;
      saveAsDefault = result['saveAsDefault'] as bool;

    // Lưu cài đặt nếu user chọn
    if (saveAsDefault) {
      await _savePrintSettings(printType, labelsPerRow, labelHeight);
      setState(() {
        _defaultPrintType = printType;
        _defaultLabelsPerRow = labelsPerRow;
        _defaultLabelHeight = labelHeight;
      });
      }
    }

    // Nếu chọn in qua Bluetooth, xử lý riêng
    // Trên iOS, tạm thời disable Bluetooth do package có bug
    if (printType == 'bluetooth') {
      if (Platform.isIOS) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Tính năng in qua Bluetooth tạm thời không khả dụng trên iOS. Vui lòng sử dụng in PDF/thermal.'),
              duration: Duration(seconds: 3),
            ),
          );
        }
        return;
      }
      await _executeBluetoothPrint();
    } else {
      await _executePrint(printType, labelsPerRow, labelHeight);
    }
  }

  /// Helper function để lấy dữ liệu sản phẩm đã lọc (dùng chung cho cả PDF và Bluetooth)
  Future<List<Map<String, dynamic>>> _fetchFilteredProductsForPrint() async {
    var query = widget.tenantClient
        .from('products')
        .select('id, product_id, imei, status');

    final queryText = searchController.text.toLowerCase();
    
    // Tìm kiếm theo tên sản phẩm từ cache
    List<String> matchingProductIds = [];
    if (queryText.isNotEmpty) {
      CacheUtil.productNameCache.forEach((id, name) {
        if (name.toLowerCase().contains(queryText)) {
          matchingProductIds.add(id);
        }
      });
    }

    if (queryText.isNotEmpty) {
      if (matchingProductIds.isNotEmpty) {
        final productIdConditions = matchingProductIds.map((id) => 'product_id.eq.$id').join(',');
        query = query.or('imei.ilike.%$queryText%,note.ilike.%$queryText%,$productIdConditions');
      } else {
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
    
    return allItems;
  }

  Future<void> _executePrint(String printType, int labelsPerRow, int labelHeight) async {
    try {
      // Load font hỗ trợ Unicode (nếu có trong assets)
      final baseFont = await _loadUnicodeFont();
      final boldFont = await _loadUnicodeFontBold();
      
      // Lấy dữ liệu đã lọc (dùng hàm chung)
      final allItems = await _fetchFilteredProductsForPrint();

      if (allItems.isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Không có dữ liệu để in')),
        );
        return;
      }

      // Tạo PDF với tem nhãn
      final pdf = pw.Document();
      
      // Tạo barcode generator
      final barcodeGen = Barcode.code128();
      
      if (printType == 'thermal') {
        // In tem nhiệt - hỗ trợ nhiều layout
        if (labelsPerRow == 1) {
          // Layout 1 tem/hàng (cuộn 40mm)
          for (var item in allItems) {
            pdf.addPage(
              pw.Page(
                pageFormat: PdfPageFormat(
                  40 * PdfPageFormat.mm,  // Width: 40mm
                  labelHeight * PdfPageFormat.mm,  // Height: tùy chọn
                  marginAll: 1 * PdfPageFormat.mm,
                ),
                theme: baseFont != null && boldFont != null
                    ? pw.ThemeData.withFont(
                        base: baseFont,
                        bold: boldFont,
                      )
                    : null, // Dùng font mặc định nếu không có font từ assets
                build: (context) => _buildThermalLabel(item, barcodeGen, labelHeight, baseFont: baseFont, boldFont: boldFont),
              ),
            );
          }
        } else {
          // Layout 2 hoặc 3 tem/hàng (cuộn rộng)
          final pageWidth = labelsPerRow == 2 
              ? 85 * PdfPageFormat.mm  // 2 tem: 40*2 + gap 5mm
              : 125 * PdfPageFormat.mm; // 3 tem: 40*3 + gap 5mm*2
          
          for (int i = 0; i < allItems.length; i += labelsPerRow) {
            final rowItems = allItems.skip(i).take(labelsPerRow).toList();
            
            pdf.addPage(
              pw.Page(
                pageFormat: PdfPageFormat(
                  pageWidth,
                  labelHeight * PdfPageFormat.mm,  // Height: tùy chọn
                  marginAll: 1 * PdfPageFormat.mm,
                ),
                theme: baseFont != null && boldFont != null
                    ? pw.ThemeData.withFont(
                        base: baseFont,
                        bold: boldFont,
                      )
                    : null, // Dùng font mặc định nếu không có font từ assets
                build: (context) {
                  return pw.Row(
                    mainAxisAlignment: pw.MainAxisAlignment.spaceEvenly,
                    children: rowItems.map((item) {
                      return pw.Container(
                        width: 38 * PdfPageFormat.mm, // 40mm - margin
                        child: _buildThermalLabel(item, barcodeGen, labelHeight, baseFont: baseFont, boldFont: boldFont),
                      );
                    }).toList(),
                  );
                },
              ),
            );
          }
        }
      } else {
        // In A4 - 4 tem trên 1 trang (2x2)
        const itemsPerPage = 4;
        for (int i = 0; i < allItems.length; i += itemsPerPage) {
          final pageItems = allItems.skip(i).take(itemsPerPage).toList();
          
          pdf.addPage(
            pw.Page(
              pageFormat: PdfPageFormat.a4,
              margin: const pw.EdgeInsets.all(20),
              theme: baseFont != null && boldFont != null
                  ? pw.ThemeData.withFont(
                      base: baseFont,
                      bold: boldFont,
                    )
                  : null, // Dùng font mặc định nếu không có font từ assets
              build: (context) {
                return pw.Column(
                  children: [
                    // Hàng đầu tiên (2 tem)
                    pw.Row(
                      crossAxisAlignment: pw.CrossAxisAlignment.start,
                      children: [
                        if (pageItems.isNotEmpty) 
                          pw.Expanded(child: _buildA4Label(pageItems[0], barcodeGen, baseFont: baseFont, boldFont: boldFont)),
                        pw.SizedBox(width: 10),
                        if (pageItems.length > 1) 
                          pw.Expanded(child: _buildA4Label(pageItems[1], barcodeGen, baseFont: baseFont, boldFont: boldFont))
                        else
                          pw.Expanded(child: pw.Container()),
                      ],
                    ),
                    pw.SizedBox(height: 20),
                    // Hàng thứ hai (2 tem)
                    pw.Row(
                      crossAxisAlignment: pw.CrossAxisAlignment.start,
                      children: [
                        if (pageItems.length > 2) 
                          pw.Expanded(child: _buildA4Label(pageItems[2], barcodeGen, baseFont: baseFont, boldFont: boldFont))
                        else
                          pw.Expanded(child: pw.Container()),
                        pw.SizedBox(width: 10),
                        if (pageItems.length > 3) 
                          pw.Expanded(child: _buildA4Label(pageItems[3], barcodeGen, baseFont: baseFont, boldFont: boldFont))
                        else
                          pw.Expanded(child: pw.Container()),
                      ],
                    ),
                  ],
                );
              },
            ),
          );
        }
      }

      // Hiển thị preview và in
      // Lưu ý: Để máy in CLabel CT221B xuất hiện trong danh sách,
      // cần cài đặt driver máy in trên hệ thống (Settings > Printers & scanners)
      // hoặc kết nối qua Bluetooth/USB và cài driver từ nhà sản xuất.
      // Nếu chỉ kết nối qua app riêng mà chưa cài driver hệ thống, 
      // máy in sẽ không xuất hiện trong dialog in của hệ điều hành.
      await Printing.layoutPdf(
        onLayout: (format) async => pdf.save(),
        name: 'Tem_Nhan_IMEI_${DateTime.now().millisecondsSinceEpoch}.pdf',
      );

    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Lỗi khi in tem nhãn: $e')),
      );
    }
  }

  /// In qua Bluetooth
  Future<void> _executeBluetoothPrint() async {
    try {
      debugPrint('🔵 [Bluetooth Print] Step 1: Checking connection...');
      // Kiểm tra kết nối Bluetooth
      bool connected = false;
      try {
        connected = await BluetoothPrintHelper.isConnected();
        debugPrint('🔵 [Bluetooth Print] Step 1: Connected = $connected');
      } catch (e, stackTrace) {
        debugPrint('❌ [Bluetooth Print] Step 1 ERROR: $e');
        debugPrint('❌ [Bluetooth Print] Step 1 Stack trace: $stackTrace');
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('Lỗi khởi tạo Bluetooth: $e\nVui lòng thử lại hoặc sử dụng in PDF/thermal.'),
              duration: const Duration(seconds: 5),
            ),
          );
        }
        return;
      }
      
      // Nếu chưa kết nối, hiển thị dialog chọn máy in
      if (!connected) {
        debugPrint('🔵 [Bluetooth Print] Step 2: Showing device picker...');
        final device = await BluetoothPrintHelper.showDevicePicker(context);
        if (device == null) {
          debugPrint('🔵 [Bluetooth Print] Step 2: User cancelled device selection');
          return; // User hủy chọn máy in
        }
        
        debugPrint('🔵 [Bluetooth Print] Step 3: Connecting to device...');
        // Kết nối với máy in
        final success = await BluetoothPrintHelper.connect(device);
        if (!success) {
          debugPrint('❌ [Bluetooth Print] Step 3: Connection failed');
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('Không thể kết nối với máy in Bluetooth')),
            );
          }
          return;
        }
        
        debugPrint('🔵 [Bluetooth Print] Step 3: Connection successful');
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Đã kết nối với máy in Bluetooth')),
          );
        }
      }

      // Sử dụng CÙNG hàm query như _executePrint() (đã hoạt động tốt)
      // Đảm bảo 100% logic query giống hệt nhau
      List<Map<String, dynamic>> allItems = [];
      
      debugPrint('🔵 [Bluetooth Print] Step 4: Fetching products data...');
      try {
        allItems = await _fetchFilteredProductsForPrint();
        debugPrint('🔵 [Bluetooth Print] Step 4: Got ${allItems.length} items');
      } catch (e, stackTrace) {
        // Log chi tiết lỗi để debug
        debugPrint('❌ [Bluetooth Print] Step 4 ERROR: $e');
        debugPrint('❌ [Bluetooth Print] Stack trace: $stackTrace');
        
        // Nếu có lỗi query, hiển thị thông báo và return
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('Lỗi khi lấy dữ liệu để in: $e'),
              duration: const Duration(seconds: 5),
            ),
          );
        }
        return;
      }

      debugPrint('🔵 [Bluetooth Print] Step 5: Checking if items is empty...');
      if (allItems.isEmpty) {
        debugPrint('🔵 [Bluetooth Print] Step 5: No items to print');
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Không có dữ liệu để in')),
          );
        }
        return;
      }

      debugPrint('🔵 [Bluetooth Print] Step 6: Showing loading dialog...');
      // Hiển thị loading
      showDialog(
        context: context,
        barrierDismissible: false,
        builder: (context) => AlertDialog(
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const CircularProgressIndicator(),
              const SizedBox(height: 16),
              Text('Đang in ${allItems.length} tem qua Bluetooth...'),
            ],
          ),
        ),
      );

      debugPrint('🔵 [Bluetooth Print] Step 7: Starting to print items...');
      // In từng item
      int successCount = 0;
      int failCount = 0;
      
      for (int i = 0; i < allItems.length; i++) {
        try {
          final item = allItems[i];
          debugPrint('🔵 [Bluetooth Print] Step 7.$i: Processing item $i/${allItems.length}');
          
          final productId = item['product_id']?.toString() ?? '';
          final imei = item['imei']?.toString() ?? '';
          debugPrint('🔵 [Bluetooth Print] Step 7.$i: productId=$productId, imei=$imei');
          
          final productName = CacheUtil.getProductName(productId);
          debugPrint('🔵 [Bluetooth Print] Step 7.$i: productName=$productName');
          
          if (imei.isNotEmpty && productName.isNotEmpty) {
            debugPrint('🔵 [Bluetooth Print] Step 7.$i: Calling printImeiLabel...');
            final success = await BluetoothPrintHelper.printImeiLabel(
              productName: productName,
              imei: imei,
              labelHeight: 30, // Mặc định 30mm cho Bluetooth
            );
            debugPrint('🔵 [Bluetooth Print] Step 7.$i: Print result = $success');
            
            if (success) {
              successCount++;
              // Đợi một chút giữa các lần in để tránh quá tải
              await Future.delayed(const Duration(milliseconds: 500));
            } else {
              failCount++;
            }
          } else {
            debugPrint('⚠️ [Bluetooth Print] Step 7.$i: Skipping item (imei or productName empty)');
          }
        } catch (e, stackTrace) {
          debugPrint('❌ [Bluetooth Print] Step 7.$i ERROR: $e');
          debugPrint('❌ [Bluetooth Print] Step 7.$i Stack trace: $stackTrace');
          failCount++;
        }
      }

      debugPrint('🔵 [Bluetooth Print] Step 8: Closing loading dialog and showing result...');
      if (mounted) {
        Navigator.pop(context); // Đóng loading dialog
        
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Đã in $successCount tem. ${failCount > 0 ? 'Lỗi: $failCount tem' : ''}'),
            duration: const Duration(seconds: 3),
          ),
        );
      }
    } catch (e, stackTrace) {
      debugPrint('❌ [Bluetooth Print] OUTER CATCH ERROR: $e');
      debugPrint('❌ [Bluetooth Print] OUTER CATCH Stack trace: $stackTrace');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Lỗi khi in qua Bluetooth: $e')),
        );
      }
    }
  }

  // Tem cho máy in nhiệt (tự động điều chỉnh theo chiều cao)
  pw.Widget _buildThermalLabel(Map<String, dynamic> item, Barcode barcodeGen, int labelHeight, {pw.Font? baseFont, pw.Font? boldFont}) {
    final productId = item['product_id']?.toString() ?? '';
    final imei = item['imei']?.toString() ?? '';
    final productName = CacheUtil.getProductName(productId);

    // Tự động điều chỉnh kích thước theo chiều cao tem
    double titleFontSize;
    double imeiFontSize;
    double barcodeHeight;
    int maxLines;
    
    if (labelHeight <= 20) {
      // Tem 20mm: rất nhỏ, chỉ hiển thị tối thiểu
      titleFontSize = 5;
      imeiFontSize = 4;
      barcodeHeight = 10;
      maxLines = 1;
    } else if (labelHeight <= 25) {
      // Tem 25mm: nhỏ, hiển thị gọn
      titleFontSize = 6;
      imeiFontSize = 4.5;
      barcodeHeight = 13;
      maxLines = 1;
    } else if (labelHeight <= 30) {
      // Tem 30mm: tiêu chuẩn
      titleFontSize = 7;
      imeiFontSize = 5;
      barcodeHeight = 16;
      maxLines = 1;
    } else {
      // Tem 40mm+: lớn, có nhiều không gian
      titleFontSize = 9;
      imeiFontSize = 6;
      barcodeHeight = 22;
      maxLines = 2;
    }

    // Tăng độ rõ: phóng to mã vạch và số IMEI
    final enlargedImeiFontSize = imeiFontSize * 2; // gấp đôi cỡ chữ IMEI
    final enlargedBarcodeHeight = barcodeHeight * 1.8; // tăng chiều cao mã vạch ~80%

    return pw.Container(
      decoration: pw.BoxDecoration(
        border: pw.Border.all(color: PdfColors.black, width: 0.5),
      ),
      child: pw.Column(
        mainAxisAlignment: pw.MainAxisAlignment.center,
        children: [
          // Tên sản phẩm
          pw.Padding(
            padding: const pw.EdgeInsets.symmetric(horizontal: 2),
            child: pw.Text(
              productName,
              style: pw.TextStyle(
                fontSize: titleFontSize,
                fontWeight: pw.FontWeight.bold,
                font: boldFont,
              ),
              textAlign: pw.TextAlign.center,
              maxLines: maxLines,
              overflow: pw.TextOverflow.clip,
            ),
          ),
          pw.SizedBox(height: 1),
          // Mã vạch
          pw.Container(
            height: enlargedBarcodeHeight,
            padding: const pw.EdgeInsets.symmetric(horizontal: 2),
            child: pw.BarcodeWidget(
              barcode: barcodeGen,
              data: imei,
              drawText: false,
              width: 95, // tăng gấp đôi chiều ngang để vạch tách rõ hơn
            ),
          ),
          pw.SizedBox(height: 1),
          // Số IMEI
          pw.Text(
            imei,
            style: pw.TextStyle(
              fontSize: enlargedImeiFontSize,
              font: baseFont,
            ),
            textAlign: pw.TextAlign.center,
          ),
        ],
      ),
    );
  }

  // Tem cho giấy A4 (có nhiều không gian hơn)
  pw.Widget _buildA4Label(Map<String, dynamic> item, Barcode barcodeGen, {pw.Font? baseFont, pw.Font? boldFont}) {
    final productId = item['product_id']?.toString() ?? '';
    final imei = item['imei']?.toString() ?? '';
    final productName = CacheUtil.getProductName(productId);

    return pw.Container(
      decoration: pw.BoxDecoration(
        border: pw.Border.all(color: PdfColors.black, width: 1),
        borderRadius: const pw.BorderRadius.all(pw.Radius.circular(4)),
      ),
      padding: const pw.EdgeInsets.all(8),
      child: pw.Column(
        mainAxisAlignment: pw.MainAxisAlignment.center,
        children: [
          // Tên sản phẩm
          pw.Text(
            productName,
            style: pw.TextStyle(
              fontSize: 12,
              fontWeight: pw.FontWeight.bold,
              font: boldFont,
            ),
            textAlign: pw.TextAlign.center,
            maxLines: 2,
            overflow: pw.TextOverflow.clip,
          ),
          pw.SizedBox(height: 8),
          // Mã vạch
          pw.Container(
            height: 100, // tăng chiều cao mã vạch để nét rõ hơn
            child: pw.BarcodeWidget(
              barcode: barcodeGen,
              data: imei,
              drawText: false,
            ),
          ),
          pw.SizedBox(height: 4),
          // Số IMEI
          pw.Text(
            imei,
            style: pw.TextStyle(
              fontSize: 18, // tăng gấp đôi kích thước chữ IMEI
              font: baseFont,
            ),
            textAlign: pw.TextAlign.center,
          ),
        ],
      ),
    );
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
      // Kiểm tra và yêu cầu quyền lưu trữ (nếu cần) - Android 13+ không cần
      final hasPermission = await StorageHelper.requestStoragePermissionIfNeeded();
      if (!hasPermission) {
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
          .select('id, product_id, imei, status, import_date, return_date, fix_price, send_fix_date, transport_fee, transporter, send_transfer_date, import_transfer_date, sale_price, customer_price, transporter_price, sale_date, saleman, note, import_price, import_currency, warehouse_id, customer, customer_id, cost_price, supplier_id, fix_unit, fix_unit_id');

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

      // ✅ KHÔNG CẦN fetch customer/supplier riêng - đã có sẵn trong data
      // Customer: products.customer
      // Supplier: lấy từ supplier_id qua CacheUtil.getSupplierName()

      var excel = Excel.createExcel();
      Sheet sheet = excel['TonKho']; // ✅ Tạo sheet mới trước
      excel.delete('Sheet1'); // ✅ Xóa sheet mặc định sau

      final headerLabels = <String>[
        'Số thứ tự',
        'Tên sản phẩm',
        'IMEI',
        if (widget.permissions.contains('view_import_price')) 'Giá nhập',
        if (widget.permissions.contains('view_import_price')) 'Đơn vị tiền nhập',
        if (widget.permissions.contains('view_cost_price')) 'Giá vốn',
        'Ngày gửi sửa',
        'Trạng thái',
        'Kho',
        'Ngày nhập',
        'Ngày trả hàng',
        'Tiền fix lỗi',
        'Cước vận chuyển',
        'Đơn vị vận chuyển',
        'Ngày chuyển kho',
        'Ngày nhập kho',
        if (widget.permissions.contains('view_sale_price')) 'Giá bán',
        if (widget.permissions.contains('view_customer')) 'Khách hàng',
        'Tiền cọc',
        'Tiền COD',
        'Ngày bán',
        if (widget.permissions.contains('view_supplier')) 'Nhà cung cấp',
        'Ghi chú',
      ];

      sheet.appendRow(headerLabels.map(TextCellValue.new).toList());
      final columnCount = headerLabels.length;
      final sizingTracker = ExcelSizingTracker(columnCount);
      final styles = ExcelCellStyles.build();

      for (int col = 0; col < columnCount; col++) {
        final cell = sheet.cell(
          CellIndex.indexByColumnRow(columnIndex: col, rowIndex: 0),
        );
        cell.cellStyle = styles.header;
        sizingTracker.update(0, col, headerLabels[col]);
      }

      const multilineHeaders = {'IMEI', 'Ghi chú'};

      var currentRowIndex = 1;
      for (int i = 0; i < allItems.length; i++) {
        final item = allItems[i];
        final productId = item['product_id']?.toString() ?? '';
        final imei = item['imei']?.toString() ?? '';

        // ✅ Lấy customer trực tiếp từ products.customer
        String? customer = item['customer']?.toString();
        
        // ✅ Lấy supplier từ supplier_id qua cache (nhanh hơn nhiều)
        String? supplier;
        if (widget.permissions.contains('view_supplier')) {
          final supplierId = item['supplier_id']?.toString();
          supplier = supplierId != null ? CacheUtil.getSupplierName(supplierId) : null;
        }

        final rowValues = <String>[
          (i + 1).toString(),
          CacheUtil.getProductName(productId),
          imei,
          if (widget.permissions.contains('view_import_price')) item['import_price']?.toString() ?? '',
          if (widget.permissions.contains('view_import_price')) item['import_currency']?.toString() ?? '',
          if (widget.permissions.contains('view_cost_price')) item['cost_price']?.toString() ?? '',
          item['send_fix_date']?.toString() ?? '',
          item['status']?.toString() ?? '',
          CacheUtil.getWarehouseName(item['warehouse_id']?.toString()),
          item['import_date']?.toString() ?? '',
          item['return_date']?.toString() ?? '',
          item['fix_price']?.toString() ?? '',
          item['transport_fee']?.toString() ?? '',
          item['transporter']?.toString() ?? '',
          item['send_transfer_date']?.toString() ?? '',
          item['import_transfer_date']?.toString() ?? '',
          if (widget.permissions.contains('view_sale_price')) item['sale_price']?.toString() ?? '',
          if (widget.permissions.contains('view_customer')) customer ?? '',
          item['customer_price']?.toString() ?? '',
          item['transporter_price']?.toString() ?? '',
          item['sale_date']?.toString() ?? '',
          if (widget.permissions.contains('view_supplier')) supplier ?? '',
          item['note']?.toString() ?? '',
        ];

        sheet.appendRow(rowValues.map(TextCellValue.new).toList());

        for (int col = 0; col < columnCount; col++) {
          final cell = sheet.cell(
            CellIndex.indexByColumnRow(columnIndex: col, rowIndex: currentRowIndex),
          );
          final headerLabel = headerLabels[col];
          final value = rowValues[col];
          final isMultiline = multilineHeaders.contains(headerLabel);
          cell.cellStyle = isMultiline ? styles.multiline : styles.centered;
          sizingTracker.update(currentRowIndex, col, value);
        }
        
        currentRowIndex++;
      }

      sizingTracker.applyToSheet(sheet);

      // Sử dụng StorageHelper để lấy thư mục Downloads (hỗ trợ Android 13+)
      final downloadsDir = await StorageHelper.getDownloadDirectory();
      if (downloadsDir == null) {
        if (mounted) {
          Navigator.pop(context);
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Không thể truy cập thư mục Downloads')),
          );
        }
        setState(() {
          isExporting = false;
        });
        return;
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

  // ✅ Helper function để format số tiền với dấu phân cách hàng nghìn
  String _formatCurrency(num? value) {
    if (value == null) return '';
    return NumberFormat('#,###', 'vi_VN').format(value).replaceAll(',', '.');
  }

  // ✅ Helper function để format ngày tháng theo format: 12:30:40 / 20-12-2025
  String _formatDateTime(String? dateTimeString) {
    if (dateTimeString == null || dateTimeString.isEmpty) return '';
    try {
      final dateTime = DateTime.parse(dateTimeString);
      final hour = dateTime.hour.toString().padLeft(2, '0');
      final minute = dateTime.minute.toString().padLeft(2, '0');
      final second = dateTime.second.toString().padLeft(2, '0');
      final day = dateTime.day.toString().padLeft(2, '0');
      final month = dateTime.month.toString().padLeft(2, '0');
      final year = dateTime.year.toString();
      return '$hour:$minute:$second / $day-$month-$year';
    } catch (e) {
      // Nếu không parse được, trả về chuỗi gốc
      return dateTimeString;
    }
  }

  // ✅ Helper function mở chi tiết khách hàng - ưu tiên dùng customer_id, fallback theo tên
  Future<void> _openCustomerDetails(
    String? customerName,
    BuildContext dialogContext, {
    String? customerId,
  }) async {
    if ((customerName == null || customerName.isEmpty) && (customerId == null || customerId.isEmpty)) {
      return;
    }
    
    try {
      dynamic query = widget.tenantClient
          .from('customers')
          .select('id, name, phone, address, social_link, debt_vnd, debt_cny, debt_usd');

      if (customerId != null && customerId.isNotEmpty) {
        query = query.eq('id', customerId);
      } else {
        query = query.eq('name', customerName);
      }

      final response = await query.maybeSingle();
      
      if (response != null && mounted) {
        // Đóng dialog chi tiết sản phẩm trước
        Navigator.of(dialogContext, rootNavigator: true).pop();
        
        // Đợi một chút để dialog đóng hoàn toàn
        await Future.delayed(const Duration(milliseconds: 100));
        
        if (!mounted) return;
        
        // Mở màn hình khách hàng
        await Navigator.push(
          context,
          MaterialPageRoute(
            builder: (newContext) {
              // Mở dialog chi tiết ngay sau khi màn hình được build
              WidgetsBinding.instance.addPostFrameCallback((_) {
                if (newContext.mounted) {
                  showDialog(
                    context: newContext,
                    builder: (context) => CustomerDetailsDialog(
                      customer: response,
                      tenantClient: widget.tenantClient,
                    ),
                  );
                }
              });
              
              return CustomersScreen(
                permissions: widget.permissions,
                tenantClient: widget.tenantClient,
              );
            },
          ),
        );
      } else {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Không tìm thấy thông tin khách hàng')),
          );
        }
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Không thể mở chi tiết khách hàng: $e')),
        );
      }
    }
  }

  // ✅ Helper function để mở chi tiết nhà cung cấp - ưu tiên supplier_id, có thể fallback theo tên nếu cần
  Future<void> _openSupplierDetails(
    String? supplierId,
    BuildContext dialogContext, {
    String? supplierName,
  }) async {
    if ((supplierId == null || supplierId.isEmpty) &&
        (supplierName == null || supplierName.isEmpty)) {
      return;
    }
    
    try {
      dynamic query = widget.tenantClient
          .from('suppliers')
          .select('id, name, phone, address, social_link, debt_vnd, debt_cny, debt_usd');

      if (supplierId != null && supplierId.isNotEmpty) {
        query = query.eq('id', supplierId);
      } else {
        query = query.eq('name', supplierName);
      }

      final response = await query.maybeSingle();
      
      if (response != null && mounted) {
        // Đóng dialog chi tiết sản phẩm trước
        Navigator.of(dialogContext, rootNavigator: true).pop();
        
        // Đợi một chút để dialog đóng hoàn toàn
        await Future.delayed(const Duration(milliseconds: 100));
        
        if (!mounted) return;
        
        // Mở màn hình nhà cung cấp
        await Navigator.push(
          context,
          MaterialPageRoute(
            builder: (newContext) {
              // Mở dialog chi tiết ngay sau khi màn hình được build
              WidgetsBinding.instance.addPostFrameCallback((_) {
                if (newContext.mounted) {
                  showDialog(
                    context: newContext,
                    builder: (context) => SupplierDetailsDialog(
                      supplier: response,
                      tenantClient: widget.tenantClient,
                    ),
                  );
                }
              });
              
              return SuppliersScreen(
                permissions: widget.permissions,
                tenantClient: widget.tenantClient,
              );
            },
          ),
        );
      } else {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Không tìm thấy thông tin nhà cung cấp')),
          );
        }
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Không thể mở chi tiết nhà cung cấp: $e')),
        );
      }
    }
  }

  // ✅ Helper function để lấy transporter ID từ tên và mở chi tiết
  Future<void> _openTransporterDetails(String? transporterName, BuildContext dialogContext) async {
    if (transporterName == null || transporterName.isEmpty) return;
    
    try {
      final response = await widget.tenantClient
          .from('transporters')
          .select('id, name, phone, address, debt')
          .eq('name', transporterName)
          .maybeSingle();
      
      if (response != null && mounted) {
        // Đóng dialog chi tiết sản phẩm trước
        Navigator.of(dialogContext, rootNavigator: true).pop();
        
        // Đợi một chút để dialog đóng hoàn toàn
        await Future.delayed(const Duration(milliseconds: 100));
        
        if (!mounted) return;
        
        // Mở màn hình đơn vị vận chuyển
        await Navigator.push(
          context,
          MaterialPageRoute(
            builder: (newContext) {
              // Mở dialog chi tiết ngay sau khi màn hình được build
              WidgetsBinding.instance.addPostFrameCallback((_) {
                if (newContext.mounted) {
                  showDialog(
                    context: newContext,
                    builder: (context) => TransporterDetailsDialog(
                      transporter: response,
                      tenantClient: widget.tenantClient,
                    ),
                  );
                }
              });
              
              return TransportersScreen(
                permissions: widget.permissions,
                tenantClient: widget.tenantClient,
              );
            },
          ),
        );
      } else {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Không tìm thấy thông tin đơn vị vận chuyển')),
          );
        }
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Không thể mở chi tiết đơn vị vận chuyển: $e')),
        );
      }
    }
  }

  // ✅ Helper function để mở chi tiết đơn vị fix lỗi - ưu tiên fix_unit_id, fallback theo tên
  Future<void> _openFixerDetails(
    String? fixerName,
    BuildContext dialogContext, {
    String? fixerId,
  }) async {
    if ((fixerName == null || fixerName.isEmpty) && (fixerId == null || fixerId.isEmpty)) {
      return;
    }
    
    try {
      dynamic query = widget.tenantClient
          .from('fix_units')
          .select('id, name, phone, address, social_link, debt_vnd, debt_cny, debt_usd');

      if (fixerId != null && fixerId.isNotEmpty) {
        query = query.eq('id', fixerId);
      } else {
        query = query.eq('name', fixerName);
      }

      final response = await query.maybeSingle();
      
      if (response != null && mounted) {
        // Đóng dialog chi tiết sản phẩm trước
        Navigator.of(dialogContext, rootNavigator: true).pop();
        
        // Đợi một chút để dialog đóng hoàn toàn
        await Future.delayed(const Duration(milliseconds: 100));
        
        if (!mounted) return;
        
        // Mở màn hình đơn vị fix lỗi
        await Navigator.push(
          context,
          MaterialPageRoute(
            builder: (newContext) {
              // Mở dialog chi tiết ngay sau khi màn hình được build
              WidgetsBinding.instance.addPostFrameCallback((_) {
                if (newContext.mounted) {
                  showDialog(
                    context: newContext,
                    builder: (context) => FixerDetailsDialog(
                      fixer: response,
                      tenantClient: widget.tenantClient,
                    ),
                  );
                }
              });
              
              return FixersScreen(
                permissions: widget.permissions,
                tenantClient: widget.tenantClient,
              );
            },
          ),
        );
      } else {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Không tìm thấy thông tin đơn vị fix lỗi')),
          );
        }
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Không thể mở chi tiết đơn vị fix lỗi: $e')),
        );
      }
    }
  }

  void _showProductDetails(Map<String, dynamic> product) async {
    final productId = product['id'] as int;

    // ✅ Ưu tiên lấy tên đối tác theo ID nếu có (không thay đổi dữ liệu trong DB, chỉ enrich để hiển thị)
    final enrichedProduct = Map<String, dynamic>.from(product);
    try {
      // Khách hàng: nếu có customer_id nhưng chưa có tên, tra theo ID
      if (widget.permissions.contains('view_customer')) {
        final customerIdFromProduct = enrichedProduct['customer_id']?.toString();
        final customerNameFromProduct = enrichedProduct['customer']?.toString();
        if ((customerNameFromProduct == null || customerNameFromProduct.isEmpty) &&
            customerIdFromProduct != null &&
            customerIdFromProduct.isNotEmpty) {
          final customerResponse = await widget.tenantClient
              .from('customers')
              .select('name')
              .eq('id', customerIdFromProduct)
              .maybeSingle();
          if (customerResponse != null && customerResponse['name'] != null) {
            enrichedProduct['customer'] = customerResponse['name'] as String;
          }
        }
      }

      // Đơn vị fix lỗi: nếu có fix_unit_id nhưng thiếu tên, lấy từ cache (GlobalCacheManager)
      final fixerIdFromProduct = enrichedProduct['fix_unit_id']?.toString();
      final fixerNameFromProduct = enrichedProduct['fix_unit']?.toString();
      if ((fixerNameFromProduct == null || fixerNameFromProduct.isEmpty) &&
          fixerIdFromProduct != null &&
          fixerIdFromProduct.isNotEmpty) {
        enrichedProduct['fix_unit'] = CacheUtil.getFixerName(fixerIdFromProduct);
      }
    } catch (_) {
      // Nếu lỗi khi enrich, bỏ qua, không ảnh hưởng tới luồng nghiệp vụ
    }

    if (!isEditingNote.containsKey(productId)) {
      isEditingNote[productId] = false;
    }
    if (!noteControllers.containsKey(productId)) {
      noteControllers[productId] = TextEditingController(text: enrichedProduct['note']?.toString() ?? '');
    }

    showDialog(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) {
          final updatedProductIndex = inventoryData.indexWhere((item) => item['id'] == productId);
          final currentProduct = updatedProductIndex != -1 
              ? inventoryData[updatedProductIndex] 
              : enrichedProduct;
          
          final productNameId = currentProduct['product_id']?.toString();
          String? customer = currentProduct['customer']?.toString();
          // ID đối tác lưu trong products
          final String? customerId = currentProduct['customer_id']?.toString();
    String? supplier;
          String? supplierId;
          // Luôn lấy dữ liệu từ database, nhưng chỉ hiển thị khi có quyền
          String? transporter = currentProduct['transporter']?.toString();
          String? fixer = currentProduct['fix_unit']?.toString();
          final String? fixerId = currentProduct['fix_unit_id']?.toString();

    if (widget.permissions.contains('view_supplier')) {
            supplierId = currentProduct['supplier_id']?.toString();
      supplier = supplierId != null ? CacheUtil.getSupplierName(supplierId) : null;
    }

    final details = <String, String?>{
      'Tên sản phẩm': CacheUtil.getProductName(productNameId),
            'IMEI': currentProduct['imei']?.toString(),
            'Trạng thái': currentProduct['status']?.toString(),
            'Kho': CacheUtil.getWarehouseName(currentProduct['warehouse_id']?.toString()),
      if (widget.permissions.contains('view_import_price'))
              'Giá nhập': currentProduct['import_price'] != null 
                  ? '${_formatCurrency(currentProduct['import_price'] as num?)} ${currentProduct['import_currency'] ?? ''}' 
            : null,
      if (widget.permissions.contains('view_cost_price'))
              'Giá vốn': currentProduct['cost_price'] != null 
                  ? _formatCurrency(currentProduct['cost_price'] as num?) 
            : null,
            'Ngày nhập': _formatDateTime(currentProduct['import_date']?.toString()),
      if (widget.permissions.contains('view_supplier') && supplier != null)
        'Nhà cung cấp': supplier,
            'Ngày trả hàng': _formatDateTime(currentProduct['return_date']?.toString()),
            'Tiền fix lỗi': currentProduct['fix_price'] != null 
                ? _formatCurrency(currentProduct['fix_price'] as num?) 
          : null,
            'Ngày gửi fix lỗi': _formatDateTime(currentProduct['send_fix_date']?.toString()),
            if (widget.permissions.contains('view_fixer') && fixer != null && fixer.trim().isNotEmpty)
              'Đơn vị fix lỗi': fixer.trim(),
            'Cước vận chuyển': currentProduct['transport_fee'] != null 
                ? _formatCurrency(currentProduct['transport_fee'] as num?) 
          : null,
            if (widget.permissions.contains('view_transporter') && transporter != null && transporter.trim().isNotEmpty)
              'Đơn vị vận chuyển': transporter.trim(),
            'Ngày chuyển kho': _formatDateTime(currentProduct['send_transfer_date']?.toString()),
            'Ngày nhập kho': _formatDateTime(currentProduct['import_transfer_date']?.toString()),
      if (widget.permissions.contains('view_sale_price'))
              'Giá bán': currentProduct['sale_price'] != null 
                  ? _formatCurrency(currentProduct['sale_price'] as num?) 
            : null,
      if (widget.permissions.contains('view_customer') && customer != null)
        'Khách hàng': customer,
            'Tiền cọc': currentProduct['customer_price'] != null && (currentProduct['customer_price'] as num) > 0
                ? _formatCurrency(currentProduct['customer_price'] as num?)
          : null,
            'Tiền COD': currentProduct['transporter_price'] != null && (currentProduct['transporter_price'] as num) > 0
                ? _formatCurrency(currentProduct['transporter_price'] as num?)
          : null,
            'Ngày bán': _formatDateTime(currentProduct['sale_date']?.toString()),
            'Nhân viên bán': currentProduct['saleman']?.toString(),
            'Ghi chú': currentProduct['note']?.toString(),
          };

          return AlertDialog(
          title: const Text('Chi tiết sản phẩm'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                ...details.entries
                    .where((entry) => entry.value != null && entry.value!.isNotEmpty)
                      .map((entry) {
                        final isPartner = entry.key == 'Khách hàng' || 
                                         entry.key == 'Nhà cung cấp' || 
                                         entry.key == 'Đơn vị vận chuyển' ||
                                         entry.key == 'Đơn vị fix lỗi';
                        return Padding(
                          padding: const EdgeInsets.symmetric(vertical: 4.0),
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                '${entry.key}: ',
                                style: const TextStyle(fontWeight: FontWeight.bold),
                              ),
                              Expanded(
                                child: isPartner
                                    ? InkWell(
                                        onTap: () {
                                          // Hiển thị menu với 2 tùy chọn cho đối tác
                                          showModalBottomSheet(
                                            context: context,
                                            builder: (context) => SafeArea(
                                              child: Column(
                                                mainAxisSize: MainAxisSize.min,
                                                children: [
                                                  ListTile(
                                                    leading: const Icon(Icons.copy),
                                                    title: const Text('Sao chép'),
                                                    onTap: () {
                                                      Clipboard.setData(ClipboardData(text: entry.value!));
                                                      Navigator.pop(context);
                                                      ScaffoldMessenger.of(context).showSnackBar(
                                                        const SnackBar(
                                                          content: Text('Đã sao chép vào clipboard'),
                                                          duration: Duration(seconds: 1),
                                                        ),
                                                      );
                                                    },
                                                  ),
                                                  ListTile(
                                                    leading: const Icon(Icons.visibility),
                                                    title: const Text('Xem đối tác'),
                                                    onTap: () {
                                                      Navigator.pop(context);
                                                      if (entry.key == 'Khách hàng') {
                                                        _openCustomerDetails(
                                                          entry.value,
                                                          context,
                                                          customerId: customerId,
                                                        );
                                                      } else if (entry.key == 'Nhà cung cấp') {
                                                        _openSupplierDetails(
                                                          supplierId,
                                                          context,
                                                          supplierName: supplier,
                                                        );
                                                      } else if (entry.key == 'Đơn vị vận chuyển') {
                                                        _openTransporterDetails(entry.value, context);
                                                      } else if (entry.key == 'Đơn vị fix lỗi') {
                                                        _openFixerDetails(
                                                          entry.value,
                                                          context,
                                                          fixerId: fixerId,
                                                        );
                                                      }
                                                    },
                                                  ),
                                                ],
                                              ),
                                            ),
                                          );
                                        },
                                        child: Text(
                                          entry.value!,
                                          style: const TextStyle(
                                            fontWeight: FontWeight.normal,
                                            color: Colors.blue,
                                            decoration: TextDecoration.underline,
                                          ),
                                        ),
                                      )
                                    : GestureDetector(
                                        onLongPress: () {
                                          // Chỉ copy cho các trường khác
                                          Clipboard.setData(ClipboardData(text: entry.value!));
                                          ScaffoldMessenger.of(context).showSnackBar(
                                            const SnackBar(
                                              content: Text('Đã sao chép vào clipboard'),
                                              duration: Duration(seconds: 1),
                                            ),
                                          );
                                        },
                                        child: SelectableText(
                                          entry.value!,
                                          style: const TextStyle(fontWeight: FontWeight.normal),
                                        ),
                                      ),
                              ),
                            ],
                          ),
                        );
                      }),
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
                    if (mounted) {
                      await Future.delayed(const Duration(milliseconds: 100));
                  setDialogState(() {
                    isEditingNote[productId] = false;
                  });
                    }
                } else {
                  setDialogState(() {
                    isEditingNote[productId] = true;
                  });
                }
              },
              child: Text(
                (isEditingNote[productId] ?? false) ? 'Xong' : 'Ghi chú',
                style: const TextStyle(color: Colors.blue),
              ),
            ),
            const SizedBox(width: 8),
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Đóng'),
            ),
          ],
          );
        },
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
                            GestureDetector(
                              onLongPress: () {
                                final imei = item['imei']?.toString() ?? '';
                                if (imei.isNotEmpty) {
                                  Clipboard.setData(ClipboardData(text: imei));
                                  ScaffoldMessenger.of(context).showSnackBar(
                                    const SnackBar(
                                      content: Text('Đã sao chép IMEI vào clipboard'),
                                      duration: Duration(seconds: 1),
                                    ),
                                  );
                                }
                              },
                              child: Text(
                              'IMEI: ${item['imei']?.toString() ?? ''}',
                              style: const TextStyle(fontSize: 14),
                              overflow: TextOverflow.ellipsis,
                            ),
                            ),
                            if (item['note'] != null && item['note'].toString().isNotEmpty) ...[
                              const SizedBox(height: 2),
                              Text(
                                'Ghi chú: ${item['note']}',
                                style: const TextStyle(fontSize: 12, color: Colors.blue),
                                overflow: TextOverflow.ellipsis,
                                maxLines: 1,
                              ),
                            ],
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
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                GestureDetector(
                  onLongPress: () => _printLabels(showSettings: true),
                  child: FloatingActionButton.extended(
                  onPressed: _printLabels,
                  label: const Text('In Tem'),
                  icon: const Icon(Icons.print),
                  backgroundColor: Colors.green,
                  foregroundColor: Colors.white,
                  heroTag: 'print_btn',
                  ),
                ),
                const SizedBox(height: 12),
                FloatingActionButton.extended(
                  onPressed: _exportToExcel,
                  label: const Text('Xuất Excel'),
                  icon: const Icon(Icons.file_download),
                  backgroundColor: Colors.blue,
                  foregroundColor: Colors.white,
                  heroTag: 'excel_btn',
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// Widget dialog cài đặt in tem đơn giản
class _PrintSettingsDialog extends StatefulWidget {
  final String defaultPrintType;
  final int defaultLabelsPerRow;
  final int defaultLabelHeight;

  const _PrintSettingsDialog({
    required this.defaultPrintType,
    required this.defaultLabelsPerRow,
    required this.defaultLabelHeight,
  });

  @override
  State<_PrintSettingsDialog> createState() => _PrintSettingsDialogState();
}

class _PrintSettingsDialogState extends State<_PrintSettingsDialog> {
  late String _selectedPrintType;
  late int _selectedLabelsPerRow;
  late int _selectedLabelHeight;
  bool _saveAsDefault = false;

  @override
  void initState() {
    super.initState();
    _selectedPrintType = widget.defaultPrintType;
    _selectedLabelsPerRow = widget.defaultLabelsPerRow;
    _selectedLabelHeight = widget.defaultLabelHeight;
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Loại máy in
        const Text(
          'Loại máy in:',
          style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14),
        ),
        const SizedBox(height: 8),
        RadioListTile<String>(
          dense: true,
          contentPadding: EdgeInsets.zero,
          title: const Text('Máy in thông thường (A4)'),
          subtitle: const Text('In 4 tem trên 1 tờ giấy A4', style: TextStyle(fontSize: 12)),
          value: 'a4',
          groupValue: _selectedPrintType,
          onChanged: (value) {
            setState(() {
              _selectedPrintType = value!;
            });
          },
        ),
        RadioListTile<String>(
          dense: true,
          contentPadding: EdgeInsets.zero,
          title: const Text('Máy in tem nhiệt'),
          subtitle: const Text('Cuộn tem nhãn (mọi loại máy)', style: TextStyle(fontSize: 12)),
          value: 'thermal',
          groupValue: _selectedPrintType,
          onChanged: (value) {
            setState(() {
              _selectedPrintType = value!;
            });
          },
        ),
        // Tạm thời ẩn Bluetooth trên iOS do package có bug
        if (!Platform.isIOS)
          RadioListTile<String>(
            dense: true,
            contentPadding: EdgeInsets.zero,
            title: const Text('In qua Bluetooth'),
            subtitle: const Text('Kết nối trực tiếp với máy in Bluetooth (CLabel CT221B)', style: TextStyle(fontSize: 12)),
            value: 'bluetooth',
            groupValue: _selectedPrintType,
            onChanged: (value) {
              setState(() {
                _selectedPrintType = value!;
              });
            },
          ),
        if (Platform.isIOS)
          RadioListTile<String>(
            dense: true,
            contentPadding: EdgeInsets.zero,
            title: const Text('In qua Bluetooth (iOS - Tạm thời không khả dụng)'),
            subtitle: const Text('Tính năng này đang được phát triển cho iOS. Vui lòng sử dụng in PDF/thermal.', style: TextStyle(fontSize: 12, color: Colors.orange)),
            value: 'bluetooth_disabled',
            groupValue: 'bluetooth_disabled',
            onChanged: null, // Disabled
          ),
        
        // Layout (chỉ hiện khi chọn tem nhiệt)
        if (_selectedPrintType == 'thermal') ...[
          const Divider(),
          const SizedBox(height: 8),
          const Text(
            'Chiều cao tem (mm):',
            style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14),
          ),
          const SizedBox(height: 8),
          RadioListTile<int>(
            dense: true,
            contentPadding: EdgeInsets.zero,
            title: const Text('20mm'),
            subtitle: const Text('Tem nhỏ, chỉ hiển thị tối thiểu', style: TextStyle(fontSize: 12)),
            value: 20,
            groupValue: _selectedLabelHeight,
            onChanged: (value) {
              setState(() {
                _selectedLabelHeight = value!;
              });
            },
          ),
          RadioListTile<int>(
            dense: true,
            contentPadding: EdgeInsets.zero,
            title: const Text('25mm'),
            subtitle: const Text('Tem vừa, hiển thị gọn', style: TextStyle(fontSize: 12)),
            value: 25,
            groupValue: _selectedLabelHeight,
            onChanged: (value) {
              setState(() {
                _selectedLabelHeight = value!;
              });
            },
          ),
          RadioListTile<int>(
            dense: true,
            contentPadding: EdgeInsets.zero,
            title: const Text('30mm'),
            subtitle: const Text('Tem tiêu chuẩn (phổ biến)', style: TextStyle(fontSize: 12)),
            value: 30,
            groupValue: _selectedLabelHeight,
            onChanged: (value) {
              setState(() {
                _selectedLabelHeight = value!;
              });
            },
          ),
          RadioListTile<int>(
            dense: true,
            contentPadding: EdgeInsets.zero,
            title: const Text('40mm'),
            subtitle: const Text('Tem lớn, nhiều không gian', style: TextStyle(fontSize: 12)),
            value: 40,
            groupValue: _selectedLabelHeight,
            onChanged: (value) {
              setState(() {
                _selectedLabelHeight = value!;
              });
            },
          ),
          const Divider(),
          const SizedBox(height: 8),
          const Text(
            'Số tem trên 1 hàng:',
            style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14),
          ),
          const SizedBox(height: 4),
          const Text(
            'Tùy thuộc độ rộng cuộn giấy của máy bạn',
            style: TextStyle(fontSize: 11, color: Colors.grey),
          ),
          const SizedBox(height: 8),
          RadioListTile<int>(
            dense: true,
            contentPadding: EdgeInsets.zero,
            title: const Text('1 tem/hàng'),
            subtitle: const Text('Cuộn 40mm (phổ biến nhất)', style: TextStyle(fontSize: 12)),
            value: 1,
            groupValue: _selectedLabelsPerRow,
            onChanged: (value) {
              setState(() {
                _selectedLabelsPerRow = value!;
              });
            },
          ),
          RadioListTile<int>(
            dense: true,
            contentPadding: EdgeInsets.zero,
            title: const Text('2 tem/hàng'),
            subtitle: const Text('Cuộn 80-90mm', style: TextStyle(fontSize: 12)),
            value: 2,
            groupValue: _selectedLabelsPerRow,
            onChanged: (value) {
              setState(() {
                _selectedLabelsPerRow = value!;
              });
            },
          ),
          RadioListTile<int>(
            dense: true,
            contentPadding: EdgeInsets.zero,
            title: const Text('3 tem/hàng'),
            subtitle: const Text('Cuộn 120-130mm', style: TextStyle(fontSize: 12)),
            value: 3,
            groupValue: _selectedLabelsPerRow,
            onChanged: (value) {
              setState(() {
                _selectedLabelsPerRow = value!;
              });
            },
          ),
        ],
        
        const Divider(),
        const SizedBox(height: 8),
        
        // Checkbox ghi nhớ
        CheckboxListTile(
          dense: true,
          contentPadding: EdgeInsets.zero,
          title: const Text('Ghi nhớ và dùng làm mặc định'),
          subtitle: const Text(
            'Lần sau sẽ tự động dùng cài đặt này',
            style: TextStyle(fontSize: 11),
          ),
          value: _saveAsDefault,
          onChanged: (value) {
            setState(() {
              _saveAsDefault = value ?? false;
            });
          },
        ),
        
        const SizedBox(height: 16),
        
        // Buttons
        Row(
          mainAxisAlignment: MainAxisAlignment.end,
          children: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Hủy'),
            ),
            const SizedBox(width: 8),
            ElevatedButton.icon(
              onPressed: () {
                Navigator.pop(context, {
                  'printType': _selectedPrintType,
                  'labelsPerRow': _selectedLabelsPerRow,
                  'labelHeight': _selectedLabelHeight,
                  'saveAsDefault': _saveAsDefault,
                });
              },
              icon: const Icon(Icons.print),
              label: const Text('In Tem'),
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.green,
                foregroundColor: Colors.white,
              ),
            ),
          ],
        ),
      ],
    );
  }
}