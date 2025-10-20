import 'package:flutter/material.dart';
import 'package:camera/camera.dart';
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';
import 'dart:io';
import 'dart:async';

class TextScannerScreen extends StatefulWidget {
  const TextScannerScreen({super.key});

  @override
  State<TextScannerScreen> createState() => _TextScannerScreenState();
}

class _TextScannerScreenState extends State<TextScannerScreen> {
  CameraController? _cameraController;
  TextRecognizer? _textRecognizer;
  bool _isInitialized = false;
  bool _isProcessing = false;
  String _recognizedText = '';
  List<String> _numbersOnly = [];
  
  // Timer cho việc quét tự động
  Timer? _scanTimer;
  int _scanAttempts = 0;
  static const int maxScanAttempts = 20; // Tối đa 20 lần quét (10 giây)

  @override
  void initState() {
    super.initState();
    _initializeCamera();
  }

  Future<void> _initializeCamera() async {
    try {
      final cameras = await availableCameras();
      if (cameras.isNotEmpty) {
        // Tìm camera cận (ultra-wide) cho iPhone
        CameraDescription? selectedCamera;
        
        // Ưu tiên camera cận (ultra-wide) cho iPhone
        for (final camera in cameras) {
          if (camera.lensDirection == CameraLensDirection.back) {
            // Kiểm tra nếu là camera cận (thường có tên chứa "ultra" hoặc "wide")
            if (camera.name.toLowerCase().contains('ultra') || 
                camera.name.toLowerCase().contains('wide') ||
                camera.name.toLowerCase().contains('macro') ||
                camera.name.toLowerCase().contains('telephoto')) {
              selectedCamera = camera;
              break;
            }
          }
        }
        
        // Nếu không tìm thấy camera cận, sử dụng camera sau đầu tiên
        selectedCamera ??= cameras.firstWhere(
          (camera) => camera.lensDirection == CameraLensDirection.back,
          orElse: () => cameras.first,
        );
        
        _cameraController = CameraController(
          selectedCamera,
          ResolutionPreset.high,
          enableAudio: false,
        );

        await _cameraController!.initialize();
        
        // Cấu hình camera cho chế độ macro/cận
        if (Platform.isIOS) {
          try {
            // Thiết lập focus mode cho camera cận
            await _cameraController!.setFocusMode(FocusMode.auto);
            await _cameraController!.setFocusPoint(const Offset(0.5, 0.5));
            
            // Thiết lập zoom để tối ưu cho chế độ cận
            // Zoom level cao hơn để camera có thể lấy nét gần hơn
            await _cameraController!.setZoomLevel(2.0);
            
            // Thiết lập exposure mode để tối ưu cho chế độ cận
            await _cameraController!.setExposureMode(ExposureMode.auto);
            
            // Kích hoạt flash nếu cần để cải thiện độ sáng
            await _cameraController!.setFlashMode(FlashMode.auto);
            
          } catch (e) {
            print('Error setting camera focus: $e');
          }
        }
        
        _textRecognizer = TextRecognizer();
        
        setState(() {
          _isInitialized = true;
        });
        
        // Bắt đầu quét tự động sau khi khởi tạo
        _startAutoScan();
      }
    } catch (e) {
      print('Error initializing camera: $e');
    }
  }

  void _startAutoScan() {
    // Quét mỗi 500ms (2 lần/giây)
    _scanTimer = Timer.periodic(const Duration(milliseconds: 500), (timer) {
      if (_isProcessing || _scanAttempts >= maxScanAttempts) {
        if (_scanAttempts >= maxScanAttempts) {
          timer.cancel();
          _showMaxAttemptsDialog();
        }
        return;
      }
      
      _processImage();
      _scanAttempts++;
    });
  }

  void _stopAutoScan() {
    _scanTimer?.cancel();
    _scanTimer = null;
    _scanAttempts = 0;
  }

  // Hàm ép camera lấy nét lại
  Future<void> _forceFocus() async {
    if (_cameraController == null || !_cameraController!.value.isInitialized) return;
    
    try {
      // Thay đổi focus point để ép camera lấy nét lại
      await _cameraController!.setFocusPoint(const Offset(0.5, 0.5));
      await _cameraController!.setFocusMode(FocusMode.auto);
      
      // Delay nhỏ để camera có thời gian lấy nét
      await Future.delayed(const Duration(milliseconds: 200));
    } catch (e) {
      print('Error forcing focus: $e');
    }
  }

