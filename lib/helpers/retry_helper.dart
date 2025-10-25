import 'dart:async';
import 'package:flutter/material.dart';
import 'error_handler.dart';

/// Helper để retry operations với exponential backoff
class RetryHelper {
  /// Retry một async operation với exponential backoff
  /// 
  /// [operation] - Function cần retry
  /// [maxAttempts] - Số lần thử tối đa (default: 3)
  /// [delayFactor] - Hệ số delay giữa các lần thử (default: 1 giây)
  /// [onRetry] - Callback khi retry (để update UI)
  static Future<T> retry<T>({
    required Future<T> Function() operation,
    int maxAttempts = 3,
    Duration delayFactor = const Duration(seconds: 1),
    void Function(int attempt)? onRetry,
  }) async {
    int attempt = 0;
    
    while (true) {
      attempt++;
      try {
        return await operation();
      } catch (e) {
        if (attempt >= maxAttempts) {
          rethrow; // Đã hết số lần thử, throw error
        }
        
        // Callback để update UI
        onRetry?.call(attempt);
        
        // Exponential backoff: 1s, 2s, 4s, ...
        final delay = delayFactor * (1 << (attempt - 1));
        await Future.delayed(delay);
      }
    }
  }

  /// Retry với dialog progress
  static Future<T?> retryWithDialog<T>({
    required BuildContext context,
    required Future<T> Function() operation,
    required String operationName,
    int maxAttempts = 3,
  }) async {
    int currentAttempt = 0;
    
    return await showDialog<T>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setState) {
          return AlertDialog(
            title: Text(operationName),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const CircularProgressIndicator(),
                const SizedBox(height: 16),
                Text(
                  currentAttempt > 0
                      ? 'Đang thử lại... (Lần ${currentAttempt + 1}/$maxAttempts)'
                      : 'Đang xử lý...',
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  /// Execute operation với retry + user-friendly error
  static Future<T?> executeWithRetry<T>({
    required BuildContext context,
    required Future<T> Function() operation,
    required String operationName,
    int maxAttempts = 3,
    bool showLoadingDialog = true,
  }) async {
    int attempt = 0;
    dynamic lastError;

    // Hiển thị loading dialog nếu cần
    if (showLoadingDialog && context.mounted) {
      showDialog(
        context: context,
        barrierDismissible: false,
        builder: (context) => AlertDialog(
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const CircularProgressIndicator(),
              const SizedBox(height: 16),
              Text(operationName),
            ],
          ),
        ),
      );
    }

    while (attempt < maxAttempts) {
      attempt++;
      try {
        final result = await operation();
        
        // Đóng loading dialog
        if (showLoadingDialog && context.mounted) {
          Navigator.of(context).pop();
        }
        
        return result;
      } catch (e) {
        lastError = e;
        
        if (attempt < maxAttempts) {
          // Retry với delay
          await Future.delayed(Duration(seconds: attempt));
        }
      }
    }

    // Đóng loading dialog
    if (showLoadingDialog && context.mounted) {
      Navigator.of(context).pop();
    }

    // Hết số lần thử, hiển thị error dialog
    if (context.mounted) {
      final shouldRetry = await ErrorHandler.showErrorDialog(
        context: context,
        title: 'Lỗi $operationName',
        error: lastError,
        showRetry: true,
      );

      if (shouldRetry) {
        // User muốn thử lại, gọi lại function
        return await executeWithRetry<T>(
          context: context,
          operation: operation,
          operationName: operationName,
          maxAttempts: maxAttempts,
          showLoadingDialog: showLoadingDialog,
        );
      }
    }

    return null;
  }
}

