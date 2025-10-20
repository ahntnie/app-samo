import 'package:TechLinh/screens/login_screen.dart';
import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // ✅ Thông tin Supabase
  await Supabase.initialize(
    url: 'https://ztmyzmkcwjiaathizgyy.supabase.co',
    anonKey: 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6Inp0bXl6bWtjd2ppYWF0aGl6Z3l5Iiwicm9sZSI6ImFub24iLCJpYXQiOjE3NDQ0MzY2MDksImV4cCI6MjA2MDAxMjYwOX0.h1VnRwJ4VWQdXS_R5VZUsXFk75It2deHb_fFXwleNJU',
  );

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
      home: const LoginScreen(), // ✅ Mở màn hình đăng nhập
    );
  }
}
