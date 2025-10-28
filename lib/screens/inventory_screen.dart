import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:excel/excel.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:open_file/open_file.dart';
import 'dart:io';
import 'dart:async';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';
import 'package:barcode/barcode.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:intl/intl.dart';
import '../helpers/global_cache_manager.dart';

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
  String _defaultPrintType = 'a4'; // 'a4' hoặc 'thermal'
  int _defaultLabelsPerRow = 1; // 1, 2, hoặc 3
  int _defaultLabelHeight = 30; // 20, 25, 30, 40mm

  @override
  void initState() {
    super.initState();
    _loadPrintSettings();
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
  
  Future<void> _loadPrintSettings() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      setState(() {
        _defaultPrintType = prefs.getString('default_print_type') ?? 'a4';
        _defaultLabelsPerRow = prefs.getInt('default_labels_per_row') ?? 1;
        _defaultLabelHeight = prefs.getInt('default_label_height') ?? 30;
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

  Future<void> _printLabels() async {
    // Hiển thị dialog đơn giản với option ghi nhớ
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

    final printType = result['printType'] as String;
    final labelsPerRow = result['labelsPerRow'] as int;
    final labelHeight = result['labelHeight'] as int;
    final saveAsDefault = result['saveAsDefault'] as bool;

    // Lưu cài đặt nếu user chọn
    if (saveAsDefault) {
      await _savePrintSettings(printType, labelsPerRow, labelHeight);
      setState(() {
        _defaultPrintType = printType;
        _defaultLabelsPerRow = labelsPerRow;
        _defaultLabelHeight = labelHeight;
      });
    }

    try {
      // Lấy dữ liệu đã lọc
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
                build: (context) => _buildThermalLabel(item, barcodeGen, labelHeight),
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
                build: (context) {
                  return pw.Row(
                    mainAxisAlignment: pw.MainAxisAlignment.spaceEvenly,
                    children: rowItems.map((item) {
                      return pw.Container(
                        width: 38 * PdfPageFormat.mm, // 40mm - margin
                        child: _buildThermalLabel(item, barcodeGen, labelHeight),
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
              build: (context) {
                return pw.Column(
                  children: [
                    // Hàng đầu tiên (2 tem)
                    pw.Row(
                      crossAxisAlignment: pw.CrossAxisAlignment.start,
                      children: [
                        if (pageItems.isNotEmpty) 
                          pw.Expanded(child: _buildA4Label(pageItems[0], barcodeGen)),
                        pw.SizedBox(width: 10),
                        if (pageItems.length > 1) 
                          pw.Expanded(child: _buildA4Label(pageItems[1], barcodeGen))
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
                          pw.Expanded(child: _buildA4Label(pageItems[2], barcodeGen))
                        else
                          pw.Expanded(child: pw.Container()),
                        pw.SizedBox(width: 10),
                        if (pageItems.length > 3) 
                          pw.Expanded(child: _buildA4Label(pageItems[3], barcodeGen))
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

  // Tem cho máy in nhiệt (tự động điều chỉnh theo chiều cao)
  pw.Widget _buildThermalLabel(Map<String, dynamic> item, Barcode barcodeGen, int labelHeight) {
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
              ),
              textAlign: pw.TextAlign.center,
              maxLines: maxLines,
              overflow: pw.TextOverflow.clip,
            ),
          ),
          pw.SizedBox(height: 1),
          // Mã vạch
          pw.Container(
            height: barcodeHeight,
            padding: const pw.EdgeInsets.symmetric(horizontal: 2),
            child: pw.BarcodeWidget(
              barcode: barcodeGen,
              data: imei,
              drawText: false,
              width: 36,
            ),
          ),
          pw.SizedBox(height: 1),
          // Số IMEI
          pw.Text(
            imei,
            style: pw.TextStyle(
              fontSize: imeiFontSize,
            ),
            textAlign: pw.TextAlign.center,
          ),
        ],
      ),
    );
  }

  // Tem cho giấy A4 (có nhiều không gian hơn)
  pw.Widget _buildA4Label(Map<String, dynamic> item, Barcode barcodeGen) {
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
            ),
            textAlign: pw.TextAlign.center,
            maxLines: 2,
            overflow: pw.TextOverflow.clip,
          ),
          pw.SizedBox(height: 8),
          // Mã vạch
          pw.Container(
            height: 60,
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
            style: const pw.TextStyle(
              fontSize: 10,
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

      // ✅ KHÔNG CẦN fetch customer/supplier riêng - đã có sẵn trong data
      // Customer: products.customer
      // Supplier: lấy từ supplier_id qua CacheUtil.getSupplierName()

      var excel = Excel.createExcel();
      Sheet sheet = excel['TonKho']; // ✅ Tạo sheet mới trước
      excel.delete('Sheet1'); // ✅ Xóa sheet mặc định sau

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

        // ✅ Lấy customer trực tiếp từ products.customer
        String? customer = item['customer']?.toString();
        
        // ✅ Lấy supplier từ supplier_id qua cache (nhanh hơn nhiều)
        String? supplier;
        if (widget.permissions.contains('view_supplier')) {
          final supplierId = item['supplier_id']?.toString();
          supplier = supplierId != null ? CacheUtil.getSupplierName(supplierId) : null;
        }

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

  // ✅ Helper function để format số tiền với dấu phân cách hàng nghìn
  String _formatCurrency(num? value) {
    if (value == null) return '';
    return NumberFormat('#,###', 'vi_VN').format(value).replaceAll(',', '.');
  }

  void _showProductDetails(Map<String, dynamic> product) async {
    final productId = product['id'] as int;
    final productNameId = product['product_id']?.toString();

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
      'Kho': CacheUtil.getWarehouseName(product['warehouse_id']?.toString()),
      if (widget.permissions.contains('view_import_price'))
        'Giá nhập': product['import_price'] != null 
            ? '${_formatCurrency(product['import_price'] as num?)} ${product['import_currency'] ?? ''}' 
            : null,
      if (widget.permissions.contains('view_cost_price'))
        'Giá vốn': product['cost_price'] != null 
            ? _formatCurrency(product['cost_price'] as num?) 
            : null,
      'Ngày nhập': product['import_date']?.toString(),
      if (widget.permissions.contains('view_supplier') && supplier != null)
        'Nhà cung cấp': supplier,
      'Ngày trả hàng': product['return_date']?.toString(),
      'Tiền fix lỗi': product['fix_price'] != null 
          ? _formatCurrency(product['fix_price'] as num?) 
          : null,
      'Ngày gửi fix lỗi': product['send_fix_date']?.toString(),
      'Cước vận chuyển': product['transport_fee'] != null 
          ? _formatCurrency(product['transport_fee'] as num?) 
          : null,
      'Đơn vị vận chuyển': product['transporter']?.toString(),
      'Ngày chuyển kho': product['send_transfer_date']?.toString(),
      'Ngày nhập kho': product['import_transfer_date']?.toString(),
      if (widget.permissions.contains('view_sale_price'))
        'Giá bán': product['sale_price'] != null 
            ? _formatCurrency(product['sale_price'] as num?) 
            : null,
      if (widget.permissions.contains('view_customer') && customer != null)
        'Khách hàng': customer,
      'Tiền cọc': product['customer_price'] != null && (product['customer_price'] as num) > 0
          ? _formatCurrency(product['customer_price'] as num?)
          : null,
      'Tiền COD': product['transporter_price'] != null && (product['transporter_price'] as num) > 0
          ? _formatCurrency(product['transporter_price'] as num?)
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
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                FloatingActionButton.extended(
                  onPressed: _printLabels,
                  label: const Text('In Tem'),
                  icon: const Icon(Icons.print),
                  backgroundColor: Colors.green,
                  foregroundColor: Colors.white,
                  heroTag: 'print_btn',
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