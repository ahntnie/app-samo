import 'dart:ui';
import 'dart:async';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:flutter/services.dart';
import 'screens/login_screen.dart';
import 'screens/reset_password_screen.dart';
import 'helpers/global_cache_manager.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  
  // Thêm global error handler để bắt lỗi và tránh crash
  FlutterError.onError = (FlutterErrorDetails details) {
    FlutterError.presentError(details);
    // Log lỗi để debug
    print('❌ [FlutterError] ${details.exception}');
    print('❌ [FlutterError] Stack: ${details.stack}');
  };
  
  // Bắt lỗi async không được catch
  PlatformDispatcher.instance.onError = (error, stack) {
    print('❌ [PlatformDispatcher Error] $error');
    print('❌ [PlatformDispatcher Error] Stack: $stack');
    return true; // Trả về true để báo rằng đã xử lý lỗi
  };
  
  // Initialize Firebase
  await Firebase.initializeApp();
  
  // Khởi tạo Supabase với dự án chính
  await Supabase.initialize(
    url: 'https://ztmyzmkcwjiaathizgyy.supabase.co',
    anonKey: 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6Inp0bXl6bWtjd2ppYWF0aGl6Z3l5Iiwicm9sZSI6ImFub24iLCJpYXQiOjE3NDQ0MzY2MDksImV4cCI6MjA2MDAxMjYwOX0.h1VnRwJ4VWQdXS_R5VZUsXFk75It2deHb_fFXwleNJU',
  );

  // Initialize Advanced Cache System
  print('🚀 Initializing Advanced Cache System...');
  await GlobalCacheManager().initialize();
  print('✅ Cache system ready!');

  runApp(const MyApp());
}

class MyApp extends StatefulWidget {
  const MyApp({super.key});

  @override
  State<MyApp> createState() => _MyAppState();
}

class _MyAppState extends State<MyApp> {
  @override
  void initState() {
    super.initState();
    _handleInitialUrl();
    _handleDeepLink();
  }

  Future<void> _handleInitialUrl() async {
    // Lấy initial URL khi app được mở từ link
    try {
      const platform = MethodChannel('com.example.sanmo/url');
      final String? url = await platform.invokeMethod('getInitialUrl');
      
      if (url != null && url.isNotEmpty) {
        print('Received URL: $url');
        await _processUrl(url);
      }
    } catch (e) {
      print('Error getting initial URL: $e');
    }
  }

  Future<void> _processUrl(String url) async {
    try {
      final uri = Uri.parse(url);
      print('Processing URL: $url');
      print('Path: ${uri.path}');
      print('Query params: ${uri.queryParameters}');
      
      // Kiểm tra nếu là Supabase auth callback
      if (uri.path.contains('/auth/v1/callback') || uri.path.contains('/auth/v1/verify')) {
        final accessToken = uri.queryParameters['access_token'];
        final type = uri.queryParameters['type'];
        
        print('Access token: ${accessToken != null ? "present" : "null"}');
        print('Type: $type');
        
        if (type == 'recovery' && accessToken != null) {
          // Set session với access token để xác thực recovery
          await Supabase.instance.client.auth.setSession(accessToken);
          
          // Chuyển đến màn hình reset password
          if (mounted) {
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (mounted) {
                Navigator.of(context).pushAndRemoveUntil(
                  MaterialPageRoute(
                    builder: (_) => const ResetPasswordScreen(),
                  ),
                  (route) => false,
                );
              }
            });
          }
        }
      }
    } catch (e) {
      print('Error processing URL: $e');
    }
  }

  void _handleDeepLink() {
    // Lắng nghe thay đổi auth state để xử lý password recovery
    Supabase.instance.client.auth.onAuthStateChange.listen((data) {
      final event = data.event;
      if (event == AuthChangeEvent.passwordRecovery) {
        // Khi nhận được password recovery event, chuyển đến màn hình reset password
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) {
            Navigator.of(context).pushAndRemoveUntil(
              MaterialPageRoute(
                builder: (_) => const ResetPasswordScreen(),
              ),
              (route) => false,
            );
          }
        });
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Quản lý nhập hàng',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.deepPurple),
        useMaterial3: true,
      ),
      home: const LoginScreen(),
    );
  }
}