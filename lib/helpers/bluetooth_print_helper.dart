import 'dart:io';
import 'dart:async';
import 'package:bluetooth_print/bluetooth_print.dart';
import 'package:bluetooth_print/bluetooth_print_model.dart';
import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';

/// Helper class để quản lý in qua Bluetooth
class BluetoothPrintHelper {
  static BluetoothPrint? _bluetoothPrint;
  static bool _isScanning = false;
  static int _initializationAttempts = 0;
  static const int _maxInitializationAttempts = 3;
  
  /// Reset initialization state (cho phép thử lại)
  static void resetInitialization() {
    _bluetoothPrint = null;
    _initializationAttempts = 0;
    debugPrint('🔄 BluetoothPrint initialization reset');
  }
  
  /// Khởi tạo BluetoothPrint instance (async để tránh lỗi method channel)
  /// Thử tạo instance mới mỗi lần thay vì dùng singleton để tránh lỗi type cast
  static Future<BluetoothPrint> _getInstance() async {
    // Nếu đã có instance và chưa có lỗi, dùng lại
    if (_bluetoothPrint != null && _initializationAttempts < _maxInitializationAttempts) {
      return _bluetoothPrint!;
    }
    
    // Nếu đã thử quá nhiều lần, reset và thử lại
    if (_initializationAttempts >= _maxInitializationAttempts) {
      debugPrint('⚠️ Max initialization attempts reached, resetting...');
      resetInitialization();
    }
    
    try {
      _initializationAttempts++;
      debugPrint('🔄 Attempting to initialize BluetoothPrint (attempt $_initializationAttempts/$_maxInitializationAttempts)...');
      
      // Đợi một chút để đảm bảo Flutter engine đã sẵn sàng
      await Future.delayed(const Duration(milliseconds: 200));
      
      // Thử tạo instance mới - không cache để tránh lỗi type cast
      // Nếu lỗi, sẽ throw exception và được catch ở đây
      final instance = BluetoothPrint.instance;
      
      // Nếu thành công, cache lại
      _bluetoothPrint = instance;
      _initializationAttempts = 0; // Reset counter khi thành công
      
      debugPrint('✅ BluetoothPrint initialized successfully');
      return instance;
    } catch (e, stackTrace) {
      debugPrint('❌ Error initializing BluetoothPrint (attempt $_initializationAttempts): $e');
      debugPrint('❌ Stack trace: $stackTrace');
      
      // Nếu lỗi là type cast và chưa thử quá nhiều lần, thử lại
      if ((e.toString().contains('is not a subtype') || e.toString().contains('type cast')) 
          && _initializationAttempts < _maxInitializationAttempts) {
        debugPrint('⚠️ Type cast error detected, will retry...');
        await Future.delayed(const Duration(milliseconds: 500));
        // Recursive call để thử lại
        return await _getInstance();
      }
      
      // Nếu đã thử hết, throw exception
      throw Exception('Không thể khởi tạo BluetoothPrint sau $_initializationAttempts lần thử.\nLỗi: $e\n\nVui lòng:\n1. Khởi động lại app\n2. Hoặc sử dụng in PDF/thermal thay thế');
    }
  }

