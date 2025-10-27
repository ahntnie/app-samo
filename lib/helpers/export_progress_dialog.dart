import 'package:flutter/material.dart';

/// Helper để hiển thị progress dialog khi export Excel
class ExportProgressDialog {
  static void show(BuildContext context, {String? message}) {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const CircularProgressIndicator(),
            const SizedBox(height: 16),
            Text(message ?? 'Đang xuất dữ liệu ra Excel...'),
            const SizedBox(height: 8),
            const Text(
              'Vui lòng chờ trong giây lát',
              style: TextStyle(fontSize: 12, color: Colors.grey),
            ),
          ],
        ),
      ),
    );
  }

  static void hide(BuildContext context) {
    if (Navigator.of(context).canPop()) {
      Navigator.of(context).pop();
    }
  }
}

