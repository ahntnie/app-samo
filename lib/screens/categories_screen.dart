import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

class CategoriesScreen extends StatefulWidget {
  final List<String> permissions;
  final SupabaseClient tenantClient;

  const CategoriesScreen({
    super.key,
    required this.permissions,
    required this.tenantClient,
  });

  @override
  _CategoriesScreenState createState() => _CategoriesScreenState();
}

class _CategoriesScreenState extends State<CategoriesScreen> {
  String selectedType = 'Danh mục sản phẩm';
  bool isLoading = true;
  String? errorMessage;
  List<Map<String, dynamic>> items = [];
  final TextEditingController nameController = TextEditingController();
  String selectedCurrency = 'VND';
  String selectedWarehouseType = 'nội địa';
  final currencies = ['VND', 'CNY', 'USD'];
  final warehouseTypes = ['nội địa', 'quốc tế'];
  
  // Biến cho việc thêm sản phẩm
  List<Map<String, dynamic>> categories = [];
  int? selectedCategoryId;

  // Cache để lưu id -> name
  static Map<String, String> productNameCache = {};
  static Map<String, String> warehouseNameCache = {};

  @override
  void initState() {
    super.initState();
    _fetchItems();
    _fetchCategories();
  }

  @override
  void dispose() {
    nameController.dispose();
    super.dispose();
  }

  Future<void> _fetchCategories() async {
    try {
      final supabase = widget.tenantClient;
      final response = await supabase.from('categories').select('id, name');
      setState(() {
        categories = response;
      });
    } catch (e) {
      print('Error fetching categories: $e');
    }
  }

  Future<void> _fetchItems() async {
    setState(() {
      isLoading = true;
      errorMessage = null;
    });

    try {
      final supabase = widget.tenantClient;
      switch (selectedType) {
        case 'Danh mục sản phẩm':
          final response = await supabase.from('categories').select('id, name').order('name', ascending: true);
          setState(() {
            items = response;
            isLoading = false;
          });
          break;
        case 'Sản phẩm':
          final response = await supabase.from('products_name').select('id, products').order('products', ascending: true);
          productNameCache.addAll({
            for (var item in response) item['id'].toString(): item['products']
          });
          setState(() {
            items = response;
            isLoading = false;
          });
          break;
        case 'Tài khoản thanh toán':
          final response = await supabase.from('financial_accounts').select('id, name, balance, currency').order('name', ascending: true);
          setState(() {
            items = response;
            isLoading = false;
          });
          break;
        case 'Chi nhánh':
          final response = await supabase.from('warehouses').select('id, name, type').order('name', ascending: true);
          warehouseNameCache.addAll({
            for (var item in response) item['id'].toString(): item['name']
          });
          setState(() {
            items = response;
            isLoading = false;
          });
          break;
      }
      print('Fetched $selectedType items: ${items.length}'); // Debug
    } catch (e) {
      print('Error fetching items: $e'); // Debug
      setState(() {
        errorMessage = 'Lỗi khi tải: $e';
        isLoading = false;
      });
    }
  }