  /// Kiểm tra và yêu cầu quyền Bluetooth trước khi scan
  static Future<bool> _requestBluetoothPermissions() async {
    try {
      // Trên iOS, Bluetooth permission được xử lý tự động bởi system
      // Chỉ cần đảm bảo Info.plist có NSBluetoothAlwaysUsageDescription (đã có)
      if (Platform.isIOS) {
        debugPrint('🔵 [Bluetooth] iOS detected - Bluetooth permission handled by system');
        // Trên iOS, permission sẽ được request tự động khi app cố gắng sử dụng Bluetooth
        // Không cần request thủ công, chỉ cần return true
        return true;
      }

      // Android: Cần request permission thủ công
      debugPrint('🔵 [Bluetooth] Android detected - Checking permissions...');
      
      // Android 12+ (API 31+) cần BLUETOOTH_SCAN và BLUETOOTH_CONNECT
      // Android 6-11 cần LOCATION
      final bluetoothScanStatus = await Permission.bluetoothScan.status;
      final bluetoothConnectStatus = await Permission.bluetoothConnect.status;
      final locationStatus = await Permission.location.status;

      debugPrint('🔵 [Bluetooth] Permission status:');
      debugPrint('  - BLUETOOTH_SCAN: $bluetoothScanStatus');
      debugPrint('  - BLUETOOTH_CONNECT: $bluetoothConnectStatus');
      debugPrint('  - LOCATION: $locationStatus');

      // Request permissions nếu chưa có
      if (!bluetoothScanStatus.isGranted) {
        debugPrint('🔵 [Bluetooth] Requesting BLUETOOTH_SCAN permission...');
        final result = await Permission.bluetoothScan.request();
        if (!result.isGranted) {
          debugPrint('❌ [Bluetooth] BLUETOOTH_SCAN permission denied');
          return false;
        }
      }

      if (!bluetoothConnectStatus.isGranted) {
        debugPrint('🔵 [Bluetooth] Requesting BLUETOOTH_CONNECT permission...');
        final result = await Permission.bluetoothConnect.request();
        if (!result.isGranted) {
          debugPrint('❌ [Bluetooth] BLUETOOTH_CONNECT permission denied');
          return false;
        }
      }

      // Location permission cho Android 6-11
      if (!locationStatus.isGranted) {
        debugPrint('🔵 [Bluetooth] Requesting LOCATION permission...');
        final result = await Permission.location.request();
        if (!result.isGranted) {
          debugPrint('⚠️ [Bluetooth] LOCATION permission denied (may still work on Android 12+)');
        }
      }

      debugPrint('✅ [Bluetooth] All permissions granted');
      return true;
    } catch (e, stackTrace) {
      debugPrint('❌ [Bluetooth] Error requesting permissions: $e');
      debugPrint('❌ [Bluetooth] Stack trace: $stackTrace');
      // Trên iOS, nếu có lỗi permission, vẫn cho phép thử scan (system sẽ tự xử lý)
      if (Platform.isIOS) {
        debugPrint('⚠️ [Bluetooth] iOS permission error, but allowing scan attempt');
        return true;
      }
      return false;
    }
  }

