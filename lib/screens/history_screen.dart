import 'package:flutter/material.dart' hide Border, BorderStyle;
import 'package:intl/intl.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:excel/excel.dart';
import 'package:open_file/open_file.dart';
import 'dart:io';
import 'dart:math' as math;
import 'dart:developer' as developer;
import '../helpers/storage_helper.dart';

class HistoryScreen extends StatefulWidget {
  final List<String> permissions;
  final SupabaseClient tenantClient;

  const HistoryScreen({super.key, required this.permissions, required this.tenantClient});

  @override
  _HistoryScreenState createState() => _HistoryScreenState();
}

class _HistoryScreenState extends State<HistoryScreen> {
  String filterType = 'all';
  DateTime? dateFrom;
  DateTime? dateTo;
  final TextEditingController _dateFromController = TextEditingController();
  final TextEditingController _dateToController = TextEditingController();

  final List<Map<String, String>> allTicketTypeOptions = [
    {'value': 'all', 'display': 'Loại Phiếu', 'permission': ''},
    {'value': 'cost', 'display': 'Chi phí', 'permission': 'access_financial_account_form'},
    {'value': 'payment', 'display': 'Chi Thanh Toán Đối Tác', 'permission': 'access_financial_account_form'},
    {'value': 'exchange', 'display': 'Đổi Tiền', 'permission': 'access_financial_account_form'},
    {'value': 'income_other', 'display': 'Thu Nhập Khác', 'permission': 'access_financial_account_form'},
    {'value': 'receive', 'display': 'Thu Tiền Đối Tác', 'permission': 'access_financial_account_form'},
    {'value': 'fix_receive_orders', 'display': 'Nhận Hàng Sửa Xong', 'permission': 'access_fix_receive_form'},
    {'value': 'fix_send_orders', 'display': 'Gửi Sửa', 'permission': 'access_fix_send_form'},
    {'value': 'import_orders', 'display': 'Nhập Hàng', 'permission': 'access_import_form'},
    {'value': 'reimport_orders', 'display': 'Nhập Lại Hàng', 'permission': 'access_reimport_form'},
    {'value': 'chuyển kho quốc tế', 'display': 'Chuyển Kho Quốc Tế', 'permission': 'access_transfer_global_form'},
    {'value': 'chuyển kho nội địa', 'display': 'Chuyển Kho Nội Địa', 'permission': 'access_transfer_local_form'},
    {'value': 'transfer_fund', 'display': 'Chuyển Quỹ', 'permission': 'access_transaction_form'},
    {'value': 'nhập kho vận chuyển', 'display': 'Nhập Kho Vận Chuyển', 'permission': 'access_transfer_receive_form'},
    {'value': 'sale_orders', 'display': 'Bán Hàng', 'permission': 'access_sale_form'},
    {'value': 'return_orders', 'display': 'Trả Hàng', 'permission': 'access_return_form'},
  ];

  late List<Map<String, String>> ticketTypeOptions;
  List<Map<String, dynamic>> tickets = [];
  bool isLoadingTickets = true;
  String? ticketError;
  bool isExporting = false;
  Map<String, String> productMap = {};
  Map<String, String> warehouseMap = {};
  Map<String, String> customerMap = {};
  Map<String, String> supplierMap = {};
  Map<String, String> fixerMap = {};
  Map<String, String> transporterMap = {};

  int pageSize = 50;
  int currentPage = 0;
  bool hasMoreData = true;
  bool isLoadingMore = false;
  final ScrollController _scrollController = ScrollController();

  @override
  void initState() {
    super.initState();
    ticketTypeOptions = allTicketTypeOptions.where((option) {
      if (option['value'] == 'all') return true;
      final requiredPermission = option['permission']!;
      return requiredPermission.isEmpty || widget.permissions.contains(requiredPermission);
    }).toList();

    developer.log('init: User permissions: ${widget.permissions.join(', ')}');
    _loadInitialData();
    _scrollController.addListener(() {
      if (_scrollController.position.pixels >=
              _scrollController.position.maxScrollExtent - 200 &&
          !isLoadingMore &&
          hasMoreData &&
          filterType == 'all' &&
          dateFrom == null &&
          dateTo == null) {
        _loadMoreTickets();
      }
    });
  }

  @override
  void dispose() {
    _scrollController.dispose();
    _dateFromController.dispose();
    _dateToController.dispose();
    super.dispose();
  }

  Future<void> _loadInitialData() async {
    developer.log('loadInitialData: Starting');
    setState(() {
      isLoadingTickets = true;
      ticketError = null;
    });

    try {
      await Future.wait([
        _fetchProducts(),
        _fetchWarehouses(),
        _fetchCustomers(),
        _fetchSuppliers(),
        _fetchFixers(),
        _fetchTransporters(),
      ]);

      if (productMap.isEmpty) {
        ticketError = 'Không tải được danh sách sản phẩm';
        developer.log('loadInitialData: productMap is empty');
      } else if (warehouseMap.isEmpty) {
        ticketError = 'Không tải được danh sách kho';
        developer.log('loadInitialData: warehouseMap is empty');
      }

      await _loadTickets();
    } catch (e) {
      setState(() {
        ticketError = 'Có lỗi xảy ra khi tải dữ liệu ban đầu: $e';
        isLoadingTickets = false;
      });
      developer.log('loadInitialData: Error: $e');
    } finally {
      setState(() {
        isLoadingTickets = false;
      });
    }
  }

  Future<void> _fetchProducts() async {
    try {
      final response = await widget.tenantClient.from('products_name').select('id, products');
      setState(() {
        productMap = Map.fromEntries(
          response.map((e) => MapEntry(e['id'].toString(), e['products'] as String)),
        );
      });
      developer.log('products: Loaded ${productMap.length} products');
    } catch (e) {
      developer.log('products: Error: $e');
      productMap = {};
    }
  }

  Future<void> _fetchWarehouses() async {
    try {
      final response = await widget.tenantClient.from('warehouses').select('id, name');
      setState(() {
        warehouseMap = Map.fromEntries(
          response.map((e) => MapEntry(e['id'].toString(), e['name'] as String)),
        );
      });
      developer.log('warehouses: Loaded ${warehouseMap.length} warehouses');
    } catch (e) {
      developer.log('warehouses: Error: $e');
      warehouseMap = {};
    }
  }

  Future<void> _fetchCustomers() async {
    try {
      final response = await widget.tenantClient.from('customers').select('id, name');
      setState(() {
        customerMap = Map.fromEntries(
          response.map((e) => MapEntry(e['id'].toString(), e['name'] as String)),
        );
      });
      developer.log('customers: Loaded ${customerMap.length} customers');
    } catch (e) {
      developer.log('customers: Error: $e');
      customerMap = {};
    }
  }

  Future<void> _fetchSuppliers() async {
    try {
      final response = await widget.tenantClient.from('suppliers').select('id, name');
      setState(() {
        supplierMap = Map.fromEntries(
          response.map((e) => MapEntry(e['id'].toString(), e['name'] as String)),
        );
      });
      developer.log('suppliers: Loaded ${supplierMap.length} suppliers');
    } catch (e) {
      developer.log('suppliers: Error: $e');
      supplierMap = {};
    }
  }

  Future<void> _fetchFixers() async {
    try {
      final response = await widget.tenantClient.from('fix_units').select('id, name');
      setState(() {
        fixerMap = Map.fromEntries(
          response.map((e) => MapEntry(e['id'].toString(), e['name'] as String)),
        );
      });
      developer.log('fixers: Loaded ${fixerMap.length} fixers');
    } catch (e) {
      developer.log('fixers: Error: $e');
      fixerMap = {};
    }
  }

  Future<void> _fetchTransporters() async {
    try {
      final response = await widget.tenantClient.from('transporters').select('id, name');
      setState(() {
        transporterMap = Map.fromEntries(
          response.map((e) => MapEntry(e['id'].toString(), e['name'] as String)),
        );
      });
      developer.log('transporters: Loaded ${transporterMap.length} transporters');
    } catch (e) {
      developer.log('transporters: Error: $e');
      transporterMap = {};
    }
  }

  Future<void> _loadTickets() async {
    developer.log('loadTickets: Starting');
    setState(() {
      isLoadingTickets = true;
      ticketError = null;
      tickets = [];
      currentPage = 0;
      hasMoreData = true;
    });

    try {
      await _loadMoreTickets();
    } catch (e) {
      setState(() {
        ticketError = 'Có lỗi xảy ra khi tải phiếu: $e';
      });
      developer.log('loadTickets: Error: $e');
    } finally {
      setState(() {
        isLoadingTickets = false;
      });
    }
  }