  Future<void> _processImage() async {
    if (_cameraController == null || _textRecognizer == null || _isProcessing) return;

    setState(() {
      _isProcessing = true;
    });

    try {
      // Ép camera lấy nét trước khi chụp
      await _forceFocus();
      
      final XFile image = await _cameraController!.takePicture();
      final inputImage = InputImage.fromFilePath(image.path);
      
      final recognizedText = await _textRecognizer!.processImage(inputImage);
      
      // Lọc để lấy các dãy số có đúng 13, 14, 15 hoặc 16 chữ số
      final numbersOnly = <String>[];
      final fullText = recognizedText.text;
      // Tìm các dãy số có thể bị ngắt bởi khoảng trắng
      final imeiPattern = RegExp(r'\b\d{1,16}(?:\s*\d{1,16})*\b');
      final matches = imeiPattern.allMatches(fullText);
      
      for (final match in matches) {
        String candidate = match.group(0)!;
        // Loại bỏ khoảng trắng
        candidate = candidate.replaceAll(RegExp(r'\s+'), '');
        // Kiểm tra độ dài sau khi loại bỏ khoảng trắng
        if (candidate.length >= 13 && candidate.length <= 16) {
          numbersOnly.add(candidate);
        }
      }

      // Loại bỏ trùng lặp
      final uniqueNumbers = numbersOnly.toSet().toList();

      setState(() {
        _recognizedText = recognizedText.text;
        _numbersOnly = uniqueNumbers;
      });

      // Nếu tìm thấy số, dừng quét và trả về
      if (uniqueNumbers.isNotEmpty) {
        _stopAutoScan();
        await Future.delayed(const Duration(milliseconds: 500)); // Delay nhỏ để UI update
        Navigator.pop(context, uniqueNumbers.first);
      }
      // Nếu không tìm thấy, tiếp tục quét tự động
      
    } catch (e) {
      print('Error processing image: $e');
    } finally {
      setState(() {
        _isProcessing = false;
      });
    }
  }

  void _showMaxAttemptsDialog() {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        title: const Text('Không tìm thấy IMEI'),
        content: const Text('Đã quét trong 10 giây nhưng không tìm thấy IMEI hợp lệ. Vui lòng thử lại.'),
        actions: [
          TextButton(
            onPressed: () {
              Navigator.pop(context);
              _scanAttempts = 0;
              _startAutoScan(); // Bắt đầu lại
            },
            child: const Text('Thử lại'),
          ),
          TextButton(
            onPressed: () {
              Navigator.pop(context);
              _stopAutoScan();
              Navigator.pop(context, null); // Hủy và return null
            },
            child: const Text('Hủy'),
          ),
        ],
      ),
    );
  }

  // Nút dừng quét thủ công
  void _stopScanning() {
    _stopAutoScan();
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Đã dừng quét'),
        content: const Text('Quét tự động đã được dừng. Bạn có muốn bắt đầu lại?'),
        actions: [
          TextButton(
            onPressed: () {
              Navigator.pop(context);
              _startAutoScan();
            },
            child: const Text('Bắt đầu lại'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Đóng'),
          ),
        ],
      ),
    );
  }

  @override
  void dispose() {
    _stopAutoScan();
    _cameraController?.dispose();
    _textRecognizer?.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!_isInitialized) {
      return const Scaffold(
        body: Center(
          child: CircularProgressIndicator(),
        ),
      );
    }

    return Scaffold(
      appBar: AppBar(
        title: const Text('Quét IMEI', style: TextStyle(color: Colors.white)),
        backgroundColor: Colors.black,
        iconTheme: const IconThemeData(color: Colors.white),
        actions: [
          IconButton(
            icon: const Icon(Icons.center_focus_strong, color: Colors.white),
            onPressed: _forceFocus,
            tooltip: 'Ép lấy nét',
          ),
          IconButton(
            icon: const Icon(Icons.stop, color: Colors.white),
            onPressed: _stopScanning,
            tooltip: 'Dừng quét',
          ),
        ],
      ),
      body: Stack(
        children: [
          // Camera preview
          SizedBox(
            width: double.infinity,
            height: double.infinity,
            child: CameraPreview(_cameraController!),
          ),
          
          // Overlay với khung quét
          Center(
            child: Container(
              width: MediaQuery.of(context).size.width * 0.8,
              height: 100,
              decoration: BoxDecoration(
                border: Border.all(color: Colors.red, width: 2),
                borderRadius: BorderRadius.circular(8),
              ),
              child: const Center(
                child: Text(
                  'Đặt IMEI cần quét trong khung này\n(Đưa camera gần để lấy nét tốt hơn)',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: Colors.white,
                    backgroundColor: Colors.black54,
                    fontSize: 16,
                  ),
                ),
              ),
            ),
          ),
          
          // Hiển thị trạng thái quét
          Positioned(
            top: 20,
            left: 16,
            right: 16,
            child: Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: _isProcessing ? Colors.orange : Colors.blue,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    _isProcessing 
                      ? 'Đang quét...' 
                      : 'Chuẩn bị quét...',
                    style: const TextStyle(
                      color: Colors.white, 
                      fontWeight: FontWeight.bold,
                      fontSize: 16
                    ),
                  ),
                  if (_isProcessing)
                    const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(
                        color: Colors.white,
                        strokeWidth: 2,
                      ),
                    ),
                  Text(
                    'Lần: $_scanAttempts',
                    style: const TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.w500
                    ),
                  ),
                ],
              ),
            ),
          ),
          
          // Hiển thị kết quả nhận dạng
          if (_recognizedText.isNotEmpty)
            Positioned(
              bottom: 100,
              left: 16,
              right: 16,
              child: Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Colors.black87,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Text(
                      'Kết quả gần nhất:',
                      style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
                    ),
                    const SizedBox(height: 8),
                    if (_numbersOnly.isNotEmpty) ...[
                      const Text(
                        'IMEI tìm thấy:',
                        style: TextStyle(color: Colors.green, fontWeight: FontWeight.bold),
                      ),
                      ..._numbersOnly.take(3).map((number) => Padding(
                        padding: const EdgeInsets.only(top: 4),
                        child: Text(
                          '• $number',
                          style: const TextStyle(color: Colors.green),
                        ),
                      )),
                    ] else
                      Text(
                        'Không tìm thấy IMEI...',
                        style: TextStyle(color: Colors.yellow),
                      ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}