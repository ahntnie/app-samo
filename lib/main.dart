import 'dart:ui';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'screens/login_screen.dart';
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

class MyApp extends StatelessWidget {
  const MyApp({super.key});

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