  Future<void> _loadMoreTickets() async {
    if (!hasMoreData || isLoadingMore) {
      developer.log('loadMoreTickets: No more data or loading');
      return;
    }

    developer.log('loadMoreTickets: Page $currentPage');
    setState(() {
      isLoadingMore = true;
    });

    try {
      final newTickets = await _fetchTickets(paginated: true);
      setState(() {
        tickets.addAll(newTickets);
        if (newTickets.length < pageSize) {
          hasMoreData = false;
        }
        currentPage++;
      });
      developer.log('tickets: Loaded ${newTickets.length}, total: ${tickets.length}');
    } catch (e) {
      setState(() {
        ticketError = 'Có lỗi khi tải thêm dữ liệu: $e';
        isLoadingMore = false;
      });
      developer.log('loadMoreTickets: Error: $e');
    } finally {
      setState(() {
        isLoadingMore = false;
      });
    }
  }

  Future<void> _selectDate(BuildContext context, bool isFrom) async {
    final initialDate = DateTime.now();
    final DateTime? picked = await showDatePicker(
      context: context,
      initialDate: isFrom ? (dateFrom ?? initialDate) : (dateTo ?? initialDate),
      firstDate: DateTime(2000),
      lastDate: DateTime(2100),
    );
    if (picked != null) {
      setState(() {
        if (isFrom) {
          dateFrom = picked;
          _dateFromController.text = DateFormat('dd/MM/yyyy').format(picked);
        } else {
          dateTo = picked;
          _dateToController.text = DateFormat('dd/MM/yyyy').format(picked);
        }
        hasMoreData = false;
      });
      developer.log('selectDate: Picked $picked, isFrom: $isFrom');
      await _loadTickets();
    }
  }

  String _formatDate(String? dateStr) {
    if (dateStr == null) return '';
    try {
      final parsedDate = DateTime.parse(dateStr);
      return DateFormat('dd/MM/yyyy').format(parsedDate);
    } catch (e) {
      developer.log('formatDate: Error $dateStr: $e');
      return dateStr;
    }
  }

  String _formatNumber(num? amount) {
    if (amount == null) return '0';
    try {
      return NumberFormat.decimalPattern('vi_VN').format(amount);
    } catch (e) {
      developer.log('formatNumber: Error $amount: $e');
      return '0';
    }
  }

  String _formatImeiForExcelCell(dynamic imeiData) {
    if (imeiData == null) {
      return 'N/A';
    }
    final raw = imeiData.toString().trim();
    if (raw.isEmpty || raw == 'N/A') {
      return 'N/A';
    }
    final normalized = raw.replaceAll('\r', '');
    final entries = normalized
        .split(RegExp(r'[,;\n]+'))
        .map((value) => value.trim())
        .where((value) => value.isNotEmpty)
        .toList();
    if (entries.isEmpty) {
      return 'N/A';
    }
    return entries.join('\r\n');
  }

  void _updateExcelMetrics({
    required Map<int, int> rowLineCounts,
    required List<double> maxColumnWidths,
    required int rowIndex,
    required int columnIndex,
    required String value,
  }) {
    final sanitized = value.replaceAll('\r\n', '\n');
    final lines = sanitized.isEmpty ? <String>[''] : sanitized.split('\n');
    final longestLineLength = lines.fold<int>(
      0,
      (currentMax, line) => math.max(currentMax, line.length),
    );
    maxColumnWidths[columnIndex] =
        math.max(maxColumnWidths[columnIndex], longestLineLength.toDouble());
    final currentRowLineCount = rowLineCounts[rowIndex] ?? 1;
    rowLineCounts[rowIndex] = math.max(currentRowLineCount, lines.length);
  }

  void _applyExcelSizing({
    required Sheet sheet,
    required List<double> maxColumnWidths,
    required Map<int, int> rowLineCounts,
  }) {
    final baseRowHeight = (sheet.defaultRowHeight ?? 15).toDouble();
    final baseColumnWidth = (sheet.defaultColumnWidth ?? 8.43).toDouble();

    for (int columnIndex = 0;
        columnIndex < maxColumnWidths.length;
        columnIndex++) {
      final contentWidth = maxColumnWidths[columnIndex];
      final computedWidth =
          contentWidth > 0 ? contentWidth + 2 : baseColumnWidth;
      sheet.setColumnWidth(
        columnIndex,
        math.max(baseColumnWidth, computedWidth),
      );
    }

    rowLineCounts.forEach((rowIndex, lineCount) {
      final effectiveLineCount = lineCount < 1 ? 1 : lineCount;
      sheet.setRowHeight(rowIndex, baseRowHeight * effectiveLineCount);
    });
  }

  String _getPartnerName(String? partnerId, String? partnerType, String? partnerName) {
    // Nếu đã có partner_name thì dùng luôn
    if (partnerName != null && partnerName.isNotEmpty && partnerName != 'N/A') {
      return partnerName;
    }
    
    // Nếu không có partner_id hoặc partner_type thì trả về N/A
    if (partnerId == null || partnerType == null) {
      return 'N/A';
    }
    
    // Tra cứu tên từ cache dựa vào partner_type
    switch (partnerType) {
      case 'suppliers':
        return supplierMap[partnerId] ?? 'N/A';
      case 'customers':
        return customerMap[partnerId] ?? 'N/A';
      case 'fix_units':
        return fixerMap[partnerId] ?? 'N/A';
      case 'transporters':
        return transporterMap[partnerId] ?? 'N/A';
      default:
        return 'N/A';
    }
  }


  String _getDisplayType(String type, String table) {
    String typeKey = type;
    if (table == 'fix_receive_orders') {
      typeKey = 'fix_receive_orders';
    } else if (table == 'fix_send_orders') {
      typeKey = 'fix_send_orders';
    } else if (table == 'import_orders') {
      typeKey = 'import_orders';
    } else if (table == 'reimport_orders') {
      typeKey = 'reimport_orders';
    } else if (table == 'sale_orders') {
      typeKey = 'sale_orders';
    } else if (table == 'return_orders') {
      typeKey = 'return_orders';
    } else if (table == 'transporter_orders') {
      typeKey = type;
    }

    final option = ticketTypeOptions.firstWhere(
      (opt) => opt['value'] == typeKey,
      orElse: () => {'display': typeKey},
    );
    return option['display'] ?? typeKey;
  }