  /// Quét và trả về danh sách thiết bị Bluetooth
  static Future<List<BluetoothDevice>> scanDevices() async {
    if (_isScanning) {
      debugPrint('⚠️ [Bluetooth] Already scanning, returning empty list');
      return [];
    }

    _isScanning = true;
    List<BluetoothDevice> devices = [];
    StreamSubscription? subscription;

    try {
      // Kiểm tra và yêu cầu quyền trước khi scan
      final hasPermission = await _requestBluetoothPermissions();
      if (!hasPermission) {
        debugPrint('❌ [Bluetooth] Missing permissions, cannot scan');
        return [];
      }

      final instance = await _getInstance();
      
      debugPrint('🔵 [Bluetooth] Setting up scan listener...');
      // Lắng nghe kết quả quét
      subscription = instance.scanResults.listen(
        (results) {
          debugPrint('🔵 [Bluetooth] Scan results received: ${results.length} devices');
          devices = results;
        },
        onError: (error) {
          debugPrint('❌ [Bluetooth] Scan listener error: $error');
        },
        cancelOnError: false,
      );

      debugPrint('🔵 [Bluetooth] Starting scan...');
      // Bắt đầu quét với timeout phù hợp
      // Trên iOS, có thể cần thời gian lâu hơn để tìm máy in
      final scanTimeout = Platform.isIOS ? const Duration(seconds: 15) : const Duration(seconds: 10);
      
      // Trên iOS, cần xử lý đặc biệt để tránh crash
      if (Platform.isIOS) {
        debugPrint('🔵 [Bluetooth] iOS detected - Using safe scan method');
        try {
          // Trên iOS, chỉ gọi startScan 1 lần với timeout đầy đủ
          // Wrap trong Future để có thể catch lỗi tốt hơn
          await Future.microtask(() async {
            await instance.startScan(timeout: scanTimeout);
          });
          debugPrint('✅ [Bluetooth] startScan called successfully (iOS)');
        } catch (scanError, scanStackTrace) {
          debugPrint('❌ [Bluetooth] Error in startScan (iOS): $scanError');
          debugPrint('❌ [Bluetooth] Stack trace: $scanStackTrace');
          // Không rethrow, chỉ log và return empty list để tránh crash
          // Trên iOS, nếu startScan crash, không thể tiếp tục
          return [];
        }
      } else {
        // Android: dùng cách bình thường
        try {
          await instance.startScan(timeout: scanTimeout);
          debugPrint('✅ [Bluetooth] startScan called successfully (Android)');
        } catch (scanError, scanStackTrace) {
          debugPrint('❌ [Bluetooth] Error in startScan (Android): $scanError');
          debugPrint('❌ [Bluetooth] Stack trace: $scanStackTrace');
          rethrow;
        }
      }

      debugPrint('🔵 [Bluetooth] Waiting for scan to complete...');
      // Đợi quét hoàn tất
      // Trên iOS, cần thời gian lâu hơn để tìm máy in Bluetooth Classic
      final waitDuration = Platform.isIOS ? const Duration(seconds: 15) : const Duration(seconds: 10);
      
      // Trên iOS, đợi từng phần nhỏ để có thể catch crash sớm
      if (Platform.isIOS) {
        const stepDuration = Duration(seconds: 2);
        int steps = waitDuration.inSeconds ~/ stepDuration.inSeconds;
        for (int i = 0; i < steps; i++) {
          await Future.delayed(stepDuration);
          debugPrint('🔵 [Bluetooth] Scan progress: ${i + 1}/$steps');
        }
      } else {
        await Future.delayed(waitDuration);
      }
      
      debugPrint('✅ [Bluetooth] Scan completed, found ${devices.length} devices');
    } catch (e, stackTrace) {
      debugPrint('❌ [Bluetooth] Error scanning Bluetooth devices: $e');
      debugPrint('❌ [Bluetooth] Stack trace: $stackTrace');
      // Không throw error, chỉ log và return empty list
    } finally {
      _isScanning = false;
      try {
        await subscription?.cancel();
        if (_bluetoothPrint != null) {
          await _bluetoothPrint!.stopScan();
        }
        debugPrint('🔵 [Bluetooth] Cleanup completed');
      } catch (e) {
        debugPrint('⚠️ [Bluetooth] Error during cleanup: $e');
      }
    }

    return devices;
  }

  /// Kết nối với thiết bị Bluetooth
  static Future<bool> connect(BluetoothDevice device) async {
    try {
      final instance = await _getInstance();
      final result = await instance.connect(device);
      return result ?? false;
    } catch (e) {
      debugPrint('Error connecting to Bluetooth device: $e');
      return false;
    }
  }

  /// Ngắt kết nối
  static Future<void> disconnect() async {
    try {
      if (_bluetoothPrint != null) {
        await _bluetoothPrint!.disconnect();
      }
    } catch (e) {
      debugPrint('Error disconnecting Bluetooth: $e');
    }
  }

  /// Kiểm tra trạng thái kết nối
  static Future<bool> isConnected() async {
    try {
      // Thử khởi tạo instance trước khi kiểm tra
      final instance = await _getInstance();
      final connected = await instance.isConnected;
      return connected ?? false;
    } catch (e, stackTrace) {
      debugPrint('❌ Error checking Bluetooth connection: $e');
      debugPrint('❌ Stack trace: $stackTrace');
      return false;
    }
  }


