import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:excel/excel.dart';
import 'package:file_picker/file_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:share_plus/share_plus.dart';
import 'dart:io';
import 'package:device_info_plus/device_info_plus.dart';

class ExcelReportScreen extends StatefulWidget {
  final List<String> permissions;
  final SupabaseClient tenantClient;

  const ExcelReportScreen({
    super.key,
    required this.permissions,
    required this.tenantClient,
  });

  @override
  _ExcelReportScreenState createState() => _ExcelReportScreenState();
}

class _ExcelReportScreenState extends State<ExcelReportScreen> {
  List<String> reportFiles = [];

  @override
  void initState() {
    super.initState();
    _loadReportFiles();
  }

  Future<Directory> _getDownloadDirectory() async {
    Directory directory;
    if (Platform.isAndroid) {
      directory = Directory('/storage/emulated/0/Download');
      if (!await directory.exists()) {
        await directory.create(recursive: true);
      }
    } else {
      directory = await getApplicationDocumentsDirectory();
    }
    return directory;
  }

  Future<void> _loadReportFiles() async {
    try {
      final downloadsDir = await _getDownloadDirectory();
      final files = downloadsDir.listSync();
      setState(() {
        reportFiles = files
            .where((file) => file.path.endsWith('.xlsx'))
            .map((file) => file.path)
            .toList();
      });
      print('Loaded report files: $reportFiles');
    } catch (e) {
      print('Error loading report files: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Lỗi khi tải danh sách báo cáo: $e')),
        );
      }
    }
  }

  void _showSuccessDialog(BuildContext context, String message) {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
        ),
        backgroundColor: Colors.white,
        title: const Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.check_circle, color: Colors.green, size: 30),
            SizedBox(width: 8),
            Text(
              'Thành công',
              style: TextStyle(
                fontSize: 20,
                fontWeight: FontWeight.bold,
                color: Colors.black,
              ),
            ),
          ],
        ),
        content: Text(
          message,
          style: const TextStyle(fontSize: 16, color: Colors.black87),
          textAlign: TextAlign.center,
        ),
        actions: [
          Center(
            child: ElevatedButton(
              onPressed: () => Navigator.pop(context),
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.blue,
                foregroundColor: Colors.white,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(8),
                ),
                padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
              ),
              child: const Text('Đóng', style: TextStyle(fontSize: 16)),
            ),
          ),
        ],
      ),
    );
  }

  Future<bool> _requestStoragePermission() async {
    if (Platform.isAndroid) {
      final deviceInfo = DeviceInfoPlugin();
      final androidInfo = await deviceInfo.androidInfo;
      final sdkInt = androidInfo.version.sdkInt;

      if (sdkInt < 30) {
        var status = await Permission.storage.status;
        if (!status.isGranted) {
          status = await Permission.storage.request();
          if (!status.isGranted) {
            if (mounted) {
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(
                  content: Text(
                      'Cần cấp quyền truy cập bộ nhớ để lưu hoặc đọc file. Vui lòng cấp quyền trong cài đặt.'),
                ),
              );
              await openAppSettings();
            }
            return false;
          }
        }
        return true;
      } else {
        if (sdkInt >= 30) {
          var status = await Permission.manageExternalStorage.status;
          if (!status.isGranted) {
            status = await Permission.manageExternalStorage.request();
            if (!status.isGranted) {
              if (mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(
                    content: Text(
                        'Cần cấp quyền truy cập bộ nhớ để lưu và đọc file. Vui lòng cấp quyền "Truy cập tất cả file" trong cài đặt.'),
                  ),
                );
                await openAppSettings();
              }
              return false;
            }
          }
          return true;
        } else {
          var status = await Permission.storage.status;
          if (!status.isGranted) {
            status = await Permission.storage.request();
            if (!status.isGranted) {
              if (mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(
                    content: Text(
                        'Cần cấp quyền truy cập bộ nhớ để lưu hoặc đọc file. Vui lòng cấp quyền trong cài đặt.'),
                  ),
                );
                await openAppSettings();
              }
              return false;
            }
          }
          return true;
        }
      }
    }
    return true;
  }

  String getExcelColumnName(int colIndex) {
    String columnName = '';
    int index = colIndex;
    while (index >= 0) {
      columnName = String.fromCharCode(65 + (index % 26)) + columnName;
      index = (index ~/ 26) - 1;
    }
    return columnName;
  }

  Future<Map<String, dynamic>> _createExcelFile(Map<String, dynamic> params) async {
    final tables = params['tables'] as List<Map<String, String>>;
    final columnTranslations = params['columnTranslations'] as Map<String, Map<String, String>>;
    final tableData = params['tableData'] as Map<String, List<Map<String, dynamic>>>;
    final tenantClient = params['tenantClient'] as SupabaseClient;

    // Lấy ánh xạ product_id -> name từ bảng products_name
    final productResponse = await tenantClient.from('products_name').select('id, products');
    final productIdToName = <String, String>{};
    for (var product in productResponse) {
      productIdToName[product['id'].toString()] = product['products'].toString();
    }

    // Lấy ánh xạ warehouse_id -> name từ bảng warehouses
    final warehouseResponse = await tenantClient.from('warehouses').select('id, name');
    final warehouseIdToName = <String, String>{};
    for (var warehouse in warehouseResponse) {
      warehouseIdToName[warehouse['id'].toString()] = warehouse['name'].toString();
    }

    var excel = Excel.createExcel();
    excel.delete('Sheet1');

    final numericColumns = [
      'quantity',
      'min_value',
      'max_value',
      'balance',
      'debt_vnd',
      'debt_cny',
      'debt_usd',
      'amount',
      'receive_amount',
      'from_amount',
      'to_amount',
      'price',
      'total_amount',
      'transport_fee',
      'cost_price',
      'fix_price',
      'sale_price',
      'import_price',
      'profit',
      'rate_vnd_cny',
      'rate_vnd_usd',
      'cost',
      'customer_price',
      'transporter_price',
      'debt',
    ];

    for (var table in tables) {
      final tableName = table['name']!;
      final displayName = table['display']!;
      final data = tableData[tableName] ?? [];

      var sheet = excel[displayName];
      final headerColumns = columnTranslations[tableName]!.keys.toList();
      final dataColumns = columnTranslations[tableName]!.values.toList();

      for (var i = 0; i < headerColumns.length; i++) {
        final columnLetter = getExcelColumnName(i);
        sheet
            .cell(CellIndex.indexByString("${columnLetter}1"))
            .value = TextCellValue(headerColumns[i]);
      }

      if (data.isNotEmpty) {
        for (var rowIndex = 0; rowIndex < data.length; rowIndex++) {
          final row = data[rowIndex];
          for (var colIndex = 0; colIndex < dataColumns.length; colIndex++) {
            final columnName = dataColumns[colIndex];
            final cellValueRaw = row[columnName];
            String cellValueString;

            if (columnName == 'product_name') {
              final productId = row['product_id']?.toString();
              cellValueString = productId != null ? productIdToName[productId] ?? '' : '';
            } else if (columnName == 'warehouse_name') {
              final warehouseId = row['warehouse_id']?.toString();
              cellValueString = warehouseId != null ? warehouseIdToName[warehouseId] ?? '' : '';
            } else if (numericColumns.contains(columnName)) {
              if (cellValueRaw != null) {
                final doubleValue = double.tryParse(cellValueRaw.toString());
                cellValueString = doubleValue != null ? doubleValue.toInt().toString() : '';
              } else {
                cellValueString = '';
              }
            } else {
              cellValueString = cellValueRaw?.toString() ?? '';
            }

            final columnLetter = getExcelColumnName(colIndex);
            sheet
                .cell(CellIndex.indexByString("${columnLetter}${rowIndex + 2}"))
                .value = TextCellValue(cellValueString);
          }
        }
      }
    }

    if (excel.sheets.containsKey('Sheet1')) {
      excel.delete('Sheet1');
      print('Sheet1 đã được xóa trước khi xuất file.');
    } else {
      print('Không tìm thấy Sheet1 sau khi tạo các sheet.');
    }

    final excelBytes = excel.encode();
    if (excelBytes == null) {
      throw Exception('Không thể tạo file Excel');
    }

    final now = DateTime.now();
    final fileName = 'Báo Cáo Tổng Hợp ${now.day}_${now.month}_${now.year} ${now.hour}_${now.minute}_${now.second}.xlsx';

    return {
      'bytes': excelBytes,
      'fileName': fileName,
    };
  }

  Future<void> _exportExcel() async {
    try {
      final hasPermission = await _requestStoragePermission();
      if (!hasPermission) {
        print('Storage permission denied');
        return;
      }

      print('Starting Excel export process');

      showDialog(
        context: context,
        barrierDismissible: false,
        builder: (context) => const Center(child: CircularProgressIndicator()),
      );

      final tables = [
        {'name': 'fix_units', 'display': 'Đơn vị sửa chữa'},
        {'name': 'import_orders', 'display': 'Phiếu nhập hàng'},
        {'name': 'products', 'display': 'Sản phẩm'},
        {'name': 'customers', 'display': 'Khách hàng'},
        {'name': 'fix_receive_orders', 'display': 'Phiếu nhận sửa'},
        {'name': 'fix_send_orders', 'display': 'Phiếu gửi sửa'},
        {'name': 'financial_orders', 'display': 'Phiếu tài chính'},
        {'name': 'suppliers', 'display': 'Nhà cung cấp'},
        {'name': 'reimport_orders', 'display': 'Phiếu nhập lại hàng'},
        {'name': 'transporters', 'display': 'Đơn vị vận chuyển'},
        {'name': 'shipping_rates', 'display': 'Cước vận chuyển'},
        {'name': 'warehouses', 'display': 'Kho hàng'},
        {'name': 'sale_orders', 'display': 'Phiếu bán hàng'},
        {'name': 'return_orders', 'display': 'Phiếu trả hàng'},
        {'name': 'financial_accounts', 'display': 'Tài khoản tài chính'},
        {'name': 'transporter_orders', 'display': 'Phiếu vận chuyển'},
        {'name': 'products_name', 'display': 'Tên sản phẩm'},
      ];

      final tableData = await _fetchAllData(tables.map((t) => t['name']!).toList());

      final columnTranslations = {
        'fix_units': {
          'ID': 'id',
          'Tên': 'name',
          'Số điện thoại': 'phone',
          'Địa chỉ': 'address',
          'Ghi chú': 'note',
          'Công nợ VND': 'debt_vnd',
          'Công nợ CNY': 'debt_cny',
          'Công nợ USD': 'debt_usd',
          'Đã hủy': 'iscancelled',
        },
        'import_orders': {
          'ID': 'id',
          'Nhà cung cấp': 'supplier',
          'Sản phẩm': 'product_name',
          'ID Sản phẩm': 'product_id',
          'IMEI': 'imei',
          'Số lượng': 'quantity',
          'Giá': 'price',
          'Đơn vị tiền': 'currency',
          'Tài khoản': 'account',
          'Ghi chú': 'note',
          'Ngày tạo': 'created_at',
          'Tổng tiền': 'total_amount',
          'Kho hàng': 'warehouse_name',
          'ID Kho': 'warehouse_id',
          'Đã hủy': 'iscancelled',
        },
        'products': {
          'ID': 'id',
          'ID Sản phẩm': 'product_id',
          'Tên': 'name',
          'IMEI': 'imei',
          'Giá nhập': 'import_price',
          'Đơn vị tiền nhập': 'import_currency',
          'Nhà cung cấp': 'supplier',
          'Ngày nhập': 'import_date',
          'Trạng thái': 'status',
          'Đơn vị sửa chữa': 'fix_unit',
          'Giá sửa': 'fix_price',
          'Đơn vị tiền sửa': 'fix_currency',
          'Giá bán': 'sale_price',
          'Khách hàng': 'customer',
          'Đơn vị ship COD': 'transporter',
          'Phí vận chuyển': 'transport_fee',
          'Giá vốn': 'cost_price',
          'Ngày gửi vận chuyển': 'send_transfer_date',
          'Ngày nhập vận chuyển': 'import_transfer_date',
          'Ngày trả hàng': 'return_date',
          'Ngày gửi sửa': 'send_fix_date',
          'Ngày nhận sửa': 'fix_receive_date',
          'ID danh mục': 'category_id',
          'Ngày bán': 'sale_date',
          'Lợi nhuận': 'profit',
          'Tiền khách cọc': 'customer_price',
          'Tiền COD vận': 'transporter_price',
          'ID Kho': 'warehouse_id',
          'Tên Kho': 'warehouse_name',
        },
        'customers': {
          'ID': 'id',
          'Tên': 'name',
          'Số điện thoại': 'phone',
          'Địa chỉ': 'address',
          'Ghi chú': 'note',
          'Link mạng xã hội': 'social_link',
          'Công nợ VND': 'debt_vnd',
          'Công nợ CNY': 'debt_cny',
          'Công nợ USD': 'debt_usd',
          'Đã hủy': 'iscancelled',
        },
        'fix_receive_orders': {
          'ID': 'id',
          'Ticket ID': 'ticket_id',
          'Đơn vị sửa chữa': 'fixer',
          'Sản phẩm': 'product',
          'ID Sản phẩm': 'product_id',
          'IMEI': 'imei',
          'Số lượng': 'quantity',
          'Giá': 'price',
          'Đơn vị tiền': 'currency',
          'Tài khoản': 'account',
          'Ngày tạo': 'created_at',
          'Đã hủy': 'iscancelled',
          'Ghi chú': 'note',
          'ID Kho': 'warehouse_id',
        },
        'fix_send_orders': {
          'ID': 'id',
          'Ticket ID': 'ticket_id',
          'Đơn vị sửa chữa': 'fixer',
          'Sản phẩm': 'product',
          'ID Sản phẩm': 'product_id',
          'IMEI': 'imei',
          'Số lượng': 'quantity',
          'Ngày tạo': 'created_at',
          'Đã hủy': 'iscancelled',
          'Ghi chú': 'note',
          'ID Kho': 'warehouse_id',
        },
        'financial_orders': {
          'ID': 'id',
          'Loại phiếu': 'type',
          'Loại đối tác': 'partner_type',
          'Tên đối tác': 'partner_name',
          'Số tiền': 'amount',
          'Đơn vị tiền': 'currency',
          'Tài khoản': 'account',
          'Ghi chú': 'note',
          'Ngày tạo': 'created_at',
          'Tỷ giá VND-CNY': 'rate_vnd_cny',
          'Tỷ giá VND-USD': 'rate_vnd_usd',
          'Số tiền nhận': 'receive_amount',
          'Tài khoản nguồn': 'from_account',
          'Tài khoản đích': 'to_account',
          'Số tiền nguồn': 'from_amount',
          'Đơn vị tiền nguồn': 'from_currency',
          'Số tiền đích': 'to_amount',
          'Đơn vị tiền đích': 'to_currency',
          'Đã hủy': 'iscancelled',
        },
        'suppliers': {
          'ID': 'id',
          'Tên': 'name',
          'Số điện thoại': 'phone',
          'Địa chỉ': 'address',
          'Ghi chú': 'note',
          'Link mạng xã hội': 'social_link',
          'Công nợ VND': 'debt_vnd',
          'Công nợ CNY': 'debt_cny',
          'Công nợ USD': 'debt_usd',
          'Đã hủy': 'iscancelled',
        },
        'reimport_orders': {
          'ID': 'id',
          'Ticket ID': 'ticket_id',
          'Khách hàng': 'customer',
          'Sản phẩm': 'product',
          'ID Sản phẩm': 'product_id',
          'IMEI': 'imei',
          'Số lượng': 'quantity',
          'Giá': 'price',
          'Đơn vị tiền': 'currency',
          'Tài khoản': 'account',
          'Ghi chú': 'note',
          'Ngày tạo': 'created_at',
          'Đã hủy': 'iscancelled',
          'ID Kho': 'warehouse_id',
        },
        'transporters': {
          'Tên': 'name',
          'Số điện thoại': 'phone',
          'Địa chỉ': 'address',
          'Ghi chú': 'note',
          'Công nợ': 'debt',
          'Ngưỡng': 'thresholds',
          'ID': 'id',
          'Đã hủy': 'iscancelled',
          'Loại': 'type',
        },
        'shipping_rates': {
          'ID': 'id',
          'Đơn vị vận chuyển': 'transporter',
          'Giá trị tối thiểu': 'min_value',
          'Giá trị tối đa': 'max_value',
          'Chi phí': 'cost',
          'Ngày tạo': 'created_at',
        },
        'warehouses': {
          'ID': 'id',
          'Tên': 'name',
          'Loại': 'type',
          'Ngày tạo': 'created_at',
        },
        'sale_orders': {
          'ID': 'id',
          'Ticket ID': 'ticket_id',
          'Nhân viên bán': 'saleman',
          'Khách hàng': 'customer',
          'Sản phẩm': 'product_name',
          'ID Sản phẩm': 'product_id',
          'IMEI': 'imei',
          'Số lượng': 'quantity',
          'Giá': 'price',
          'Đơn vị tiền': 'currency',
          'Tài khoản': 'account',
          'Ghi chú': 'note',
          'Ngày tạo': 'created_at',
          'Đã hủy': 'iscancelled',
          'Đơn vị ship COD': 'transporter',
          'Tiền khách cọc': 'customer_price',
          'Tiền COD vận': 'transporter_price',
          'Kho hàng': 'warehouse_name',
          'ID Kho': 'warehouse_id',
        },
        'return_orders': {
          'ID': 'id',
          'Ticket ID': 'ticket_id',
          'Nhà cung cấp': 'supplier',
          'Sản phẩm': 'product',
          'Tên sản phẩm': 'product_name',
          'ID Sản phẩm': 'product_id',
          'IMEI': 'imei',
          'Số lượng': 'quantity',
          'Giá': 'price',
          'Đơn vị tiền': 'currency',
          'Tài khoản': 'account',
          'Ghi chú': 'note',
          'Ngày tạo': 'created_at',
          'Đã hủy': 'iscancelled',
          'ID Kho': 'warehouse_id',
          'Tổng tiền': 'total_amount',
        },
        'financial_accounts': {
          'ID': 'id',
          'Tên': 'name',
          'Số dư': 'balance',
          'Đơn vị tiền': 'currency',
          'Đã hủy': 'iscancelled',
        },
        'transporter_orders': {
          'ID': 'id',
          'Ticket ID': 'ticket_id',
          'IMEI': 'imei',
          'Đơn vị vận chuyển': 'transporter',
          'Kho hàng': 'warehouse',
          'ID Kho': 'warehouse_id',
          'Phí vận chuyển': 'transport_fee',
          'Ngày tạo': 'created_at',
          'Sản phẩm': 'product',
          'ID Sản phẩm': 'product_id',
          'Loại': 'type',
          'Đã hủy': 'iscancelled',
        },
        'products_name': {
          'ID': 'id',
          'Ngày tạo': 'created_at',
          'Sản phẩm': 'products',
          'ID danh mục': 'category_id',
        },
      };

      final params = {
        'tables': tables,
        'columnTranslations': columnTranslations,
        'tableData': tableData,
        'tenantClient': widget.tenantClient,
      };

      print('Calling _createExcelFile with params');
      final excelData = await this._createExcelFile(params);
      final excelBytes = excelData['bytes'] as List<int>;
      final fileName = excelData['fileName'] as String;

      print('Excel file created, saving to local storage: $fileName');

      final downloadsDir = await _getDownloadDirectory();
      final localFilePath = '${downloadsDir.path}/$fileName';
      final localFile = File(localFilePath);
      await localFile.writeAsBytes(excelBytes);
      print('Saved file to local path for report management: $localFilePath');

      if (Platform.isIOS) {
        final tempDir = await getTemporaryDirectory();
        final tempFilePath = '${tempDir.path}/$fileName';
        final tempFile = File(tempFilePath);
        await tempFile.writeAsBytes(excelBytes);

        print('Sharing file on iOS: $tempFilePath');
        await Share.shareXFiles(
          [XFile(tempFilePath, mimeType: 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet')],
        );

        if (await tempFile.exists()) {
          await tempFile.delete();
          print('Deleted temporary file: $tempFilePath');
        }
      } else {
        print('File saved at: $localFilePath');
      }

      await _loadReportFiles();

      if (mounted) {
        Navigator.pop(context);
        _showSuccessDialog(
          context,
          Platform.isIOS
              ? 'Đã tạo báo cáo Excel thành công. Vui lòng chọn vị trí lưu file.'
              : 'Đã xuất báo cáo Excel thành công.\nFile được lưu tại: $localFilePath',
        );
      }
    } catch (e) {
      print('Export Excel error: $e');
      if (mounted) {
        Navigator.pop(context);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Lỗi khi xuất báo cáo Excel: $e')),
        );
      }
    }
  }

  Future<Map<String, List<Map<String, dynamic>>>> _fetchAllData(List<String> tableNames) async {
    final data = <String, List<Map<String, dynamic>>>{};
    final transactionTables = [
      'financial_orders',
      'fix_receive_orders',
      'fix_send_orders',
      'import_orders',
      'reimport_orders',
      'return_orders',
      'sale_orders',
      'transporter_orders',
    ]; // Các bảng cần lọc iscancelled = false

    for (var table in tableNames) {
      print('Fetching data for table: $table');
      try {
        bool hasCreatedAt = false;
        try {
          final testResponse = await widget.tenantClient.from(table).select().limit(1).maybeSingle();
          if (testResponse != null && testResponse['created_at'] != null) {
            hasCreatedAt = true;
          }
        } catch (e) {
          print('Error checking created_at for table $table: $e');
        }

        dynamic query = widget.tenantClient.from(table).select();
        if (transactionTables.contains(table)) {
          query = query.eq('iscancelled', false);
        }
        if (hasCreatedAt) {
          query = query.order('created_at', ascending: false).limit(1000);
        }

        final response = await query;
        data[table] = (response as List<dynamic>).cast<Map<String, dynamic>>();
        print('Processed ${data[table]!.length} rows for table $table');
      } catch (e) {
        print('Error fetching data for table $table: $e');
        data[table] = []; // Nếu lỗi, trả mảng rỗng cho bảng đó
      }
    }

    print('All Supabase queries completed');
    return data;
  }

  Future<void> _importExcel() async {
    try {
      final hasPermission = await _requestStoragePermission();
      if (!hasPermission) {
        print('Storage permission denied for file picker');
        return;
      }

      FilePickerResult? result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['xlsx'],
        withData: Platform.isIOS,
      );

      if (result == null || (result.files.single.path == null && result.files.single.bytes == null)) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Không có file nào được chọn')),
        );
        return;
      }

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
                'Dữ liệu đang được tải lên. Vui lòng chờ tới khi hoàn tất và không đóng ứng dụng.',
                textAlign: TextAlign.center,
              ),
            ],
          ),
        ),
      );

      List<int>? fileBytes = result.files.single.bytes;
      String? originalFilePath = result.files.single.path;

      if (fileBytes == null && originalFilePath != null) {
        final originalFile = File(originalFilePath);
        if (!await originalFile.exists()) {
          throw Exception('File không tồn tại tại đường dẫn: $originalFilePath');
        }
        fileBytes = await originalFile.readAsBytes();
      }

      if (fileBytes == null) {
        throw Exception('Không thể đọc dữ liệu file Excel');
      }

      final excel = Excel.decodeBytes(fileBytes);

      final columnTranslations = {
        'Đơn vị sửa chữa': {
          'ID': 'id',
          'Tên': 'name',
          'Số điện thoại': 'phone',
          'Địa chỉ': 'address',
          'Ghi chú': 'note',
          'Công nợ VND': 'debt_vnd',
          'Công nợ CNY': 'debt_cny',
          'Công nợ USD': 'debt_usd',
          'Đã hủy': 'iscancelled',
        },
        'Phiếu nhập hàng': {
          'ID': 'id',
          'Nhà cung cấp': 'supplier',
          'Sản phẩm': 'product_name',
          'ID Sản phẩm': 'product_id',
          'IMEI': 'imei',
          'Số lượng': 'quantity',
          'Giá': 'price',
          'Đơn vị tiền': 'currency',
          'Tài khoản': 'account',
          'Ghi chú': 'note',
          'Ngày tạo': 'created_at',
          'Tổng tiền': 'total_amount',
          'Kho hàng': 'warehouse_name',
          'ID Kho': 'warehouse_id',
          'Đã hủy': 'iscancelled',
        },
        'Sản phẩm': {
          'ID': 'id',
          'ID Sản phẩm': 'product_id',
          'Tên': 'name',
          'IMEI': 'imei',
          'Giá nhập': 'import_price',
          'Đơn vị tiền nhập': 'import_currency',
          'Nhà cung cấp': 'supplier',
          'Ngày nhập': 'import_date',
          'Trạng thái': 'status',
          'Đơn vị sửa chữa': 'fix_unit',
          'Giá sửa': 'fix_price',
          'Đơn vị tiền sửa': 'fix_currency',
          'Giá bán': 'sale_price',
          'Khách hàng': 'customer',
          'Đơn vị ship COD': 'transporter',
          'Phí vận chuyển': 'transport_fee',
          'Giá vốn': 'cost_price',
          'Ngày gửi vận chuyển': 'send_transfer_date',
          'Ngày nhập vận chuyển': 'import_transfer_date',
          'Ngày trả hàng': 'return_date',
          'Ngày gửi sửa': 'send_fix_date',
          'Ngày nhận sửa': 'fix_receive_date',
          'ID danh mục': 'category_id',
          'Ngày bán': 'sale_date',
          'Lợi nhuận': 'profit',
          'Tiền khách cọc': 'customer_price',
          'Tiền COD vận': 'transporter_price',
          'ID Kho': 'warehouse_id',
          'Tên Kho': 'warehouse_name',
        },
        'Khách hàng': {
          'ID': 'id',
          'Tên': 'name',
          'Số điện thoại': 'phone',
          'Địa chỉ': 'address',
          'Ghi chú': 'note',
          'Link mạng xã hội': 'social_link',
          'Công nợ VND': 'debt_vnd',
          'Công nợ CNY': 'debt_cny',
          'Công nợ USD': 'debt_usd',
          'Đã hủy': 'iscancelled',
        },
        'Phiếu nhận sửa': {
          'ID': 'id',
          'Ticket ID': 'ticket_id',
          'Đơn vị sửa chữa': 'fixer',
          'Sản phẩm': 'product',
          'ID Sản phẩm': 'product_id',
          'IMEI': 'imei',
          'Số lượng': 'quantity',
          'Giá': 'price',
          'Đơn vị tiền': 'currency',
          'Tài khoản': 'account',
          'Ngày tạo': 'created_at',
          'Đã hủy': 'iscancelled',
          'Ghi chú': 'note',
          'ID Kho': 'warehouse_id',
        },
        'Phiếu gửi sửa': {
          'ID': 'id',
          'Ticket ID': 'ticket_id',
          'Đơn vị sửa chữa': 'fixer',
          'Sản phẩm': 'product',
          'ID Sản phẩm': 'product_id',
          'IMEI': 'imei',
          'Số lượng': 'quantity',
          'Ngày tạo': 'created_at',
          'Đã hủy': 'iscancelled',
          'Ghi chú': 'note',
          'ID Kho': 'warehouse_id',
        },
        'Phiếu tài chính': {
          'ID': 'id',
          'Loại phiếu': 'type',
          'Loại đối tác': 'partner_type',
          'Tên đối tác': 'partner_name',
          'Số tiền': 'amount',
          'Đơn vị tiền': 'currency',
          'Tài khoản': 'account',
          'Ghi chú': 'note',
          'Ngày tạo': 'created_at',
          'Tỷ giá VND-CNY': 'rate_vnd_cny',
          'Tỷ giá VND-USD': 'rate_vnd_usd',
          'Số tiền nhận': 'receive_amount',
          'Tài khoản nguồn': 'from_account',
          'Tài khoản đích': 'to_account',
          'Số tiền nguồn': 'from_amount',
          'Đơn vị tiền nguồn': 'from_currency',
          'Số tiền đích': 'to_amount',
          'Đơn vị tiền đích': 'to_currency',
          'Đã hủy': 'iscancelled',
        },
        'Nhà cung cấp': {
          'ID': 'id',
          'Tên': 'name',
          'Số điện thoại': 'phone',
          'Địa chỉ': 'address',
          'Ghi chú': 'note',
          'Link mạng xã hội': 'social_link',
          'Công nợ VND': 'debt_vnd',
          'Công nợ CNY': 'debt_cny',
          'Công nợ USD': 'debt_usd',
          'Đã hủy': 'iscancelled',
        },
        'Phiếu nhập lại hàng': {
          'ID': 'id',
          'Ticket ID': 'ticket_id',
          'Khách hàng': 'customer',
          'Sản phẩm': 'product',
          'ID Sản phẩm': 'product_id',
          'IMEI': 'imei',
          'Số lượng': 'quantity',
          'Giá': 'price',
          'Đơn vị tiền': 'currency',
          'Tài khoản': 'account',
          'Ghi chú': 'note',
          'Ngày tạo': 'created_at',
          'Đã hủy': 'iscancelled',
          'ID Kho': 'warehouse_id',
        },
        'Đơn vị vận chuyển': {
          'Tên': 'name',
          'Số điện thoại': 'phone',
          'Địa chỉ': 'address',
          'Ghi chú': 'note',
          'Công nợ': 'debt',
          'Ngưỡng': 'thresholds',
          'ID': 'id',
          'Đã hủy': 'iscancelled',
          'Loại': 'type',
        },
        'Cước vận chuyển': {
          'ID': 'id',
          'Đơn vị vận chuyển': 'transporter',
          'Giá trị tối thiểu': 'min_value',
          'Giá trị tối đa': 'max_value',
          'Chi phí': 'cost',
          'Ngày tạo': 'created_at',
        },
        'Kho hàng': {
          'ID': 'id',
          'Tên': 'name',
          'Loại': 'type',
          'Ngày tạo': 'created_at',
        },
        'Phiếu bán hàng': {
          'ID': 'id',
          'Ticket ID': 'ticket_id',
          'Nhân viên bán': 'saleman',
          'Khách hàng': 'customer',
          'Sản phẩm': 'product_name',
          'ID Sản phẩm': 'product_id',
          'IMEI': 'imei',
          'Số lượng': 'quantity',
          'Giá': 'price',
          'Đơn vị tiền': 'currency',
          'Tài khoản': 'account',
          'Ghi chú': 'note',
          'Ngày tạo': 'created_at',
          'Đã hủy': 'iscancelled',
          'Đơn vị ship COD': 'transporter',
          'Tiền khách cọc': 'customer_price',
          'Tiền COD vận': 'transporter_price',
          'Kho hàng': 'warehouse_name',
          'ID Kho': 'warehouse_id',
        },
        'Phiếu trả hàng': {
          'ID': 'id',
          'Ticket ID': 'ticket_id',
          'Nhà cung cấp': 'supplier',
          'Sản phẩm': 'product',
          'Tên sản phẩm': 'product_name',
          'ID Sản phẩm': 'product_id',
          'IMEI': 'imei',
          'Số lượng': 'quantity',
          'Giá': 'price',
          'Đơn vị tiền': 'currency',
          'Tài khoản': 'account',
          'Ghi chú': 'note',
          'Ngày tạo': 'created_at',
          'Đã hủy': 'iscancelled',
          'ID Kho': 'warehouse_id',
          'Tổng tiền': 'total_amount',
        },
        'Tài khoản tài chính': {
          'ID': 'id',
          'Tên': 'name',
          'Số dư': 'balance',
          'Đơn vị tiền': 'currency',
          'Đã hủy': 'iscancelled',
        },
        'Phiếu vận chuyển': {
          'ID': 'id',
          'Ticket ID': 'ticket_id',
          'IMEI': 'imei',
          'Đơn vị vận chuyển': 'transporter',
          'Kho hàng': 'warehouse',
          'ID Kho': 'warehouse_id',
          'Phí vận chuyển': 'transport_fee',
          'Ngày tạo': 'created_at',
          'Sản phẩm': 'product',
          'ID Sản phẩm': 'product_id',
          'Loại': 'type',
          'Đã hủy': 'iscancelled',
        },
        'Tên sản phẩm': {
          'ID': 'id',
          'Ngày tạo': 'created_at',
          'Sản phẩm': 'products',
          'ID danh mục': 'category_id',
        },
      };

      final sheetToTableMap = {
        'Đơn vị sửa chữa': 'fix_units',
        'Phiếu nhập hàng': 'import_orders',
        'Sản phẩm': 'products',
        'Khách hàng': 'customers',
        'Phiếu nhận sửa': 'fix_receive_orders',
        'Phiếu gửi sửa': 'fix_send_orders',
        'Phiếu tài chính': 'financial_orders',
        'Nhà cung cấp': 'suppliers',
        'Phiếu nhập lại hàng': 'reimport_orders',
        'Đơn vị vận chuyển': 'transporters',
        'Cước vận chuyển': 'shipping_rates',
        'Kho hàng': 'warehouses',
        'Phiếu bán hàng': 'sale_orders',
        'Phiếu trả hàng': 'return_orders',
        'Tài khoản tài chính': 'financial_accounts',
        'Phiếu vận chuyển': 'transporter_orders',
        'Tên sản phẩm': 'products_name',
      };

      final timestampColumns = [
        'created_at',
        'import_date',
        'send_transfer_date',
        'import_transfer_date',
        'return_date',
        'send_fix_date',
        'fix_receive_date',
        'sale_date',
      ];

      final bigintColumns = [
        'quantity',
        'min_value',
        'max_value',
        'balance',
        'debt_vnd',
        'debt_cny',
        'debt_usd',
        'thresholds',
      ];

      final integerColumns = [
        'amount',
        'receive_amount',
        'from_amount',
        'to_amount',
        'profit',
        'customer_price',
        'transporter_price',
        'cost',
        'transport_fee',
      ];

      final numericColumns = [
        'price',
        'total_amount',
        'cost_price',
        'fix_price',
        'sale_price',
        'import_price',
        'rate_vnd_cny',
        'rate_vnd_usd',
        'debt',
      ];

      final uuidColumns = [
        'product_id',
        'warehouse_id',
        'id',
      ];

      final textColumns = [
        'ticket_id',
      ];

      const batchSize = 100;

      Map<String, List<Map<String, dynamic>>> tableData = {};

      for (var sheetName in excel.sheets.keys) {
        final sheet = excel.sheets[sheetName]!;
        final tableEntry = columnTranslations.entries.firstWhere(
          (entry) => entry.key == sheetName,
          orElse: () => MapEntry('', {}),
        );

        if (tableEntry.key.isEmpty) {
          continue;
        }

        final tableName = sheetToTableMap[sheetName];
        if (tableName == null) {
          continue;
        }

        final translations = tableEntry.value;

        final headers = sheet.rows.first
            .map((cell) => cell?.value?.toString() ?? '')
            .toList();
        final expectedHeaders = translations.keys.toList();

        if (headers.length != expectedHeaders.length ||
            !headers.every((header) => expectedHeaders.contains(header))) {
          if (mounted) {
            Navigator.pop(context);
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text('Cấu trúc cột trong sheet "$sheetName" không khớp')),
            );
          }
          return;
        }

        tableData[tableName] = tableData[tableName] ?? [];

        final rows = sheet.rows.sublist(1);

        for (var row in rows) {
          final rowData = <String, dynamic>{};

          for (var colIndex = 0; colIndex < headers.length; colIndex++) {
            final vietnameseHeader = headers[colIndex];
            final columnName = translations[vietnameseHeader]!;
            final CellValue? cellValue = row[colIndex]?.value;
            final String cellValueString = cellValue?.toString() ?? '';

            if (cellValueString.isEmpty) {
              rowData[columnName] = null;
            } else if (columnName == 'iscancelled') {
              rowData[columnName] = cellValueString.toLowerCase() == 'true';
            } else if (timestampColumns.contains(columnName)) {
              rowData[columnName] = cellValueString;
            } else if (columnName == 'imei') {
              rowData[columnName] = cellValueString;
            } else if (uuidColumns.contains(columnName)) {
              // Xử lý UUID columns - giữ nguyên dạng string
              rowData[columnName] = cellValueString;
            } else if (textColumns.contains(columnName)) {
              // Xử lý text columns - giữ nguyên dạng string
              rowData[columnName] = cellValueString;
            } else if (bigintColumns.contains(columnName)) {
              final numericValue = double.tryParse(cellValueString);
              if (numericValue != null) {
                rowData[columnName] = numericValue.toInt();
              } else {
                throw Exception('Giá trị không hợp lệ cho cột số nguyên lớn $columnName trong bảng $tableName: $cellValueString');
              }
            } else if (integerColumns.contains(columnName)) {
              final numericValue = double.tryParse(cellValueString);
              if (numericValue != null) {
                rowData[columnName] = numericValue.toInt();
              } else {
                throw Exception('Giá trị không hợp lệ cho cột số nguyên $columnName trong bảng $tableName: $cellValueString');
              }
            } else if (numericColumns.contains(columnName)) {
              final numericValue = double.tryParse(cellValueString);
              if (numericValue != null) {
                rowData[columnName] = numericValue;
              } else {
                throw Exception('Giá trị không hợp lệ cho cột số $columnName trong bảng $tableName: $cellValueString');
              }
            } else {
              rowData[columnName] = cellValueString;
            }
          }

          if (rowData.isNotEmpty) {
            tableData[tableName]!.add(rowData);
          }
        }
      }

      final upsertOrder = [
        'products_name',
        'warehouses',
        'transporters',
        'shipping_rates',
        'financial_accounts',
        'suppliers',
        'customers',
        'fix_units',
        'products',
        'import_orders',
        'sale_orders',
        'return_orders',
        'reimport_orders',
        'fix_send_orders',
        'fix_receive_orders',
        'transporter_orders',
        'financial_orders',
      ];

      for (var tableName in upsertOrder) {
        if (tableData.containsKey(tableName)) {
          final data = tableData[tableName]!;
          for (var batchStart = 0; batchStart < data.length; batchStart += batchSize) {
            final batchEnd = (batchStart + batchSize < data.length) ? batchStart + batchSize : data.length;
            final batchData = data.sublist(batchStart, batchEnd);

            if (batchData.isNotEmpty) {
              for (int attempt = 1; attempt <= 2; attempt++) {
                try {
                  await widget.tenantClient
                      .from(tableName)
                      .upsert(batchData, onConflict: 'id');
                  print('Upserted ${batchData.length} records in $tableName');
                  break;
                } catch (e) {
                  if (attempt == 2) {
                    throw Exception('Failed to upsert batch in table $tableName after 2 attempts: $e');
                  }
                  await Future.delayed(Duration(milliseconds: 500 * attempt));
                }
              }
            }
          }
        }
      }

      if (mounted) {
        Navigator.pop(context);
        _showSuccessDialog(context, 'Đã nhập dữ liệu từ Excel thành công.');
      }
    } catch (e) {
      print('Error importing Excel: $e');
      if (mounted) {
        Navigator.pop(context);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Lỗi khi nhập dữ liệu từ Excel: $e')),
        );
      }
    }
  }

  Future<void> _resetData() async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Xác nhận Reset dữ liệu'),
        content: const Text(
          'Sau khi Reset hãy tạo phiếu đổi tiền để cập nhật tỉ giá. Sẽ xóa mọi dữ liệu hiện có. Bạn có đồng ý không?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Hủy'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Đồng ý', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );

    if (confirm != true) return;

    try {
      final tablesToReset = [
        'fix_units',
        'import_orders',
        'products',
        'customers',
        'fix_receive_orders',
        'fix_send_orders',
        'financial_orders',
        'suppliers',
        'reimport_orders',
        'transporters',
        'shipping_rates',
        'warehouses',
        'sale_orders',
        'return_orders',
        'financial_accounts',
        'transporter_orders',
        'products_name',
      ];

      for (var table in tablesToReset) {
        await widget.tenantClient.from(table).delete().neq('id', 0);
        print('Đã xóa dữ liệu từ bảng $table');
      }

      await _loadReportFiles();

      if (mounted) {
        _showSuccessDialog(context, 'Đã reset dữ liệu thành công. Vui lòng tạo phiếu đổi tiền để cập nhật tỉ giá.');
      }
    } catch (e) {
      print('Error resetting data: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Lỗi khi reset dữ liệu: $e')),
        );
      }
    }
  }

  void _viewReports() {
    if (reportFiles.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Không có báo cáo nào để xem')),
      );
      return;
    }

    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Danh sách báo cáo', style: TextStyle(fontWeight: FontWeight.bold)),
        content: SizedBox(
          width: double.maxFinite,
          height: 300,
          child: ListView.builder(
            shrinkWrap: true,
            itemCount: reportFiles.length,
            itemBuilder: (context, index) {
              final filePath = reportFiles[index];
              final fileName = filePath.split('/').last;
              return Card(
                elevation: 2,
                margin: const EdgeInsets.symmetric(vertical: 4),
                child: ListTile(
                  title: Text(fileName, style: const TextStyle(fontSize: 16)),
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      IconButton(
                        icon: const Icon(Icons.share, color: Colors.blue),
                        onPressed: () async {
                          try {
                            final file = File(filePath);
                            if (!await file.exists()) {
                              print('Error: File not found at $filePath');
                              ScaffoldMessenger.of(context).showSnackBar(
                                SnackBar(content: Text('File "$fileName" không tồn tại')),
                              );
                              return;
                            }

                            await Share.shareXFiles(
                              [XFile(filePath, mimeType: 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet')],
                            );
                          } catch (e) {
                            print('Error sharing file: $e');
                            if (mounted) {
                              ScaffoldMessenger.of(context).showSnackBar(
                                SnackBar(content: Text('Lỗi khi chia sẻ file: $e')),
                              );
                            }
                          }
                        },
                      ),
                      IconButton(
                        icon: const Icon(Icons.delete, color: Colors.red),
                        onPressed: () async {
                          final confirm = await showDialog<bool>(
                            context: context,
                            builder: (context) => AlertDialog(
                              title: const Text('Xác nhận xóa'),
                              content: Text('Bạn có chắc muốn xóa "$fileName"?'),
                              actions: [
                                TextButton(
                                  onPressed: () => Navigator.pop(context, false),
                                  child: const Text('Hủy'),
                                ),
                                TextButton(
                                  onPressed: () => Navigator.pop(context, true),
                                  child: const Text('Xóa', style: TextStyle(color: Colors.red)),
                                ),
                              ],
                            ),
                          );

                          if (confirm == true) {
                            try {
                              await File(filePath).delete();
                              print('Deleted file: $filePath');
                              await _loadReportFiles();
                              if (mounted) {
                                Navigator.pop(context);
                                _viewReports();
                              }
                            } catch (e) {
                              print('Error deleting file: $e');
                              if (mounted) {
                                ScaffoldMessenger.of(context).showSnackBar(
                                  SnackBar(content: Text('Lỗi khi xóa file: $e')),
                                );
                              }
                            }
                          }
                        },
                      ),
                    ],
                  ),
                ),
              );
            },
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Đóng', style: TextStyle(color: Colors.blue)),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Nhập Xuất Báo Cáo Excel', style: TextStyle(color: Colors.white)),
        backgroundColor: Colors.black,
        iconTheme: const IconThemeData(color: Colors.white),
      ),
      body: SingleChildScrollView(
        child: Center(
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 40),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                ElevatedButton(
                  onPressed: () => _importExcel(),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.blue,
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 24),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                    minimumSize: const Size(200, 50),
                  ),
                  child: const Text('Nhập Báo Cáo Excel', style: TextStyle(fontSize: 16)),
                ),
                const SizedBox(height: 30),
                ElevatedButton(
                  onPressed: () => _exportExcel(),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.green,
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 24),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                    minimumSize: const Size(200, 50),
                  ),
                  child: const Text('Xuất Báo Cáo Excel', style: TextStyle(fontSize: 16)),
                ),
                const SizedBox(height: 30),
                ElevatedButton(
                  onPressed: () => _viewReports(),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.orange,
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 24),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                    minimumSize: const Size(200, 50),
                  ),
                  child: const Text('Xem Báo Cáo', style: TextStyle(fontSize: 16)),
                ),
                const SizedBox(height: 40),
                GestureDetector(
                  onTap: () => _resetData(),
                  child: Container(
                    width: 100,
                    height: 100,
                    decoration: const BoxDecoration(
                      color: Colors.red,
                      shape: BoxShape.circle,
                    ),
                    child: const Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(
                          Icons.delete_forever,
                          color: Colors.white,
                          size: 40,
                        ),
                        SizedBox(height: 4),
                        Text(
                          'Reset\nDữ Liệu',
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: 14,
                            fontWeight: FontWeight.bold,
                          ),
                          textAlign: TextAlign.center,
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}