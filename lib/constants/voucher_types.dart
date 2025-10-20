// lib/constants/voucher_types.dart

/// Định nghĩa các loại phiếu tài chính qua enum
enum FinancialVoucherType {
  thuTienDoiTac,
  chiThanhToanDoiTac,
  chiTienDoiTac,
}

/// Phần mở rộng (extension) để trả về giá trị hiển thị cho từng loại phiếu
extension FinancialVoucherTypeExtension on FinancialVoucherType {
  String get display {
    switch (this) {
      case FinancialVoucherType.thuTienDoiTac:
        return 'Thu Tiền Đối Tác';
      case FinancialVoucherType.chiThanhToanDoiTac:
        return 'Chi Thanh Toán Đối Tác';
      case FinancialVoucherType.chiTienDoiTac:
        return 'Chi Tiền Đối Tác';
      default:
        return '';
    }
  }
}
