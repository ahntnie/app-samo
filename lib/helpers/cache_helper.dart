import 'global_cache_manager.dart';

/// Helper functions để tự động cache sau khi insert/update
/// Đảm bảo cache luôn sync với database
class CacheHelper {
  static final _cache = GlobalCacheManager();

  /// Cache customer sau khi insert/update
  static void cacheCustomer(String id, String name) {
    _cache.cacheCustomerName(id, name);
    print('✅ Cached customer: $name (id: $id)');
  }

  /// Cache supplier sau khi insert/update
  static void cacheSupplier(String id, String name) {
    _cache.cacheSupplierName(id, name);
    print('✅ Cached supplier: $name (id: $id)');
  }

  /// Cache product sau khi insert/update
  static void cacheProduct(String id, String name) {
    _cache.cacheProductName(id, name);
    print('✅ Cached product: $name (id: $id)');
  }

  /// Cache warehouse sau khi insert/update
  static void cacheWarehouse(String id, String name) {
    _cache.cacheWarehouseName(id, name);
    print('✅ Cached warehouse: $name (id: $id)');
  }

  /// Cache fixer sau khi insert/update
  static void cacheFixer(String id, String name) {
    _cache.cacheFixerName(id, name);
    print('✅ Cached fixer: $name (id: $id)');
  }
}

