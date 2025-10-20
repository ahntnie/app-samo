import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'login_screen.dart';

class SignUpScreen extends StatefulWidget {
  const SignUpScreen({super.key});

  @override
  State<SignUpScreen> createState() => _SignUpScreenState();
}

class _SignUpScreenState extends State<SignUpScreen> {
  final emailController = TextEditingController();
  final passwordController = TextEditingController();
  bool isLoading = false;
  bool showPassword = false;
  String? errorText;

  Future<void> signUp() async {
    if (!mounted) return;

    setState(() {
      isLoading = true;
      errorText = null;
    });

    final email = emailController.text.trim();
    final password = passwordController.text.trim();

    // Kiểm tra dữ liệu đầu vào
    if (email.isEmpty || password.isEmpty) {
      setState(() {
        errorText = 'Vui lòng điền đầy đủ email và mật khẩu';
        isLoading = false;
      });
      return;
    }

    if (!RegExp(r'^[\w-\.]+@([\w-]+\.)+[\w-]{2,4}$').hasMatch(email)) {
      setState(() {
        errorText = 'Email không hợp lệ';
        isLoading = false;
      });
      return;
    }

    if (password.length < 6) {
      setState(() {
        errorText = 'Mật khẩu phải có ít nhất 6 ký tự';
        isLoading = false;
      });
      return;
    }

    try {
      print('Attempting to sign up with email: $email');
      final response = await Supabase.instance.client.auth.signUp(
        email: email,
        password: password,
      );

      if (response.user != null) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              Supabase.instance.client.auth.currentSession != null
                  ? 'Đăng ký thành công! Vui lòng đăng nhập.'
                  : 'Đăng ký thành công! Vui lòng kiểm tra email để xác nhận tài khoản, sau đó đăng nhập.',
            ),
            backgroundColor: Colors.green,
          ),
        );
        // Luôn chuyển về LoginScreen sau khi đăng ký
        Navigator.pushReplacement(
          context,
          MaterialPageRoute(builder: (_) => const LoginScreen()),
        );
      } else {
        if (!mounted) return;
        setState(() {
          errorText = 'Không thể đăng ký tài khoản';
        });
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        errorText = 'Lỗi khi đăng ký: $e';
      });
      print('Sign-up error: $e');
    } finally {
      if (!mounted) return;
      setState(() {
        isLoading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF121826),
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text(
                'Đăng Ký',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 28, fontWeight: FontWeight.bold, color: Colors.white),
              ),
              const SizedBox(height: 8),
              const Text(
                'Nhập email và mật khẩu của bạn',
                textAlign: TextAlign.center,
                style: TextStyle(color: Colors.white70),
              ),
              const SizedBox(height: 24),
              TextField(
                controller: emailController,
                style: const TextStyle(color: Colors.white),
                decoration: InputDecoration(
                  hintText: 'Email',
                  hintStyle: const TextStyle(color: Colors.white54),
                  filled: true,
                  fillColor: const Color(0xFF1E293B),
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none),
                ),
              ),
              const SizedBox(height: 16),
              TextField(
                controller: passwordController,
                obscureText: !showPassword,
                style: const TextStyle(color: Colors.white),
                decoration: InputDecoration(
                  hintText: 'Mật khẩu',
                  hintStyle: const TextStyle(color: Colors.white54),
                  filled: true,
                  fillColor: const Color(0xFF1E293B),
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none),
                ),
              ),
              const SizedBox(height: 8),
              Row(
                mainAxisAlignment: MainAxisAlignment.start,
                children: [
                  Checkbox(
                    value: showPassword,
                    onChanged: (value) => setState(() => showPassword = value!),
                    activeColor: Colors.blue,
                  ),
                  const Text('Hiện mật khẩu', style: TextStyle(color: Colors.white70)),
                ],
              ),
              const SizedBox(height: 8),
              ElevatedButton(
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF2563EB),
                  foregroundColor: Colors.white,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  padding: const EdgeInsets.symmetric(vertical: 16),
                ),
                onPressed: isLoading ? null : signUp,
                child: isLoading
                    ? const CircularProgressIndicator(color: Colors.white)
                    : const Text('Đăng ký', style: TextStyle(fontSize: 16, color: Colors.white)),
              ),
              const SizedBox(height: 12),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  TextButton(
                    onPressed: isLoading
                        ? null
                        : () {
                            print('Navigating back to LoginScreen');
                            Navigator.pushReplacement(
                              context,
                              MaterialPageRoute(builder: (_) => const LoginScreen()),
                            );
                          },
                    child: const Text(
                      'Đăng nhập',
                      style: TextStyle(color: Colors.white, fontSize: 16),
                    ),
                  ),
                  const SizedBox(width: 0), // Giữ vị trí cho nút "Lấy lại mật khẩu" (bỏ đi ở màn hình này)
                ],
              ),
              if (errorText != null) ...[
                const SizedBox(height: 12),
                Text(errorText!, style: const TextStyle(color: Colors.redAccent), textAlign: TextAlign.center),
              ],
              const SizedBox(height: 24),
              const Text(
                'Phần Mềm Viết Bởi Vũ Ngọc Tú\n0948233333',
                textAlign: TextAlign.center,
                style: TextStyle(color: Colors.white54),
              ),
            ],
          ),
        ),
      ),
    );
  }
}