  Future<void> _addItem(String name) async {
    try {
      final supabase = widget.tenantClient;
      switch (selectedType) {
        case 'Danh mục sản phẩm':
          await supabase.from('categories').insert({ 'name': name });
          print('Added category: $name');
          break;
        case 'Sản phẩm':
          if (selectedCategoryId == null) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('Vui lòng chọn loại sản phẩm!')),
            );
            return;
          }
          final response = await supabase.from('products_name').insert({ 
            'products': name,
            'category_id': selectedCategoryId,
          }).select('id, products').single();
          productNameCache[response['id'].toString()] = name;
          print('Added product: $name, id: ${response['id']}, category_id: $selectedCategoryId');
          break;
        case 'Tài khoản thanh toán':
          await supabase.from('financial_accounts').insert({
            'name': name,
            'balance': 0,
            'currency': selectedCurrency,
          });
          print('Added financial account: $name, currency: $selectedCurrency');
          break;
        case 'Chi nhánh':
          final response = await supabase.from('warehouses').insert({
            'name': name,
            'type': selectedWarehouseType,
          }).select('id, name').single();
          warehouseNameCache[response['id'].toString()] = name;
          print('Added warehouse: $name, type: $selectedWarehouseType, id: ${response['id']}');
          break;
      }
      await _fetchItems();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Đã thêm $selectedType')),
      );
    } catch (e) {
      print('Error adding item: $e');
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Lỗi: $e')),
      );
    }
  }

  Future<void> _editItem(dynamic id, String oldValue, String newValue) async {
    try {
      final supabase = widget.tenantClient;
      switch (selectedType) {
        case 'Danh mục sản phẩm':
          await supabase.from('categories').update({ 'name': newValue }).eq('id', id);
          print('Edited category: $id, new name: $newValue');
          break;
        case 'Sản phẩm':
          await supabase.from('products_name').update({ 'products': newValue }).eq('id', id);
          productNameCache[id.toString()] = newValue;
          print('Edited product: $id, new name: $newValue');
          break;
        case 'Tài khoản thanh toán':
          await supabase.from('financial_accounts').update({ 'name': newValue }).eq('id', id);
          print('Edited financial account: $id, new name: $newValue');
          break;
        case 'Chi nhánh':
          await supabase.from('warehouses').update({ 'name': newValue }).eq('id', id);
          warehouseNameCache[id.toString()] = newValue;
          print('Edited warehouse: $id, new name: $newValue');
          break;
      }
      await _fetchItems();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Đã sửa $selectedType')),
      );
    } catch (e) {
      print('Error editing item: $e');
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Lỗi: $e')),
      );
    }
  }

  Future<void> _deleteItem(String id) async {
    try {
      final supabase = widget.tenantClient;
      switch (selectedType) {
        case 'Danh mục sản phẩm':
          await supabase.from('categories').delete().eq('id', id);
          print('Deleted category: $id');
          break;
        case 'Sản phẩm':
          await supabase.from('products_name').delete().eq('id', id);
          productNameCache.remove(id);
          print('Deleted product: $id');
          break;
        case 'Tài khoản thanh toán':
          await supabase.from('financial_accounts').delete().eq('id', id);
          print('Deleted financial account: $id');
          break;
        case 'Chi nhánh':
          await supabase.from('warehouses').delete().eq('id', id);
          warehouseNameCache.remove(id);
          print('Deleted warehouse: $id');
          break;
      }
      await _fetchItems();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Đã xóa $selectedType')),
      );
    } catch (e) {
      print('Error deleting item: $e');
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Lỗi: $e')),
      );
    }
  }

  void _showAddDialog() {
    nameController.clear();
    setState(() {
      selectedCurrency = 'VND';
      selectedWarehouseType = 'nội địa';
      selectedCategoryId = null;
    });
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Thêm $selectedType'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: nameController,
              decoration: const InputDecoration(
                labelText: 'Tên',
                border: OutlineInputBorder(),
              ),
            ),
            if (selectedType == 'Sản phẩm') ...[
              const SizedBox(height: 8),
              DropdownButtonFormField<int>(
                value: selectedCategoryId,
                items: categories.map((e) => DropdownMenuItem<int>(
                  value: e['id'] as int,
                  child: Text(e['name'] as String),
                )).toList(),
                onChanged: (val) => setState(() => selectedCategoryId = val),
                decoration: const InputDecoration(
                  labelText: 'Loại sản phẩm',
                  border: OutlineInputBorder(),
                ),
              ),
            ],
            if (selectedType == 'Tài khoản thanh toán') ...[
              const SizedBox(height: 8),
              DropdownButtonFormField<String>(
                value: selectedCurrency,
                items: currencies.map((e) => DropdownMenuItem(value: e, child: Text(e))).toList(),
                onChanged: (val) => setState(() => selectedCurrency = val!),
                decoration: const InputDecoration(
                  labelText: 'Loại tiền',
                  border: OutlineInputBorder(),
                ),
              ),
            ],
            if (selectedType == 'Chi nhánh') ...[
              const SizedBox(height: 8),
              DropdownButtonFormField<String>(
                value: selectedWarehouseType,
                items: warehouseTypes
                    .map((e) => DropdownMenuItem(value: e, child: Text(e)))
                    .toList(),
                onChanged: (val) => setState(() => selectedWarehouseType = val!),
                decoration: const InputDecoration(
                  labelText: 'Loại chi nhánh',
                  border: OutlineInputBorder(),
                ),
              ),
            ],
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Hủy'),
          ),
          ElevatedButton(
            onPressed: () {
              if (nameController.text.trim().isNotEmpty) {
                _addItem(nameController.text.trim());
                Navigator.pop(context);
              }
            },
            child: const Text('Thêm'),
          ),
        ],
      ),
    );
  }

  void _showEditDialog(String id, String currentValue) {
    nameController.text = currentValue;
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Sửa $selectedType'),
        content: TextField(
          controller: nameController,
          decoration: const InputDecoration(
            labelText: 'Tên',
            border: OutlineInputBorder(),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Hủy'),
          ),
          ElevatedButton(
            onPressed: () {
              if (nameController.text.trim().isNotEmpty) {
                _editItem(id, currentValue, nameController.text.trim());
                Navigator.pop(context);
              }
            },
            child: const Text('Lưu'),
          ),
        ],
      ),
    );
  }

  void _showDeleteDialog(String id, String value) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Xóa $selectedType'),
        content: Text('Bạn có chắc muốn xóa "$value"?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Hủy'),
          ),
          ElevatedButton(
            onPressed: () {
              _deleteItem(id);
              Navigator.pop(context);
            },
            style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
            child: const Text('Xóa'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF6F9FF),
      appBar: AppBar(
        title: const Text(
          'Danh mục',
          style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
        ),
        backgroundColor: Colors.black,
        iconTheme: const IconThemeData(color: Colors.white),
        elevation: 4,
      ),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            DropdownButtonFormField<String>(
              value: selectedType,
              items: ['Danh mục sản phẩm', 'Sản phẩm', 'Tài khoản thanh toán', 'Chi nhánh']
                  .map((e) => DropdownMenuItem(value: e, child: Text(e)))
                  .toList(),
              onChanged: (val) {
                setState(() {
                  selectedType = val!;
                  _fetchItems();
                });
              },
              decoration: InputDecoration(
                labelText: 'Loại',
                filled: true,
                fillColor: Colors.grey.shade200,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                  borderSide: BorderSide.none,
                ),
              ),
            ),
            const SizedBox(height: 16),
            Expanded(
              child: isLoading
                  ? const Center(child: CircularProgressIndicator())
                  : errorMessage != null
                      ? Center(child: Text(errorMessage!, style: const TextStyle(color: Colors.red)))
                      : items.isEmpty
                          ? Center(child: Text('Không có ${selectedType.toLowerCase()}'))
                          : ListView.builder(
                              itemCount: items.length,
                              itemBuilder: (context, index) {
                                final item = items[index];
                                String displayValue;
                                switch (selectedType) {
                                  case 'Danh mục sản phẩm':
                                    displayValue = item['name'] ?? 'Không xác định';
                                    break;
                                  case 'Sản phẩm':
                                    displayValue = item['products'] ?? 'Không xác định';
                                    break;
                                  case 'Tài khoản thanh toán':
                                    displayValue = '${item['name']} (${item['currency']})';
                                    break;
                                  case 'Chi nhánh':
                                    displayValue = '${item['name']} (${item['type']})';
                                    break;
                                  default:
                                    displayValue = 'Không xác định';
                                }
                                return Card(
                                  margin: const EdgeInsets.symmetric(vertical: 4),
                                  child: ListTile(
                                    title: Text(displayValue),
                                    trailing: Row(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        IconButton(
                                          icon: const Icon(Icons.edit, color: Colors.blue),
                                          onPressed: () => _showEditDialog(
                                            item['id'].toString(),
                                            item['name'] ?? item['products'],
                                          ),
                                        ),
                                        IconButton(
                                          icon: const Icon(Icons.delete, color: Colors.red),
                                          onPressed: () => _showDeleteDialog(item['id'].toString(), displayValue),
                                        ),
                                      ],
                                    ),
                                  ),
                                );
                              },
                            ),
            ),
            const SizedBox(height: 16),
            ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.blue,
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 24),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              ),
              onPressed: _showAddDialog,
              child: Text('Thêm $selectedType'),
            ),
          ],
        ),
      ),
    );
  }
}