import 'dart:io';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';

/// Helper class để xử lý quyền lưu trữ và lấy thư mục Downloads trên Android 13+
class StorageHelper {
  /// Kiểm tra và yêu cầu quyền lưu trữ (nếu cần) và trả về thư mục Downloads
  /// 
  /// Trên Android 13+ (API 33+): Không cần permission, sử dụng scoped storage
  /// Trên Android < 13: Cần permission.storage
  static Future<Directory?> getDownloadDirectory() async {
    if (!Platform.isAndroid) {
      // iOS/Desktop: Sử dụng application documents directory
      return await getApplicationDocumentsDirectory();
    }

    try {
      final deviceInfo = DeviceInfoPlugin();
      final androidInfo = await deviceInfo.androidInfo;
      final sdkInt = androidInfo.version.sdkInt;

      // Android 13+ (API 33+): Không cần permission, nhưng cần sử dụng cách khác để truy cập Downloads
      if (sdkInt >= 33) {
        // Trên Android 13+, WRITE_EXTERNAL_STORAGE không còn hoạt động
        // Sử dụng getExternalStorageDirectory() và tạo thư mục Downloads
        // Hoặc sử dụng MediaStore (phức tạp hơn)
        // Thử cách đơn giản: sử dụng external storage directory của app
        try {
          final externalDir = await getExternalStorageDirectory();
          if (externalDir != null) {
            // externalDir thường là /storage/emulated/0/Android/data/com.example.app/files
            // Cần lấy parent để đến /storage/emulated/0/Download
            final parentPath = externalDir.parent.path;
            // Loại bỏ '/Android/data/com.example.app/files' để đến /storage/emulated/0
            if (parentPath.contains('/Android/data/')) {
              final rootPath = parentPath.substring(0, parentPath.indexOf('/Android/data/'));
              final downloadsPath = '$rootPath/Download';
              final downloadsDir = Directory(downloadsPath);
              try {
                if (!await downloadsDir.exists()) {
                  await downloadsDir.create(recursive: true);
                }
                // Thử ghi test file để kiểm tra quyền
                final testFile = File('${downloadsDir.path}/.test');
                await testFile.writeAsString('test');
                await testFile.delete();
                return downloadsDir;
              } catch (e) {
                print('⚠️ Cannot write to Downloads via direct path: $e');
              }
            }
          }
        } catch (e) {
          print('⚠️ Error getting external storage directory: $e');
        }
        
        // Fallback: Thử đường dẫn truyền thống (có thể hoạt động nếu app có quyền legacy)
        try {
          final downloadsDir = Directory('/storage/emulated/0/Download');
          // Thử tạo file test để kiểm tra quyền ghi
          final testFile = File('${downloadsDir.path}/.test');
          await testFile.writeAsString('test');
          await testFile.delete();
          if (!await downloadsDir.exists()) {
            await downloadsDir.create(recursive: true);
          }
          return downloadsDir;
        } catch (e) {
          print('⚠️ Cannot access /storage/emulated/0/Download: $e');
          // Trên Android 13+, nếu không truy cập được Downloads, sử dụng app-specific directory
          try {
            final appDir = await getApplicationDocumentsDirectory();
            final downloadsPath = '${appDir.path}/Downloads';
            final downloadsDir = Directory(downloadsPath);
            if (!await downloadsDir.exists()) {
              await downloadsDir.create(recursive: true);
            }
            print('📁 Using app-specific Downloads directory: ${downloadsDir.path}');
            return downloadsDir;
          } catch (e2) {
            print('❌ Fallback to app directory also failed: $e2');
          }
        }
      } else if (sdkInt >= 30) {
        // Android 11-12 (API 30-32): Cần manageExternalStorage permission
        var status = await Permission.manageExternalStorage.status;
        if (!status.isGranted) {
          status = await Permission.manageExternalStorage.request();
          if (!status.isGranted) {
            print('❌ manageExternalStorage permission denied');
            return null;
          }
        }

        // Sử dụng đường dẫn truyền thống
        final downloadsDir = Directory('/storage/emulated/0/Download');
        if (!await downloadsDir.exists()) {
          await downloadsDir.create(recursive: true);
        }
        return downloadsDir;
      } else {
        // Android < 11 (API < 30): Cần storage permission
        var status = await Permission.storage.status;
        if (!status.isGranted) {
          status = await Permission.storage.request();
          if (!status.isGranted) {
            print('❌ storage permission denied');
            return null;
          }
        }

        // Sử dụng đường dẫn truyền thống
        final downloadsDir = Directory('/storage/emulated/0/Download');
        if (!await downloadsDir.exists()) {
          await downloadsDir.create(recursive: true);
        }
        return downloadsDir;
      }
    } catch (e) {
      print('❌ Error getting download directory: $e');
      // Fallback: Sử dụng external storage
      try {
        final externalDir = await getExternalStorageDirectory();
        if (externalDir != null) {
          final downloadsPath = '${externalDir.parent.path}/Download';
          final downloadsDir = Directory(downloadsPath);
          if (!await downloadsDir.exists()) {
            await downloadsDir.create(recursive: true);
          }
          return downloadsDir;
        }
      } catch (e2) {
        print('❌ Fallback also failed: $e2');
      }
    }

    return null;
  }

  /// Kiểm tra và yêu cầu quyền lưu trữ (nếu cần) trên Android
  /// Trả về true nếu có quyền hoặc không cần quyền
  static Future<bool> requestStoragePermissionIfNeeded() async {
    if (!Platform.isAndroid) {
      return true; // iOS/Desktop không cần permission
    }

    try {
      final deviceInfo = DeviceInfoPlugin();
      final androidInfo = await deviceInfo.androidInfo;
      final sdkInt = androidInfo.version.sdkInt;

      // Android 13+ (API 33+): Không cần permission
      if (sdkInt >= 33) {
        return true;
      } else if (sdkInt >= 30) {
        // Android 11-12: Cần manageExternalStorage
        var status = await Permission.manageExternalStorage.status;
        if (!status.isGranted) {
          status = await Permission.manageExternalStorage.request();
        }
        return status.isGranted;
      } else {
        // Android < 11: Cần storage permission
        var status = await Permission.storage.status;
        if (!status.isGranted) {
          status = await Permission.storage.request();
        }
        return status.isGranted;
      }
    } catch (e) {
      print('❌ Error checking storage permission: $e');
      // Trên Android 13+, không có permission cũng OK
      return true;
    }
  }
}

