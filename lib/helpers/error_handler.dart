import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'dart:io';
import 'dart:async';

/// ErrorHandler - Smart error parsing and user-friendly error messages
/// 
/// Usage:
/// ```dart
/// try {
///   await someOperation();
/// } catch (e) {
///   await ErrorHandler.showErrorDialog(
///     context: context,
///     title: 'Lỗi tạo phiếu',
///     error: e,
///     showRetry: false,
///   );
/// }
/// ```
class ErrorHandler {
  /// Show error dialog với user-friendly message
  /// 
  /// Returns: true if user clicked retry, false otherwise
  static Future<bool> showErrorDialog({
    required BuildContext context,
    required String title,
    required dynamic error,
    bool showRetry = false,
  }) async {
    final userMessage = _parseError(error);
    
    if (!context.mounted) return false;
    
    final result = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        title: Row(
          children: [
            const Icon(Icons.error_outline, color: Colors.red, size: 28),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                title,
                style: const TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                  color: Colors.red,
                ),
              ),
            ),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              userMessage,
              style: const TextStyle(fontSize: 15),
            ),
            const SizedBox(height: 16),
            const Divider(),
            const SizedBox(height: 8),
            Row(
              children: const [
                Icon(Icons.info_outline, size: 16, color: Colors.grey),
                SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Nếu vấn đề vẫn tiếp diễn, vui lòng chụp màn hình và liên hệ hỗ trợ.',
                    style: TextStyle(fontSize: 12, color: Colors.grey),
                  ),
                ),
              ],
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Đóng'),
          ),
          if (showRetry)
            ElevatedButton(
              onPressed: () => Navigator.pop(context, true),
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.blue,
                foregroundColor: Colors.white,
              ),
              child: const Text('Thử lại'),
            ),
        ],
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
        ),
      ),
    );
    
    return result ?? false;
  }

  /// Parse error và convert thành user-friendly message
  static String _parseError(dynamic error) {
    // Convert error to string for analysis
    final errorString = error.toString().toLowerCase();
    
    // PostgrestException - Database errors
    if (error is PostgrestException) {
      return _parsePostgrestException(error);
    }
    
    // Network errors
    if (error is SocketException) {
      return '❌ Không có kết nối mạng\n\n'
          'Vui lòng kiểm tra:\n'
          '• WiFi hoặc 4G/5G đã bật chưa?\n'
          '• Kết nối mạng có ổn định không?\n'
          '• Thử tắt và bật lại WiFi/4G';
    }
    
    if (error is TimeoutException || errorString.contains('timeout')) {
      return '⏱️ Kết nối quá chậm\n\n'
          'Mạng hiện tại đang chậm hoặc không ổn định.\n\n'
          'Vui lòng:\n'
          '• Thử lại sau vài giây\n'
          '• Kiểm tra tín hiệu mạng\n'
          '• Di chuyển đến nơi có sóng tốt hơn';
    }
    
    if (error is HttpException || errorString.contains('http')) {
      return '🌐 Lỗi kết nối máy chủ\n\n'
          'Không thể kết nối đến máy chủ.\n\n'
          'Vui lòng:\n'
          '• Kiểm tra kết nối mạng\n'
          '• Thử lại sau vài phút\n'
          '• Liên hệ hỗ trợ nếu vấn đề vẫn tiếp diễn';
    }
    
    // File/Storage errors
    if (error is FileSystemException || errorString.contains('file')) {
      return '💾 Lỗi lưu file\n\n'
          'Không thể lưu file vào thiết bị.\n\n'
          'Vui lòng kiểm tra:\n'
          '• Dung lượng bộ nhớ còn đủ không?\n'
          '• Quyền truy cập bộ nhớ đã được cấp chưa?\n'
          '• Thử xóa bớt file cũ để giải phóng dung lượng';
    }
    
    if (errorString.contains('permission') && errorString.contains('denied')) {
      return '🔒 Thiếu quyền truy cập\n\n'
          'Ứng dụng cần quyền truy cập bộ nhớ.\n\n'
          'Vui lòng:\n'
          '• Vào Cài đặt → Ứng dụng → [Tên app]\n'
          '• Cấp quyền "Lưu trữ" hoặc "Files and Media"\n'
          '• Thử lại sau khi cấp quyền';
    }
    
    // Format errors
    if (errorString.contains('format') || errorString.contains('parse')) {
      return '⚠️ Dữ liệu không hợp lệ\n\n'
          'Dữ liệu nhập vào không đúng định dạng.\n\n'
          'Vui lòng kiểm tra lại:\n'
          '• Số tiền, số lượng có đúng không?\n'
          '• Định dạng ngày tháng có chính xác không?\n'
          '• Các trường bắt buộc đã nhập đầy đủ chưa?';
    }
    
    // Type errors
    if (errorString.contains('type') && errorString.contains('subtype')) {
      return '⚠️ Lỗi dữ liệu\n\n'
          'Dữ liệu không đúng định dạng hệ thống yêu cầu.\n\n'
          'Vui lòng:\n'
          '• Kiểm tra lại thông tin đã nhập\n'
          '• Thử làm mới trang và nhập lại\n'
          '• Liên hệ hỗ trợ nếu vấn đề vẫn tiếp diễn';
    }
    
    // Default fallback
    return '❌ Đã xảy ra lỗi\n\n'
        'Hệ thống gặp sự cố không xác định.\n\n'
        'Vui lòng:\n'
        '• Thử lại sau vài giây\n'
        '• Kiểm tra kết nối mạng\n'
        '• Chụp màn hình lỗi này và liên hệ hỗ trợ\n\n'
        'Chi tiết kỹ thuật: ${error.toString().substring(0, error.toString().length > 100 ? 100 : error.toString().length)}...';
  }

  /// Parse PostgrestException thành user-friendly message
  static String _parsePostgrestException(PostgrestException error) {
    final code = error.code ?? '';
    final message = error.message.toLowerCase();
    
    // Foreign key violation
    if (code == '23503' || message.contains('foreign key') || message.contains('violates foreign key')) {
      return '🔗 Dữ liệu liên quan không tồn tại\n\n'
          'Không thể thực hiện thao tác vì thiếu dữ liệu liên quan.\n\n'
          'Vui lòng kiểm tra:\n'
          '• Khách hàng/Nhà cung cấp đã được tạo chưa?\n'
          '• Sản phẩm có tồn tại trong hệ thống không?\n'
          '• Kho hàng đã được thiết lập chưa?\n'
          '• Tài khoản tài chính đã được tạo chưa?';
    }
    
    // Unique constraint violation
    if (code == '23505' || message.contains('unique') || message.contains('duplicate')) {
      return '⚠️ Dữ liệu đã tồn tại\n\n'
          'Không thể tạo vì dữ liệu này đã có trong hệ thống.\n\n'
          'Vui lòng kiểm tra:\n'
          '• Tên khách hàng/sản phẩm đã trùng chưa?\n'
          '• IMEI đã được nhập vào hệ thống chưa?\n'
          '• Số phiếu/mã giao dịch đã tồn tại chưa?\n\n'
          'Thử dùng tên/mã khác hoặc tìm kiếm dữ liệu cũ.';
    }
    
    // Not null violation
    if (code == '23502' || message.contains('null value') || message.contains('not-null')) {
      return '📝 Thiếu thông tin bắt buộc\n\n'
          'Một số trường thông tin bắt buộc chưa được nhập.\n\n'
          'Vui lòng kiểm tra và nhập đầy đủ:\n'
          '• Tên khách hàng/sản phẩm\n'
          '• Số tiền/số lượng\n'
          '• Ngày tháng\n'
          '• Các trường có dấu (*) bắt buộc';
    }
    
    // Check constraint violation
    if (code == '23514' || message.contains('check constraint')) {
      return '⚠️ Dữ liệu không hợp lệ\n\n'
          'Dữ liệu nhập vào không thỏa mãn điều kiện của hệ thống.\n\n'
          'Vui lòng kiểm tra:\n'
          '• Số tiền phải lớn hơn 0\n'
          '• Số lượng phải là số dương\n'
          '• Ngày tháng phải hợp lệ\n'
          '• Giá trị nằm trong khoảng cho phép';
    }
    
    // Permission errors
    if (code == '401' || message.contains('unauthorized')) {
      return '🔒 Không có quyền truy cập\n\n'
          'Bạn không có quyền thực hiện thao tác này.\n\n'
          'Vui lòng:\n'
          '• Đăng nhập lại\n'
          '• Kiểm tra quyền hạn của tài khoản\n'
          '• Liên hệ quản trị viên để cấp quyền';
    }
    
    if (code == '403' || message.contains('forbidden')) {
      return '🚫 Quyền truy cập bị từ chối\n\n'
          'Tài khoản của bạn không được phép thực hiện thao tác này.\n\n'
          'Vui lòng liên hệ quản trị viên để:\n'
          '• Kiểm tra quyền hạn tài khoản\n'
          '• Yêu cầu cấp quyền phù hợp\n'
          '• Xác nhận vai trò của bạn trong hệ thống';
    }
    
    // Row level security
    if (message.contains('row') && message.contains('security')) {
      return '🔐 Lỗi bảo mật dữ liệu\n\n'
          'Bạn không có quyền truy cập dữ liệu này.\n\n'
          'Vui lòng:\n'
          '• Kiểm tra bạn đang đăng nhập đúng tài khoản chưa\n'
          '• Liên hệ quản trị viên nếu cần truy cập\n'
          '• Đảm bảo bạn có quyền với dữ liệu này';
    }
    
    // Default Supabase error
    return '🔧 Lỗi cơ sở dữ liệu\n\n'
        'Hệ thống gặp sự cố khi xử lý dữ liệu.\n\n'
        'Vui lòng:\n'
        '• Kiểm tra lại thông tin đã nhập\n'
        '• Thử lại sau vài giây\n'
        '• Liên hệ hỗ trợ nếu vấn đề vẫn tiếp diễn\n\n'
        'Mã lỗi: ${error.code ?? "unknown"}';
  }
}