  Future<List<Map<String, dynamic>>> _fetchTickets({bool paginated = false}) async {
    developer.log('fetchTickets: Paginated: $paginated, filterType: $filterType');
    List<Map<String, dynamic>> allTickets = [];
    final ticketIds = <String>{};

    final hasTransportPermission = widget.permissions.contains('access_transfer_global_form') ||
        widget.permissions.contains('access_transfer_local_form') ||
        widget.permissions.contains('access_transfer_receive_form');

    if (!hasTransportPermission &&
        (filterType == 'chuyển kho quốc tế' || filterType == 'chuyển kho nội địa' || filterType == 'nhập kho vận chuyển')) {
      setState(() {
        ticketError = 'Bạn không có quyền xem các phiếu vận chuyển';
      });
      return [];
    }

    final tables = [
      if (widget.permissions.contains('access_financial_account_form'))
        {
          'table': 'financial_orders',
          'key': 'id',
          'select': 'id, type, created_at, partner_name, partner_id, amount, currency, iscancelled, from_amount, from_currency, to_amount, to_currency, to_account, partner_type, account, note',
          'partnerField': 'partner_name',
          'amountField': 'amount',
          'dateField': 'created_at',
          'snapshotKey': 'id',
        },
      if (widget.permissions.contains('access_fix_receive_form'))
        {
          'table': 'fix_receive_orders',
          'key': 'ticket_id',
          'select': 'ticket_id, created_at, fixer, fix_unit_id, price, quantity, currency, account, iscancelled, product_id, warehouse_id, imei, note',
          'partnerField': 'fix_unit_id',
          'amountField': 'price',
          'dateField': 'created_at',
          'snapshotKey': 'ticket_id',
        },
      if (widget.permissions.contains('access_fix_send_form'))
        {
          'table': 'fix_send_orders',
          'key': 'ticket_id',
          'select': 'ticket_id, created_at, fixer, fix_unit_id, quantity, iscancelled, product_id, warehouse_id, imei',
          'partnerField': 'fix_unit_id',
          'amountField': null,
          'dateField': 'created_at',
          'snapshotKey': 'ticket_id',
        },
      if (widget.permissions.contains('access_import_form'))
        {
          'table': 'import_orders',
          'key': 'id',
          'select': 'id, created_at, supplier_id, price, quantity, total_amount, currency, account, iscancelled, product_id, warehouse_id, imei, note',
          'partnerField': 'supplier_id',
          'amountField': 'price',
          'dateField': 'created_at',
          'snapshotKey': 'id',
        },
      if (widget.permissions.contains('access_reimport_form'))
        {
          'table': 'reimport_orders',
          'key': 'ticket_id',
          'select': 'ticket_id, created_at, customer_id, price, quantity, currency, account, iscancelled, product_id, warehouse_id, imei, note',
          'partnerField': 'customer_id',
          'amountField': 'price',
          'dateField': 'created_at',
          'snapshotKey': 'ticket_id',
        },
      if (widget.permissions.contains('access_sale_form'))
        {
          'table': 'sale_orders',
          'key': 'ticket_id',
          'select': 'ticket_id, created_at, customer_id, price, quantity, currency, account, customer_price, transporter_price, transporter, iscancelled, product_id, warehouse_id, imei, saleman, note, doanhso',
          'partnerField': 'customer_id',
          'amountField': 'price',
          'dateField': 'created_at',
          'snapshotKey': 'ticket_id',
        },
      if (widget.permissions.contains('access_return_form'))
        {
          'table': 'return_orders',
          'key': 'ticket_id',
          'select': 'ticket_id, created_at, supplier_id, price, quantity, total_amount, currency, account, iscancelled, product_id, warehouse_id, imei',
          'partnerField': 'supplier_id',
          'amountField': 'price',
          'dateField': 'created_at',
          'snapshotKey': 'ticket_id',
        },
      if (hasTransportPermission)
        {
          'table': 'transporter_orders',
          'key': 'id',
          'select': 'id, ticket_id, type, created_at, transporter, transport_fee, iscancelled, product_id, warehouse_id, imei, note',
          'partnerField': 'transporter',
          'amountField': 'transport_fee',
          'dateField': 'created_at',
          'snapshotKey': 'id',
        },
    ];

    for (final table in tables) {
      try {
        final tableName = table['table'] as String;
        final select = table['select'] as String;
        final partnerField = table['partnerField'] as String;
        final amountField = table['amountField'];
        final dateField = table['dateField'] as String;
        final keyField = table['key'] as String;

        // Thử SELECT với note, nếu lỗi thì SELECT lại không có note
        List<dynamic> response;
        String selectToUse = select;
        try {
          dynamic query = widget.tenantClient.from(tableName).select(selectToUse);
        query = query.eq('iscancelled', false);
        if (dateFrom != null) {
          query = query.gte(dateField, dateFrom!.toIso8601String());
        }
        if (dateTo != null) {
          query = query.lte(dateField, dateTo!.toIso8601String());
        }
        query = query.order(dateField, ascending: false);

        if (paginated && filterType == 'all' && dateFrom == null && dateTo == null) {
          final start = currentPage * pageSize;
          final end = start + pageSize - 1;
          response = await query.range(start, end);
          developer.log('fetchTickets: Fetched ${response.length} from $tableName (paginated)');
        } else {
          response = await query;
          developer.log('fetchTickets: Fetched ${response.length} from $tableName');
          }
        } catch (e) {
          // Nếu lỗi (có thể do cột note không tồn tại), thử lại không có note
          developer.log('fetchTickets: Error with note column for $tableName, retrying without note: $e');
          // Loại bỏ note khỏi SELECT statement (xử lý các trường hợp: note ở đầu, giữa, cuối)
          final selectParts = select.split(',').map((s) => s.trim()).where((s) => s != 'note').toList();
          selectToUse = selectParts.join(', ');
          dynamic query = widget.tenantClient.from(tableName).select(selectToUse);
          query = query.eq('iscancelled', false);
          if (dateFrom != null) {
            query = query.gte(dateField, dateFrom!.toIso8601String());
          }
          if (dateTo != null) {
            query = query.lte(dateField, dateTo!.toIso8601String());
          }
          query = query.order(dateField, ascending: false);

          if (paginated && filterType == 'all' && dateFrom == null && dateTo == null) {
            final start = currentPage * pageSize;
            final end = start + pageSize - 1;
            response = await query.range(start, end);
            developer.log('fetchTickets: Fetched ${response.length} from $tableName without note (paginated)');
          } else {
            response = await query;
            developer.log('fetchTickets: Fetched ${response.length} from $tableName without note');
          }
        }

        final groupedTickets = <String, Map<String, dynamic>>{};
        for (var tx in response) {
          String ticketKey;
          String ticketKeyField;
          if (tableName == 'transporter_orders' && tx['type'] == 'nhập kho vận chuyển' && tx['ticket_id'] != null) {
            ticketKey = tx['ticket_id'].toString();
            ticketKeyField = 'ticket_id';
          } else {
            ticketKey = tx[keyField]?.toString() ?? '';
            ticketKeyField = keyField;
            if (ticketKey.isEmpty) {
              developer.log('fetchTickets: Invalid ticket key for $tableName, skipping');
              continue;
            }
          }

          String productName = 'N/A';
          String warehouseName = 'N/A';
          String imeiList = tx['imei']?.toString() ?? 'N/A';

          final productId = tx['product_id']?.toString();
          final warehouseId = tx['warehouse_id']?.toString();

          if (productId != null && productMap.containsKey(productId)) {
            productName = productMap[productId]!;
          }
          if (warehouseId != null && warehouseMap.containsKey(warehouseId)) {
            warehouseName = warehouseMap[warehouseId]!;
          }

          num quantity = 0;
          if (tableName != 'transporter_orders') {
            try {
              quantity = num.tryParse(tx['quantity']?.toString() ?? '0') ?? 0;
            } catch (e) {
              developer.log('fetchTickets: Error parsing quantity for $tableName, record: ${tx['id'] ?? tx['ticket_id']}, quantity: ${tx['quantity']}, error: $e');
            }
          } else {
            quantity = imeiList != 'N/A' ? imeiList.split(',').map((e) => e.trim()).where((e) => e.isNotEmpty).length : 0;
          }

          if (!groupedTickets.containsKey(ticketKey)) {
            // Lấy tên đối tác - đặc biệt xử lý cho các loại phiếu
            String partnerName;
            if (tableName == 'financial_orders') {
              partnerName = _getPartnerName(
                tx['partner_id']?.toString(),
                tx['partner_type']?.toString(),
                tx[partnerField]?.toString(),
              );
            } else if (tableName == 'import_orders' || tableName == 'return_orders') {
              // Nhà cung cấp - dùng supplier_id
              final supplierId = tx[partnerField]?.toString();
              partnerName = supplierId != null ? (supplierMap[supplierId] ?? 'N/A') : 'N/A';
            } else if (tableName == 'sale_orders' || tableName == 'reimport_orders') {
              // Khách hàng - dùng customer_id
              final customerId = tx[partnerField]?.toString();
              partnerName = customerId != null ? (customerMap[customerId] ?? 'N/A') : 'N/A';
            } else if (tableName == 'fix_send_orders' || tableName == 'fix_receive_orders') {
              // Đơn vị fix - dùng fix_unit_id nếu có, nếu không dùng fixer (tên)
              final fixUnitId = tx['fix_unit_id']?.toString();
              if (fixUnitId != null) {
                partnerName = fixerMap[fixUnitId] ?? 'N/A';
              } else {
                partnerName = tx[partnerField]?.toString() ?? 'N/A';
              }
            } else {
              partnerName = tx[partnerField]?.toString() ?? 'N/A';
            }
            
            groupedTickets[ticketKey] = {
              'table': tableName,
              'key': ticketKeyField,
              'id': ticketKey,
              'type': tableName == 'financial_orders' || tableName == 'transporter_orders' ? (tx['type'] ?? tableName) : tableName,
              'partner': partnerName,
              'date': tx[dateField]?.toString() ?? '',
              'snapshot_data': null,
              'snapshot_created_at': null,
              'items': [],
              'total_quantity': 0,
              'total_amount': 0,
              'currency': 'VND',
              'product_name': productName,
              'warehouse_name': warehouseName,
              'imei': tableName == 'transporter_orders' || tableName == 'fix_send_orders' || tableName == 'fix_receive_orders' || tableName == 'sale_orders' || tableName == 'return_orders' || tableName == 'reimport_orders' || tableName == 'import_orders' ? '' : null,
              'note': tx['note']?.toString(),
            };
          }

          // Lấy tên đối tác cho item - đặc biệt xử lý cho các loại phiếu
          String itemPartnerName;
          if (tableName == 'financial_orders') {
            itemPartnerName = _getPartnerName(
              tx['partner_id']?.toString(),
              tx['partner_type']?.toString(),
              tx[partnerField]?.toString(),
            );
          } else if (tableName == 'import_orders' || tableName == 'return_orders') {
            // Nhà cung cấp - dùng supplier_id
            final supplierId = tx[partnerField]?.toString();
            itemPartnerName = supplierId != null ? (supplierMap[supplierId] ?? 'N/A') : 'N/A';
          } else if (tableName == 'sale_orders' || tableName == 'reimport_orders') {
            // Khách hàng - dùng customer_id
            final customerId = tx[partnerField]?.toString();
            itemPartnerName = customerId != null ? (customerMap[customerId] ?? 'N/A') : 'N/A';
          } else if (tableName == 'fix_send_orders' || tableName == 'fix_receive_orders') {
            // Đơn vị fix - dùng fix_unit_id nếu có, nếu không dùng fixer (tên)
            final fixUnitId = tx['fix_unit_id']?.toString();
            if (fixUnitId != null) {
              itemPartnerName = fixerMap[fixUnitId] ?? 'N/A';
            } else {
              itemPartnerName = tx[partnerField]?.toString() ?? 'N/A';
            }
          } else {
            itemPartnerName = tx[partnerField]?.toString() ?? 'N/A';
          }
          
          final item = {
            'amount': amountField != null ? num.tryParse(tx[amountField]?.toString() ?? '0') : null,
            'currency': tx['currency']?.toString() ?? 'VND',
            'quantity': quantity,
            'total_amount': tx['total_amount'],
            'account': tx['account']?.toString(),
            'partner_type': tx['partner_type'],
            'from_amount': tx['from_amount'],
            'from_currency': tx['from_currency'],
            'to_amount': tx['to_amount'],
            'to_currency': tx['to_currency'],
            'to_account': tx['to_account'],
            'customer_price': tx['customer_price'],
            'transporter_price': tx['transporter_price'],
            'transporter': tx['transporter'],
            'product_id': tx['product_id'],
            'warehouse_id': tx['warehouse_id'],
            'imei': tx['imei'],
            'product_name': productName,
            'warehouse_name': warehouseName,
            'partner': itemPartnerName, // Lưu partner cho từng item
            'saleman': tx['saleman']?.toString(), // Lưu nhân viên bán
            'note': tx['note']?.toString(), // Lưu ghi chú
            'doanhso': tx['doanhso'], // Lưu doanh số nhân viên
          };

          final ticket = groupedTickets[ticketKey]!;
          (ticket['items'] as List<dynamic>).add(item);
          ticket['total_quantity'] = (ticket['total_quantity'] as num) + quantity;

          if (tableName == 'transporter_orders' && tx['type'] == 'nhập kho vận chuyển') {
            final amount = num.tryParse(tx['transport_fee']?.toString() ?? '0') ?? 0;
            ticket['total_amount'] = (ticket['total_amount'] as num) + amount;
            developer.log('fetchTickets: Added transport_fee=$amount to total_amount=${ticket['total_amount']} for ticket_id=$ticketKey');
          } else if (tableName != 'fix_send_orders') {
            final amount = tx['total_amount'] ?? (item['amount'] ?? 0) * (quantity > 0 ? quantity : 1);
            ticket['total_amount'] = (ticket['total_amount'] as num) + amount;
            ticket['currency'] = tx['currency']?.toString() ?? ticket['currency'];
          }

          if ((tableName == 'transporter_orders' || tableName == 'fix_send_orders' || tableName == 'fix_receive_orders' || tableName == 'sale_orders' || tableName == 'return_orders' || tableName == 'reimport_orders' || tableName == 'import_orders') &&
              item['imei'] != null) {
            ticket['imei'] = ticket['imei']!.isEmpty ? item['imei'] : '${ticket['imei']}, ${item['imei']}';
          }

          ticketIds.add(ticketKey);
        }

        allTickets.addAll(groupedTickets.values);
      } catch (e) {
        developer.log('fetchTickets: Error fetching ${table['table']}: $e');
      }
    }

    if (ticketIds.isNotEmpty) {
      try {
        final snapshotResponse = await widget.tenantClient
            .from('snapshots')
            .select('ticket_id, ticket_table, snapshot_data, created_at')
            .inFilter('ticket_id', ticketIds.toList());

        final snapshotMap = <String, Map<String, dynamic>>{};
        for (var snapshot in snapshotResponse) {
          final key = '${snapshot['ticket_table']}:${snapshot['ticket_id']}';
          snapshotMap[key] = snapshot;
        }

        for (var ticket in allTickets) {
          final snapshot = snapshotMap['${ticket['table']}:${ticket['id']}'];
          ticket['snapshot_data'] = snapshot?['snapshot_data'] ?? {};
          ticket['snapshot_created_at'] = snapshot?['created_at'];
        }
      } catch (e) {
        developer.log('fetchTickets: Error fetching snapshots: $e');
        for (var ticket in allTickets) {
          ticket['snapshot_data'] = {};
        }
      }
    }

    allTickets = allTickets.where((ticket) => filterType == 'all' || ticket['type'] == filterType).toList();

    allTickets.sort((a, b) {
      final dateA = DateTime.tryParse(a['date']?.toString() ?? '1900-01-01') ?? DateTime(1900);
      final dateB = DateTime.tryParse(b['date']?.toString() ?? '1900-01-01') ?? DateTime(1900);
      return dateB.compareTo(dateA);
    });

    return allTickets;
  }

