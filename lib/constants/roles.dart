// lib/constants/roles.dart

/// Định nghĩa các quyền người dùng (Roles)
enum UserRole {
  admin,
  manager,
  staff,
  guest,
}

/// Mỗi role có thể có một tập hợp quyền (permissions) khác nhau.
/// Bạn có thể định nghĩa một Map để ánh xạ giữa role và danh sách quyền.
final Map<UserRole, List<String>> rolePermissions = {
  UserRole.admin: ['all'],
  UserRole.manager: ['view', 'edit', 'delete'],
  UserRole.staff: ['view', 'edit'],
  UserRole.guest: ['view'],
};

/// Hàm trả về danh sách quyền dựa trên role
List<String> getPermissionsForRole(UserRole role) {
  return rolePermissions[role] ?? [];
}
