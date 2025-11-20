# Hướng dẫn thêm font hỗ trợ tiếng Việt

Để fix lỗi font tiếng Việt khi in PDF, bạn cần thêm font hỗ trợ Unicode vào thư mục này.

## Các bước:

1. **Tải font Roboto** (hỗ trợ đầy đủ tiếng Việt):
   - Truy cập: https://fonts.google.com/specimen/Roboto
   - Tải 2 file:
     - `Roboto-Regular.ttf`
     - `Roboto-Bold.ttf`
   
   Hoặc tải từ: https://github.com/google/fonts/tree/main/apache/roboto

2. **Đặt file vào thư mục này**:
   - `assets/fonts/Roboto-Regular.ttf`
   - `assets/fonts/Roboto-Bold.ttf`

3. **Chạy lại ứng dụng**:
   - Code sẽ tự động load font từ assets
   - Nếu không có font, sẽ dùng font mặc định (có thể không hỗ trợ tiếng Việt)

## Lưu ý:
- File `pubspec.yaml` đã được cập nhật để khai báo assets
- Sau khi thêm font, chạy `flutter pub get` và rebuild app