  /// In tem IMEI qua Bluetooth
  /// [productName]: Tên sản phẩm
  /// [imei]: Số IMEI
  /// [labelHeight]: Chiều cao tem (mm) - không dùng trong ESC/POS
  static Future<bool> printImeiLabel({
    required String productName,
    required String imei,
    required int labelHeight,
  }) async {
    try {
      final connected = await isConnected();
      if (!connected) {
        debugPrint('Bluetooth printer not connected');
        return false;
      }

      final instance = await _getInstance();
      
      // Tạo config cho printReceipt
      Map<String, dynamic> config = {};
      
      // Tạo danh sách LineText để in
      List<LineText> lines = [];
      
      // Tên sản phẩm (căn giữa, đậm, kích thước lớn)
      lines.add(LineText(
        type: LineText.TYPE_TEXT,
        content: productName,
        weight: 1, // Bold
        align: LineText.ALIGN_CENTER,
        size: 2, // Double size
        linefeed: 1,
      ));
      
      // Barcode CODE128 (căn giữa)
      lines.add(LineText(
        type: LineText.TYPE_BARCODE,
        content: imei,
        align: LineText.ALIGN_CENTER,
        linefeed: 1,
      ));
      
      // IMEI text (căn giữa, kích thước lớn)
      lines.add(LineText(
        type: LineText.TYPE_TEXT,
        content: imei,
        align: LineText.ALIGN_CENTER,
        size: 2, // Double size
        linefeed: 2,
      ));
      
      // Gửi dữ liệu đến máy in
      await instance.printReceipt(config, lines);

      return true;
    } catch (e, stackTrace) {
      debugPrint('❌ Error printing via Bluetooth: $e');
      debugPrint('❌ Stack trace: $stackTrace');
      return false;
    }
  }

  /// Hiển thị dialog chọn máy in Bluetooth
  static Future<BluetoothDevice?> showDevicePicker(BuildContext context) async {
    // Hiển thị loading
    if (!context.mounted) return null;
    
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => const AlertDialog(
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            CircularProgressIndicator(),
            SizedBox(height: 16),
            Text('Đang quét thiết bị Bluetooth...'),
          ],
        ),
      ),
    );

    try {
      // Quét thiết bị với error handling tốt hơn
      List<BluetoothDevice> devices = [];
      try {
        devices = await scanDevices();
      } catch (e, stackTrace) {
        debugPrint('❌ [Bluetooth] Error in scanDevices: $e');
        debugPrint('❌ [Bluetooth] Stack trace: $stackTrace');
        // Không throw, chỉ log và tiếp tục với empty list
      }
      
      if (!context.mounted) return null;
      Navigator.pop(context); // Đóng loading dialog

      if (devices.isEmpty) {
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                Platform.isIOS 
                  ? 'Không tìm thấy thiết bị Bluetooth nào.\n\nVui lòng:\n1. Đảm bảo máy in đã bật Bluetooth và ở chế độ pairing\n2. Kiểm tra Settings > Bluetooth trên iPhone\n3. Thử lại sau vài giây'
                  : 'Không tìm thấy thiết bị Bluetooth nào.\n\nVui lòng đảm bảo máy in đã bật Bluetooth và ở chế độ pairing.',
              ),
              duration: const Duration(seconds: 5),
            ),
          );
        }
        return null;
      }

      // Hiển thị dialog chọn thiết bị
      return await showDialog<BluetoothDevice>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Chọn máy in Bluetooth'),
          content: SizedBox(
            width: double.maxFinite,
            child: ListView.builder(
              shrinkWrap: true,
              itemCount: devices.length,
              itemBuilder: (context, index) {
                final device = devices[index];
                return ListTile(
                  leading: const Icon(Icons.print),
                  title: Text(device.name ?? 'Unknown Device'),
                  subtitle: Text(device.address ?? ''),
                  onTap: () => Navigator.pop(context, device),
                );
              },
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Hủy'),
            ),
          ],
        ),
      );
    } catch (e) {
      if (context.mounted) {
        Navigator.pop(context); // Đóng loading dialog
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Lỗi khi quét Bluetooth: $e')),
        );
      }
      return null;
    }
  }
}

