import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

class WarehouseForm extends StatefulWidget {
  final SupabaseClient tenantClient;

  const WarehouseForm({super.key, required this.tenantClient});

  @override
  State<WarehouseForm> createState() => _WarehouseFormState();
}

class _WarehouseFormState extends State<WarehouseForm> {
  List<Map<String, dynamic>> warehouses = [];
  final TextEditingController nameController = TextEditingController();
  String type = 'nội địa'; // Mặc định là nội địa

  @override
  void initState() {
    super.initState();
    _fetchWarehouses();
  }

  Future<void> _fetchWarehouses() async {
    try {
      final res = await widget.tenantClient.from('warehouses').select('id, name, type');
      print('Supabase response: $res'); // Debug: In dữ liệu trả về
      setState(() {
        warehouses = res.map((e) {
          final map = Map<String, dynamic>.from(e);
          // Kiểm tra id (UUID dạng chuỗi)
          if (map['id'] == null || map['id'] is! String) {
            print('Cột id không hợp lệ trong bản ghi: $map');
            map['id'] = ''; // Giá trị mặc định nếu id không hợp lệ
          }
          // Kiểm tra name
          if (map['name'] == null) {
            print('Thiếu cột name trong bản ghi: $map');
            map['name'] = 'Unknown';
          }
          // Kiểm tra type
          if (map['type'] == null) {
            print('Thiếu cột type trong bản ghi: $map');
            map['type'] = 'nội địa'; // Mặc định nếu type null
          }
          return map;
        }).toList();
      });
    } catch (e) {
      print('Lỗi tải danh sách kho: $e'); // Debug: In lỗi
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Lỗi khi tải danh sách kho: $e')),
      );
    }
  }

  Future<void> _addWarehouse() async {
    if (nameController.text.isEmpty) return;
    try {
      await widget.tenantClient.from('warehouses').insert({
        'name': nameController.text,
        'type': type, // Sử dụng type từ DropdownButton
      });
      nameController.clear();
      await _fetchWarehouses();
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Thêm kho thành công')),
      );
    } catch (e) {
      print('Lỗi thêm kho: $e'); // Debug: In lỗi
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Lỗi khi thêm kho: $e')),
      );
    }
  }

  Future<void> _editWarehouse(String id, String oldName) async {
    final editController = TextEditingController(text: oldName);
    final result = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Sửa tên kho'),
        content: TextField(
          controller: editController,
          decoration: const InputDecoration(labelText: 'Tên kho mới'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Hủy'),
          ),
          TextButton(
            onPressed: () {
              if (editController.text.isNotEmpty) {
                Navigator.pop(context, editController.text);
              }
            },
            child: const Text('Lưu'),
          ),
        ],
      ),
    );

    if (result != null && result != oldName) {
      try {
        // Cập nhật tên kho
        await widget.tenantClient
            .from('warehouses')
            .update({'name': result})
            .eq('id', id);

        // Cập nhật cột status trong bảng products
        await widget.tenantClient
            .from('products')
            .update({'status': result})
            .eq('status', oldName);

        await _fetchWarehouses();
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Sửa tên kho thành công')),
        );
      } catch (e) {
        print('Lỗi sửa kho: $e'); // Debug: In lỗi
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Lỗi khi sửa kho: $e')),
        );
      }
    }
  }

  Future<void> _deleteWarehouse(String id) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Xác nhận xóa'),
        content: const Text('Bạn có chắc muốn xóa kho này?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Hủy'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Xóa'),
          ),
        ],
      ),
    );

    if (confirm == true) {
      try {
        await widget.tenantClient.from('warehouses').delete().eq('id', id);
        await _fetchWarehouses();
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Xóa kho thành công')),
        );
      } catch (e) {
        print('Lỗi xóa kho: $e'); // Debug: In lỗi
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Lỗi khi xóa kho: $e')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Quản lý kho', style: TextStyle(color: Colors.white)),
        backgroundColor: Colors.black,
        iconTheme: const IconThemeData(color: Colors.white),
      ),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: nameController,
                    decoration: const InputDecoration(labelText: 'Tên kho'),
                  ),
                ),
                const SizedBox(width: 12),
                DropdownButton<String>(
                  value: type,
                  items: const [
                    DropdownMenuItem(value: 'nội địa', child: Text('Nội địa')),
                    DropdownMenuItem(value: 'quốc tế', child: Text('Quốc tế')),
                  ],
                  onChanged: (value) => setState(() => type = value!),
                ),
                const SizedBox(width: 8),
                ElevatedButton(
                  onPressed: _addWarehouse,
                  child: const Text('Thêm'),
                ),
              ],
            ),
            const SizedBox(height: 20),
            Expanded(
              child: ListView.builder(
                itemCount: warehouses.length,
                itemBuilder: (context, index) {
                  final warehouse = warehouses[index];
                  return ListTile(
                    title: Text('${warehouse['name']} (${warehouse['type']})'),
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        IconButton(
                          icon: const Icon(Icons.edit),
                          onPressed: () => _editWarehouse(
                            warehouse['id'] as String,
                            warehouse['name'],
                          ),
                        ),
                        IconButton(
                          icon: const Icon(Icons.delete),
                          onPressed: () => _deleteWarehouse(warehouse['id'] as String),
                        ),
                      ],
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
}