  void _showTransactionDetails(Map<String, dynamic> ticket) {
    String? saleman;
    num? totalDoanhso;
    if (ticket['table'] == 'sale_orders' && ticket['items'] is List<dynamic>) {
      final items = ticket['items'] as List<dynamic>;
      if (items.isNotEmpty) {
        final salemanSet = items
            .map((item) => item['saleman'])
            .whereType<String>()
            .where((s) => s.isNotEmpty)
            .toSet();
        saleman = salemanSet.isNotEmpty ? salemanSet.join(', ') : null;
        
        // Tính tổng doanh số của phiếu
        totalDoanhso = items.fold<num>(
          0,
          (sum, item) {
            final doanhso = item['doanhso'];
            if (doanhso != null) {
              final doanhsoValue = num.tryParse(doanhso.toString()) ?? 0;
              return sum + doanhsoValue;
            }
            return sum;
          },
        );
      }
    }

    final isFinancialTicket = ticket['table'] == 'financial_orders';
    final financialType = ticket['type'] as String?;
    
    // Kiểm tra nếu có nhiều đối tác khác nhau trong ticket
    final hasMultiplePartners = ticket['table'] == 'return_orders' || ticket['table'] == 'reimport_orders';
    final uniquePartners = hasMultiplePartners 
        ? (ticket['items'] as List).map((item) => item['partner'] as String? ?? 'N/A').toSet()
        : <String>{};
    final displayPartner = hasMultiplePartners && uniquePartners.length > 1
        ? 'Nhiều đối tác (${uniquePartners.length})'
        : ticket['partner'];

    showDialog(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text('Chi tiết phiếu', style: TextStyle(fontWeight: FontWeight.bold)),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Loại Phiếu: ${_getDisplayType(ticket['type'], ticket['table'])}'),
                Text('Đối tác: $displayPartner'),
                if (isFinancialTicket && financialType == 'exchange') ...[
                  Text('Số Tiền Đổi: ${_formatNumber(ticket['items'][0]['from_amount'])} ${ticket['items'][0]['from_currency']}'),
                  if (ticket['items'][0]['to_amount'] != null && ticket['items'][0]['to_currency'] != null)
                    Text('Số Tiền Nhận: ${_formatNumber(ticket['items'][0]['to_amount'])} ${ticket['items'][0]['to_currency']}'),
                ] else if (isFinancialTicket)
                  Text('Số Tiền: ${_formatNumber(ticket['items'][0]['amount'])} ${ticket['items'][0]['currency'] ?? 'VND'}')
                else
                  Text('Tổng Tiền: ${_formatNumber(ticket['total_amount'])} ${ticket['currency'] ?? 'VND'}'),
                Text('Ngày: ${_formatDate(ticket['date'])}'),
                if (!isFinancialTicket) ...[
                  Text('Số Lượng: ${ticket['table'] == 'transporter_orders' ? ticket['total_quantity'] : _formatNumber(ticket['total_quantity'])}'),
                ],
                if (ticket['items'][0]['account'] != null && !isFinancialTicket)
                  Text('Tài Khoản: ${ticket['items'][0]['account']}'),
                if (saleman != null) Text('Nhân viên bán: $saleman'),
                if (totalDoanhso != null && totalDoanhso > 0)
                  Text('Doanh số nhân viên: ${_formatNumber(totalDoanhso)}'),
                if (!isFinancialTicket) ...[
                  ...ticket['items'].map<Widget>((item) {
                    final productName = item['product_name']?.toString() ?? 'N/A';
                    final quantity = item['quantity'] as num? ?? 0;
                    if (productName != 'N/A' && quantity > 0) {
                      return Text('Sản phẩm: $productName x${quantity.toInt()}');
                    }
                    return const SizedBox.shrink();
                  }).toList(),
                ],
                if (ticket['warehouse_name'] != null && ticket['warehouse_name'] != 'N/A')
                  Text('Kho: ${ticket['warehouse_name']}'),
                if (ticket['note'] != null && ticket['note'].toString().isNotEmpty)
                  Text('Ghi chú: ${ticket['note']}'),
                if (!isFinancialTicket) ...[
                  const SizedBox(height: 8),
                  const Text('Chi tiết sản phẩm:', style: TextStyle(fontWeight: FontWeight.bold)),
                  ...ticket['items'].asMap().entries.map((entry) {
                    final item = entry.value;
                    final currentTable = ticket['table'] as String;
                    return Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        if (ticket['items'].length > 1) Text('Sản phẩm ${entry.key + 1}:'),
                        if (hasMultiplePartners && item['partner'] != null)
                          Text('  Đối tác: ${item['partner']}'),
                        if (currentTable != 'transporter_orders' && item['quantity'] != null)
                          Text('  Số Lượng: ${item['quantity']}'),
                        if (currentTable == 'transporter_orders' && item['imei'] != null)
                          Text('  Số Lượng: ${(item['imei'] as String).split(',').map((e) => e.trim()).where((e) => e.isNotEmpty).length}'),
                        if (item['amount'] != null) Text('  Giá: ${_formatNumber(item['amount'])} ${item['currency']}'),
                        if (item['total_amount'] != null) Text('  Tổng: ${_formatNumber(item['total_amount'])} ${item['currency']}'),
                        if (item['product_name'] != null && item['product_name'] != 'N/A')
                          Text('  Sản phẩm: ${item['product_name']}'),
                        if (item['warehouse_name'] != null && item['warehouse_name'] != 'N/A')
                          Text('  Kho: ${item['warehouse_name']}'),
                        if (item['imei'] != null) Text('  IMEI: ${item['imei']}'),
                        if (item['doanhso'] != null && item['doanhso'] != 0)
                          Text('  Doanh số: ${_formatNumber(item['doanhso'])}'),
                        if (item['note'] != null && item['note'].toString().isNotEmpty)
                          Text('  Ghi chú: ${item['note']}'),
                      ],
                    );
                  }),
                ],
              ],
            ),
          ),
          actions: [
            if (widget.permissions.contains('cancel_transaction'))
              TextButton(
                onPressed: () => _confirmCancelTicket(ticket),
                child: const Text('Hủy Phiếu', style: TextStyle(color: Colors.red)),
              ),
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Đóng'),
            ),
          ],
        );
      },
    );
  }

  Future<bool> _isLatestTicket(Map<String, dynamic> ticket) async {
    final table = ticket['table'] as String;
    final ticketId = ticket['id'] as String;
    final keyField = ticket['key'] as String;

    try {
      developer.log('isLatestTicket: Checking ticket_id: $ticketId in table: $table, keyField: $keyField');

      // Kiểm tra snapshot tồn tại cho phiếu cần hủy
      final snapshot = await widget.tenantClient
          .from('snapshots')
          .select('ticket_id, ticket_table, created_at')
          .eq('ticket_id', ticketId)
          .eq('ticket_table', table)
          .limit(1)
          .maybeSingle();

      if (snapshot == null) {
        developer.log('isLatestTicket: No snapshot found for ticket_id: $ticketId in table: $table');
        return false;
      }

      // Lấy snapshot mới nhất từ bảng snapshots
      final latestSnapshot = await widget.tenantClient
          .from('snapshots')
          .select('ticket_id, ticket_table, created_at')
          .order('created_at', ascending: false)
          .limit(1)
          .maybeSingle();

      if (latestSnapshot == null) {
        developer.log('isLatestTicket: No snapshots found in snapshots table');
        return false;
      }

      final latestTicketId = latestSnapshot['ticket_id']?.toString();
      final latestTicketTable = latestSnapshot['ticket_table']?.toString();
      final latestSnapshotCreatedAt = latestSnapshot['created_at']?.toString();

      developer.log('isLatestTicket: Latest snapshot: ticket_id=$latestTicketId, table=$latestTicketTable, created_at=$latestSnapshotCreatedAt');

      // So sánh snapshot của phiếu cần hủy với snapshot mới nhất
      if (latestTicketId != ticketId || latestTicketTable != table) {
        developer.log('isLatestTicket: Ticket $ticketId in $table is not the latest. Latest is $latestTicketId in $latestTicketTable');
        return false;
      }

      // Kiểm tra phiếu có iscancelled = false
      final ticketRecord = await widget.tenantClient
          .from(table)
          .select(keyField)
          .eq(keyField, ticketId)
          .eq('iscancelled', false)
          .limit(1)
          .maybeSingle();

      if (ticketRecord == null) {
        developer.log('isLatestTicket: Ticket $ticketId in $table is already cancelled or does not exist');
        return false;
      }

      developer.log('isLatestTicket: Ticket $ticketId in $table is the latest with valid snapshot');
      return true;
    } catch (e) {
      developer.log('isLatestTicket: Error checking ticket_id: $ticketId in table: $table, error: $e');
      return false;
    }
  }

  Future<void> _confirmCancelTicket(Map<String, dynamic> ticket) async {
    final table = ticket['table'] as String;
    final ticketId = ticket['id'] as String;
    developer.log('confirmCancelTicket: Initiating for ticket_id: $ticketId, table: $table');

    // Kiểm tra snapshot
    if (ticket['snapshot_data'] == null || ticket['snapshot_data'].isEmpty) {
      developer.log('confirmCancelTicket: No snapshot data found for ticket_id: $ticketId');
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Không thể hủy: Không tìm thấy snapshot')),
      );
      return;
    }
    developer.log('confirmCancelTicket: Snapshot data exists for ticket_id: $ticketId');

    // Kiểm tra phiếu mới nhất
    final isLatest = await _isLatestTicket(ticket);
    if (!isLatest) {
      developer.log('confirmCancelTicket: Ticket $ticketId is not the latest in $table');
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Không thể hủy: Chỉ hủy được phiếu mới nhất chưa bị hủy')),
      );
      return;
    }
    developer.log('confirmCancelTicket: Ticket $ticketId is confirmed as the latest');

    // Hiển thị dialog xác nhận
    developer.log('confirmCancelTicket: Showing confirmation dialog for ticket_id: $ticketId');
    showDialog(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text('Xác nhận hủy phiếu'),
          content: const Text('Bạn có chắc muốn hủy phiếu này? Dữ liệu sẽ được khôi phục từ snapshot.'),
          actions: [
            TextButton(
              onPressed: () {
                developer.log('confirmCancelTicket: User cancelled for ticket_id: $ticketId');
                Navigator.pop(context);
              },
              child: const Text('Hủy bỏ'),
            ),
            TextButton(
              onPressed: () async {
                developer.log('confirmCancelTicket: User confirmed cancellation for ticket_id: $ticketId');
                try {
                  // Khôi phục snapshot (bao gồm cả doanhso từ sub_accounts nếu có trong snapshot)
                  developer.log('confirmCancelTicket: Restoring snapshot for ticket_id: $ticketId');
                  await _restoreFromSnapshot(ticket);

                  // Cập nhật iscancelled
                  final keyField = ticket['key'] as String;
                  developer.log('confirmCancelTicket: Updating iscancelled for ticket_id: $ticketId in $table, keyField: $keyField');
                  await widget.tenantClient
                      .from(table)
                      .update({'iscancelled': true})
                      .eq(keyField, ticketId);
                  developer.log('confirmCancelTicket: Updated iscancelled to true for ticket_id: $ticketId');

                  // Xóa snapshot
                  developer.log('confirmCancelTicket: Deleting snapshot for ticket_id: $ticketId');
                  await widget.tenantClient
                      .from('snapshots')
                      .delete()
                      .eq('ticket_id', ticketId)
                      .eq('ticket_table', table);
                  developer.log('confirmCancelTicket: Snapshot deleted for ticket_id: $ticketId');

                  Navigator.pop(context); // Đóng dialog xác nhận
                  Navigator.pop(context); // Đóng dialog chi tiết
                  setState(() {
                    _loadTickets();
                  });
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('Hủy phiếu thành công')),
                  );
                  developer.log('confirmCancelTicket: Successfully cancelled ticket_id: $ticketId');
                } catch (e) {
                  developer.log('confirmCancelTicket: Error cancelling ticket_id: $ticketId, error: $e');
                  Navigator.pop(context);
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text('Lỗi khi hủy phiếu: $e')),
                  );
                }
              },
              child: const Text('Xác nhận', style: TextStyle(color: Colors.red)),
            ),
          ],
        );
      },
    );
  }

  Future<void> _restoreFromSnapshot(Map<String, dynamic> ticket) async {
    final snapshotData = ticket['snapshot_data'] as Map<String, dynamic>?;
    final table = ticket['table'] as String;
    final ticketId = ticket['id'] as String;

    developer.log('restoreSnapshot: Starting for ticket_id: $ticketId in table: $table');

    if (snapshotData == null) {
      developer.log('restoreSnapshot: Snapshot data is null for ticket_id: $ticketId');
      throw Exception('Snapshot data is null');
    }

    try {
      if (snapshotData['products'] != null) {
        final productsData = snapshotData['products'] as List<dynamic>;
        developer.log('restoreSnapshot: Restoring ${productsData.length} products');
        if (table == 'import_orders') {
          final orders = snapshotData['import_orders'] as List<dynamic>? ?? [];
          final imeiList = orders
              .expand((order) => (order['imei'] as String?)?.split(',').where((e) => e.trim().isNotEmpty) ?? [])
              .toList();
          developer.log('restoreSnapshot: Deleting ${imeiList.length} IMEIs');
          for (int i = 0; i < imeiList.length; i += 1000) {
            final batchImeis = imeiList.sublist(i, i + 1000 < imeiList.length ? i + 1000 : imeiList.length);
            developer.log('restoreSnapshot: Deleting batch of ${batchImeis.length} IMEIs');
            await widget.tenantClient.from('products').delete().inFilter('imei', batchImeis);
          }
        } else if (table == 'return_orders' || table == 'sale_orders' || table == 'fix_send_orders' || table == 'fix_receive_orders' || table == 'reimport_orders' || table == 'transporter_orders') {
          for (var product in productsData) {
            if (product['imei'] != null) {
              developer.log('restoreSnapshot: Updating product with IMEI: ${product['imei']}');
              await widget.tenantClient.from('products').update(product).eq('imei', product['imei']);
            } else if (product['id'] != null) {
              developer.log('restoreSnapshot: Updating product with ID: ${product['id']}');
              await widget.tenantClient.from('products').update(product).eq('id', product['id']);
            } else {
              developer.log('restoreSnapshot: Skipping product update: no IMEI or ID');
            }
          }
        }
      } else {
        developer.log('restoreSnapshot: No products data in snapshot');
      }

      if (snapshotData['suppliers'] != null) {
        final suppliersData = snapshotData['suppliers'];
        if (suppliersData is List) {
          // New format: List of suppliers
          developer.log('restoreSnapshot: Restoring ${suppliersData.length} suppliers');
          for (var supplierData in suppliersData) {
            final supplierId = supplierData['id']?.toString();
            final supplierName = supplierData['name'];
            developer.log('restoreSnapshot: Restoring supplier: $supplierName (id: $supplierId)');
            if (supplierId != null) {
              await widget.tenantClient.from('suppliers').update({
                'debt_vnd': supplierData['debt_vnd'] ?? 0,
                'debt_cny': supplierData['debt_cny'] ?? 0,
                'debt_usd': supplierData['debt_usd'] ?? 0,
              }).eq('id', supplierId);
            } else {
              // Fallback to name if id not available (for old snapshots)
              developer.log('restoreSnapshot: Warning - Using name fallback for supplier: $supplierName');
              await widget.tenantClient.from('suppliers').update({
                'debt_vnd': supplierData['debt_vnd'] ?? 0,
                'debt_cny': supplierData['debt_cny'] ?? 0,
                'debt_usd': supplierData['debt_usd'] ?? 0,
              }).eq('name', supplierName);
            }
          }
        } else {
          // Old format: Single supplier as Map (backward compatibility)
          final supplierData = suppliersData as Map<String, dynamic>;
          final supplierId = supplierData['id']?.toString();
          final supplierName = supplierData['name'];
          developer.log('restoreSnapshot: Restoring supplier: $supplierName (id: $supplierId)');
          if (supplierId != null) {
            await widget.tenantClient.from('suppliers').update({
              'debt_vnd': supplierData['debt_vnd'] ?? 0,
              'debt_cny': supplierData['debt_cny'] ?? 0,
              'debt_usd': supplierData['debt_usd'] ?? 0,
            }).eq('id', supplierId);
          } else {
            // Fallback to name if id not available (for old snapshots)
            developer.log('restoreSnapshot: Warning - Using name fallback for supplier: $supplierName');
            await widget.tenantClient.from('suppliers').update({
              'debt_vnd': supplierData['debt_vnd'] ?? 0,
              'debt_cny': supplierData['debt_cny'] ?? 0,
              'debt_usd': supplierData['debt_usd'] ?? 0,
            }).eq('name', supplierName);
          }
        }
      }

      if (snapshotData['customers'] != null) {
        final customersData = snapshotData['customers'] is List ? snapshotData['customers'] as List<dynamic> : [snapshotData['customers']];
        developer.log('restoreSnapshot: Restoring ${customersData.length} customers');
        for (var customerData in customersData) {
          final customerId = customerData['id']?.toString();
          final customerName = customerData['name'];
          developer.log('restoreSnapshot: Restoring customer: $customerName (id: $customerId)');
          if (customerId != null) {
            await widget.tenantClient.from('customers').update({
              'debt_vnd': customerData['debt_vnd'] ?? 0,
              'debt_cny': customerData['debt_cny'] ?? 0,
              'debt_usd': customerData['debt_usd'] ?? 0,
            }).eq('id', customerId);
          } else {
            // Fallback to name if id not available (for old snapshots)
            developer.log('restoreSnapshot: Warning - Using name fallback for customer: $customerName');
            await widget.tenantClient.from('customers').update({
              'debt_vnd': customerData['debt_vnd'] ?? 0,
              'debt_cny': customerData['debt_cny'] ?? 0,
              'debt_usd': customerData['debt_usd'] ?? 0,
            }).eq('name', customerName);
          }
        }
      }

      if (snapshotData['financial_accounts'] != null) {
        final accountData = snapshotData['financial_accounts'] as Map<String, dynamic>;
        if (accountData['from_account'] != null) {
          final fromAccountData = Map<String, dynamic>.from(accountData['from_account']);
          fromAccountData.remove('id');
          developer.log('restoreSnapshot: Restoring from_account: ${fromAccountData['name']}');
          await widget.tenantClient.from('financial_accounts').update(fromAccountData).eq('name', fromAccountData['name']);
        }
        if (accountData['to_account'] != null) {
          final toAccountData = Map<String, dynamic>.from(accountData['to_account']);
          toAccountData.remove('id');
          developer.log('restoreSnapshot: Restoring to_account: ${toAccountData['name']}');
          await widget.tenantClient.from('financial_accounts').update(toAccountData).eq('name', toAccountData['name']);
        } else if (accountData['name'] != null) {
          final singleAccountData = Map<String, dynamic>.from(accountData);
          singleAccountData.remove('id');
          developer.log('restoreSnapshot: Restoring single account: ${singleAccountData['name']}');
          await widget.tenantClient.from('financial_accounts').update(singleAccountData).eq('name', singleAccountData['name']);
        }
      }

      if (snapshotData['transporters'] != null) {
        final transportersData = snapshotData['transporters'] is List ? snapshotData['transporters'] as List<dynamic> : [snapshotData['transporters']];
        developer.log('restoreSnapshot: Restoring ${transportersData.length} transporters');
        for (var transporterData in transportersData) {
          developer.log('restoreSnapshot: Restoring transporter: ${transporterData['name']}, debt: ${transporterData['debt']}');
          await widget.tenantClient.from('transporters').update({
            'debt': transporterData['debt'] ?? 0,
          }).eq('name', transporterData['name']);
        }
      }

      if (snapshotData['fix_units'] != null) {
        final fixUnitsData = snapshotData['fix_units'] is List ? snapshotData['fix_units'] as List<dynamic> : [snapshotData['fix_units']];
        developer.log('restoreSnapshot: Restoring ${fixUnitsData.length} fix units');
        for (var fixUnitData in fixUnitsData) {
          developer.log('restoreSnapshot: Restoring fix_unit: ${fixUnitData['name']}');
          // Use id if available, otherwise fallback to name
          if (fixUnitData['id'] != null) {
            await widget.tenantClient.from('fix_units').update(fixUnitData).eq('id', fixUnitData['id']);
          } else {
            await widget.tenantClient.from('fix_units').update(fixUnitData).eq('name', fixUnitData['name']);
          }
        }
      }

      // ✅ Khôi phục doanhso từ sub_accounts snapshot (cho sale_orders và reimport_orders)
      if (snapshotData['sub_accounts'] != null && (table == 'sale_orders' || table == 'reimport_orders')) {
        final subAccountData = snapshotData['sub_accounts'];
        
        // Xử lý cả Map (1 nhân viên) và List (nhiều nhân viên)
        if (subAccountData is Map<String, dynamic>) {
          // Trường hợp 1 nhân viên
          final username = subAccountData['username']?.toString();
          final doanhso = subAccountData['doanhso'];
          
          if (username != null && username.isNotEmpty) {
            try {
              developer.log('restoreSnapshot: Restoring sub_account doanhso for username: $username, doanhso: $doanhso');
              
              // Parse doanhso - có thể là int hoặc double
              final doanhsoValue = doanhso is int 
                  ? doanhso
                  : doanhso is double
                      ? doanhso.round()
                      : int.tryParse(doanhso?.toString() ?? '0') ?? 0;
              
              await widget.tenantClient
                  .from('sub_accounts')
                  .update({'doanhso': doanhsoValue})
                  .eq('username', username);
              
              developer.log('restoreSnapshot: ✅ Successfully restored sub_account doanhso for username: $username');
            } catch (e) {
              developer.log('restoreSnapshot: ❌ ERROR restoring sub_account doanhso: $e');
              // Không throw để tiếp tục restore các dữ liệu khác
            }
          }
        } else if (subAccountData is List) {
          // Trường hợp nhiều nhân viên (reimport_orders có thể có nhiều IMEI từ nhiều nhân viên)
          for (var accountData in subAccountData) {
            if (accountData is Map<String, dynamic>) {
              final username = accountData['username']?.toString();
              final doanhso = accountData['doanhso'];
              
              if (username != null && username.isNotEmpty) {
                try {
                  developer.log('restoreSnapshot: Restoring sub_account doanhso for username: $username, doanhso: $doanhso');
                  
                  // Parse doanhso - có thể là int hoặc double
                  final doanhsoValue = doanhso is int 
                      ? doanhso
                      : doanhso is double
                          ? doanhso.round()
                          : int.tryParse(doanhso?.toString() ?? '0') ?? 0;
                  
                  await widget.tenantClient
                      .from('sub_accounts')
                      .update({'doanhso': doanhsoValue})
                      .eq('username', username);
                  
                  developer.log('restoreSnapshot: ✅ Successfully restored sub_account doanhso for username: $username');
                } catch (e) {
                  developer.log('restoreSnapshot: ❌ ERROR restoring sub_account doanhso for username $username: $e');
                  // Không throw để tiếp tục restore các nhân viên khác
                }
              }
            }
          }
        }
      }

      const validTables = [
        'financial_orders',
        'sale_orders',
        'import_orders',
        'return_orders',
        'reimport_orders',
        'fix_send_orders',
        'fix_receive_orders',
        'transporter_orders',
      ];
      for (var relatedTable in validTables) {
        if (snapshotData[relatedTable] != null && relatedTable != table) {
          final orders = snapshotData[relatedTable] as List<dynamic>;
          developer.log('restoreSnapshot: Restoring ${orders.length} orders in $relatedTable');
          for (var order in orders) {
            await widget.tenantClient.from(relatedTable).upsert(order);
          }
        }
      }

      developer.log('restoreSnapshot: Success for ticket_id: $ticketId in table: $table');
    } catch (e) {
      developer.log('restoreSnapshot: Error for ticket_id: $ticketId in table: $table, error: $e');
      throw Exception('Failed to restore snapshot: $e');
    }
  }

  Future<void> _exportToExcel() async {
    if (isExporting) return;

    setState(() => isExporting = true);

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: const [
            CircularProgressIndicator(),
            SizedBox(height: 16),
            Text('Đang xuất Excel...', textAlign: TextAlign.center),
          ],
        ),
      ),
    );

    try {
      // Kiểm tra và yêu cầu quyền lưu trữ (nếu cần) - Android 13+ không cần
      final hasPermission = await StorageHelper.requestStoragePermissionIfNeeded();
      if (!hasPermission) {
          Navigator.pop(context);
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Cần quyền lưu trữ để xuất Excel')),
          );
          return;
      }

      List<Map<String, dynamic>> exportTickets = tickets;
      if (hasMoreData && filterType == 'all' && dateFrom == null && dateTo == null) {
        exportTickets = await _fetchTickets(paginated: false);
      }

      if (exportTickets.isEmpty) {
        Navigator.pop(context);
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Không có phiếu để xuất')),
        );
        return;
      }

      final excel = Excel.createExcel();
      excel.delete('Sheet1');
      final sheet = excel['LichSuPhieu'];

      final headerLabels = <String>[
        'Loại Phiếu',
        'Đối Tác',
        'Sản phẩm',
        'Kho',
        'IMEI',
        'Số Tiền',
        'Đơn Vị Tiền',
        'Số Lượng',
        'Ngày',
        'Tài Khoản',
        'Nhân viên bán',
        'Doanh số nhân viên',
        'Ghi chú',
      ];
      final headers = headerLabels.map(TextCellValue.new).toList();

      sheet.appendRow(headers);

      final border = Border(borderStyle: BorderStyle.Thin);
      final headerStyle = CellStyle(
        bold: true,
        topBorder: border,
        bottomBorder: border,
        leftBorder: border,
        rightBorder: border,
        verticalAlign: VerticalAlign.Center,
        horizontalAlign: HorizontalAlign.Center,
        textWrapping: TextWrapping.WrapText,
      );
      final dataStyle = CellStyle(
        topBorder: border,
        bottomBorder: border,
        leftBorder: border,
        rightBorder: border,
        verticalAlign: VerticalAlign.Center,
        horizontalAlign: HorizontalAlign.Center,
        textWrapping: TextWrapping.WrapText,
      );
      final multilineDataStyle = CellStyle(
        topBorder: border,
        bottomBorder: border,
        leftBorder: border,
        rightBorder: border,
        verticalAlign: VerticalAlign.Top,
        horizontalAlign: HorizontalAlign.Center,
        textWrapping: TextWrapping.WrapText,
      );

      final columnCount = headers.length;
      final maxColumnWidths = List<double>.filled(columnCount, 0);
      final Map<int, int> rowLineCounts = {};

      for (int columnIndex = 0; columnIndex < columnCount; columnIndex++) {
        final cell = sheet.cell(
          CellIndex.indexByColumnRow(columnIndex: columnIndex, rowIndex: 0),
        );
        cell.cellStyle = headerStyle;
        _updateExcelMetrics(
          rowLineCounts: rowLineCounts,
          maxColumnWidths: maxColumnWidths,
          rowIndex: 0,
          columnIndex: columnIndex,
          value: headerLabels[columnIndex],
        );
      }

      int dataRowIndex = 2; // Bắt đầu từ row 2 (sau header row)
      const multilineColumns = {4, 12};
      for (var ticket in exportTickets) {
        final tableName = ticket['table'] as String;
        final type = _getDisplayType(ticket['type'], tableName);
        final date = _formatDate(ticket['date']);

        // Create separate rows for each product in the ticket
        for (var item in ticket['items']) {
          // Sử dụng partner từ item nếu có (cho return_orders, reimport_orders), nếu không dùng partner chung
          final itemPartner = item['partner']?.toString() ?? ticket['partner'] ?? 'N/A';
          final productName = item['product_name']?.toString() ?? 'N/A';
          final warehouseName = item['warehouse_name']?.toString() ?? 'N/A';
          final imei = item['imei']?.toString() ?? 'N/A';
          final amount = item['amount'] ?? item['total_amount'] ?? 0;
          final currency = item['currency']?.toString() ?? 'VND';
          final quantity = tableName == 'transporter_orders' 
              ? (item['imei'] != null ? (item['imei'] as String).split(',').map((e) => e.trim()).where((e) => e.isNotEmpty).length.toString() : '0')
              : _formatNumber(item['quantity'] ?? 0);
          final account = (item['account'] != null && ticket['type'] != 'exchange' && ticket['type'] != 'payment' && ticket['type'] != 'transfer_fund')
              ? item['account'].toString()
              : '';
          final saleman = item['saleman']?.toString() ?? '';
          final doanhso = (item['doanhso'] != null && item['doanhso'] != 0)
              ? _formatNumber(item['doanhso'])
              : '';
          // Ưu tiên note của item, nếu không có thì lấy note của ticket
          final note = (item['note'] != null && item['note'].toString().isNotEmpty)
              ? item['note'].toString()
              : (ticket['note'] != null && ticket['note'].toString().isNotEmpty)
                  ? ticket['note'].toString()
                  : '';
          final imeiCellValue = _formatImeiForExcelCell(imei);

          final rowValues = <String>[
            type,
            itemPartner,
            productName,
            warehouseName,
            imeiCellValue,
            _formatNumber(amount),
            currency,
            quantity,
            date,
            account,
            saleman,
            doanhso,
            note,
          ];
          final rowData = rowValues.map(TextCellValue.new).toList();
          
          sheet.appendRow(rowData);

          final currentRowIndex = dataRowIndex - 1;
          for (int columnIndex = 0;
              columnIndex < columnCount;
              columnIndex++) {
            final cell = sheet.cell(
              CellIndex.indexByColumnRow(
                columnIndex: columnIndex,
                rowIndex: currentRowIndex,
              ),
            );
            final isMultiline = multilineColumns.contains(columnIndex);
            cell.cellStyle = isMultiline ? multilineDataStyle : dataStyle;
            _updateExcelMetrics(
              rowLineCounts: rowLineCounts,
              maxColumnWidths: maxColumnWidths,
              rowIndex: currentRowIndex,
              columnIndex: columnIndex,
              value: rowValues[columnIndex],
            );
          }

          dataRowIndex++;
        }
      }

      _applyExcelSizing(
        sheet: sheet,
        maxColumnWidths: maxColumnWidths,
        rowLineCounts: rowLineCounts,
      );

      if (excel.sheets.containsKey('Sheet1')) {
        excel.delete('Sheet1');
        print('Sheet1 đã được xóa trước khi xuất file.');
      } else {
        print('Không tìm thấy Sheet1 sau khi tạo các sheet.');
      }

      // Sử dụng StorageHelper để lấy thư mục Downloads (hỗ trợ Android 13+)
      final downloadsDir = await StorageHelper.getDownloadDirectory();
      if (downloadsDir == null) {
        Navigator.pop(context);
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Không thể truy cập thư mục Downloads')),
        );
        return;
      }

      final now = DateTime.now();
      final fileName = 'BaoCao_${now.day}_${now.month}_${now.year}_${now.hour}_${now.minute}_${now.second}.xlsx';
      final filePath = '${downloadsDir.path}/$fileName';
      final file = File(filePath);

      final excelBytes = excel.encode();
      if (excelBytes == null) {
        throw Exception('Không tạo được file Excel');
      }
      await file.writeAsBytes(excelBytes);

      Navigator.pop(context);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Đã xuất Excel: $filePath')),
      );

      final openResult = await OpenFile.open(filePath);
      if (openResult.type != ResultType.done) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Không mở được file. File lưu tại: $filePath')),
        );
      }
    } catch (e) {
      Navigator.pop(context);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Lỗi xuất Excel: $e')),
      );
    } finally {
      setState(() => isExporting = false);
    }
  }

  Widget _buildFilterRow() {
    return Row(
      children: [
        Expanded(
          flex: 3,
          child: ClipRect(
            child: DropdownButtonFormField<String>(
              value: filterType,
              isExpanded: true,
              isDense: true,
              items: ticketTypeOptions.map((option) {
                return DropdownMenuItem<String>(
                  value: option['value'],
                  child: Text(
                    option['display']!,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 12),
                  ),
                );
              }).toList(),
              onChanged: (value) {
                setState(() {
                  filterType = value ?? 'all';
                  hasMoreData = false;
                  _loadTickets();
                });
              },
              decoration: const InputDecoration(
                border: OutlineInputBorder(),
                contentPadding: EdgeInsets.symmetric(horizontal: 8, vertical: 8),
                floatingLabelBehavior: FloatingLabelBehavior.never,
              ),
            ),
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          flex: 2,
          child: TextField(
            controller: _dateFromController,
            decoration: const InputDecoration(
              labelText: 'Từ Ngày',
              border: OutlineInputBorder(),
              contentPadding: EdgeInsets.symmetric(horizontal: 8, vertical: 8),
            ),
            readOnly: true,
            onTap: () => _selectDate(context, true),
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          flex: 2,
          child: TextField(
            controller: _dateToController,
            decoration: const InputDecoration(
              labelText: 'Đến Ngày',
              border: OutlineInputBorder(),
              contentPadding: EdgeInsets.symmetric(horizontal: 8, vertical: 8),
            ),
            readOnly: true,
            onTap: () => _selectDate(context, false),
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Lịch Sử Giao Dịch', style: TextStyle(color: Colors.white)),
        backgroundColor: Colors.black,
        iconTheme: const IconThemeData(color: Colors.white),
      ),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Stack(
          children: [
            Column(
              children: [
                _buildFilterRow(),
                const SizedBox(height: 12),
                Expanded(
                  child: isLoadingTickets
                      ? const Center(child: CircularProgressIndicator())
                      : ticketError != null
                          ? Center(child: Text(ticketError!))
                          : tickets.isEmpty
                              ? const Center(child: Text('Không có giao dịch.'))
                              : ListView.builder(
                                  controller: _scrollController,
                                  itemCount: tickets.length + (isLoadingMore ? 1 : 0),
                                  itemBuilder: (context, index) {
                                    if (index == tickets.length) {
                                      return const Center(child: CircularProgressIndicator());
                                    }
                                    return _buildTicketCard(tickets[index]);
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
      ),
    );
  }

  Widget _buildTicketCard(Map<String, dynamic> ticket) {
    final isFinancialTicket = ticket['table'] == 'financial_orders';
    final financialType = ticket['type'] as String?;
    
    // Kiểm tra nếu có nhiều đối tác khác nhau trong ticket
    final hasMultiplePartners = ticket['table'] == 'return_orders' || ticket['table'] == 'reimport_orders';
    final uniquePartners = hasMultiplePartners 
        ? (ticket['items'] as List).map((item) => item['partner'] as String? ?? 'N/A').toSet()
        : <String>{};
    final displayPartner = hasMultiplePartners && uniquePartners.length > 1
        ? 'Nhiều đối tác (${uniquePartners.length})'
        : ticket['partner'];

    return Card(
      margin: const EdgeInsets.symmetric(vertical: 8),
      child: ListTile(
        title: Text(_getDisplayType(ticket['type'], ticket['table'])),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Đối Tác: $displayPartner'),
            if (isFinancialTicket && financialType == 'exchange')
              Text('Số Tiền: ${_formatNumber(ticket['items'][0]['from_amount'])} ${ticket['items'][0]['from_currency']}')
            else if (isFinancialTicket)
              Text('Số Tiền: ${_formatNumber(ticket['items'][0]['amount'])} ${ticket['items'][0]['currency'] ?? 'VND'}')
            else if (ticket['total_amount'] != null)
              Text('Số Tiền: ${_formatNumber(ticket['total_amount'])} ${ticket['currency'] ?? 'VND'}'),
            if (!isFinancialTicket) ...[
              Text('Số Lượng: ${ticket['table'] == 'transporter_orders' ? ticket['total_quantity'] : _formatNumber(ticket['total_quantity'])}'),
            ],
            Text('Ngày: ${_formatDate(ticket['date'])}'),
            if (!isFinancialTicket) ...[
              ...ticket['items'].map<Widget>((item) {
                final productName = item['product_name']?.toString() ?? 'N/A';
                final quantity = item['quantity'] as num? ?? 0;
                if (productName != 'N/A' && quantity > 0) {
                  return Text('Sản phẩm: $productName x${quantity.toInt()}');
                }
                return const SizedBox.shrink();
              }).toList(),
            ],
            if (ticket['warehouse_name'] != null && ticket['warehouse_name'] != 'N/A')
              Text('Kho: ${ticket['warehouse_name']}'),
          ],
        ),
        trailing: IconButton(
          icon: const Icon(Icons.visibility, color: Colors.blue),
          onPressed: () => _showTransactionDetails(ticket),
        ),
      ),
    );
  }
}