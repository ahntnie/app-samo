import 'package:flutter/material.dart';

/// Standardized loading dialog cho toàn bộ app
class LoadingDialog {
  static bool _isShowing = false;

  /// Hiển thị loading dialog
  static void show(BuildContext context, {String? message}) {
    if (_isShowing) return; // Tránh show nhiều dialog
    
    _isShowing = true;
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => WillPopScope(
        onWillPop: () async => false, // Không cho back
        child: AlertDialog(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const SizedBox(
                width: 50,
                height: 50,
                child: CircularProgressIndicator(strokeWidth: 3),
              ),
              const SizedBox(height: 20),
              Text(
                message ?? 'Đang xử lý...',
                style: const TextStyle(fontSize: 15),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 8),
              const Text(
                'Vui lòng chờ trong giây lát',
                style: TextStyle(fontSize: 12, color: Colors.grey),
                textAlign: TextAlign.center,
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// Đóng loading dialog
  static void hide(BuildContext context) {
    if (!_isShowing) return;
    
    _isShowing = false;
    if (Navigator.of(context).canPop()) {
      Navigator.of(context).pop();
    }
  }

  /// Check xem có đang hiển thị không
  static bool get isShowing => _isShowing;
}

/// Widget loading state chuẩn cho full screen
class LoadingScreen extends StatelessWidget {
  final String? message;

  const LoadingScreen({super.key, this.message});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const CircularProgressIndicator(),
            const SizedBox(height: 16),
            Text(
              message ?? 'Đang tải dữ liệu...',
              style: const TextStyle(fontSize: 15),
            ),
          ],
        ),
      ),
    );
  }
}

/// Widget error state chuẩn cho full screen
class ErrorScreen extends StatelessWidget {
  final String message;
  final VoidCallback? onRetry;

  const ErrorScreen({
    super.key,
    required this.message,
    this.onRetry,
  });

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(
                Icons.error_outline,
                size: 64,
                color: Colors.red,
              ),
              const SizedBox(height: 16),
              Text(
                message,
                textAlign: TextAlign.center,
                style: const TextStyle(fontSize: 16),
              ),
              if (onRetry != null) ...[
                const SizedBox(height: 24),
                ElevatedButton.icon(
                  onPressed: onRetry,
                  icon: const Icon(Icons.refresh),
                  label: const Text('Thử lại'),
                  style: ElevatedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 12),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// Widget empty state chuẩn
class EmptyState extends StatelessWidget {
  final String message;
  final IconData icon;
  final String? actionLabel;
  final VoidCallback? onAction;

  const EmptyState({
    super.key,
    required this.message,
    this.icon = Icons.inbox_outlined,
    this.actionLabel,
    this.onAction,
  });

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              icon,
              size: 64,
              color: Colors.grey,
            ),
            const SizedBox(height: 16),
            Text(
              message,
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 16, color: Colors.grey),
            ),
            if (actionLabel != null && onAction != null) ...[
              const SizedBox(height: 24),
              ElevatedButton(
                onPressed: onAction,
                child: Text(actionLabel!),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// Loading overlay cho operations không block toàn màn hình
class LoadingOverlay extends StatelessWidget {
  final bool isLoading;
  final Widget child;
  final String? message;

  const LoadingOverlay({
    super.key,
    required this.isLoading,
    required this.child,
    this.message,
  });

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        child,
        if (isLoading)
          Container(
            color: Colors.black54,
            child: Center(
              child: Card(
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const CircularProgressIndicator(),
                      if (message != null) ...[
                        const SizedBox(height: 16),
                        Text(message!),
                      ],
                    ],
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }
}

