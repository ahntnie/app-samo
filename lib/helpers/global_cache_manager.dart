import 'package:supabase_flutter/supabase_flutter.dart';
import 'advanced_cache_manager.dart';

/// Global Cache Manager - Wrapper around AdvancedCacheManager
/// Giữ backward compatibility với code cũ
/// 
/// DEPRECATED: Sử dụng AdvancedCacheManager trực tiếp cho tính năng mới
class GlobalCacheManager {
  static final GlobalCacheManager _instance = GlobalCacheManager._internal();
  factory GlobalCacheManager() => _instance;
  GlobalCacheManager._internal();

  // Delegate to AdvancedCacheManager
  final _advancedCache = AdvancedCacheManager();

  // Product Names
  Future<void> fetchAndCacheProducts(SupabaseClient client) async {
    await _advancedCache.fetchAndCacheProducts(client);
  }
  
  void cacheProductName(String id, String name) {
    _advancedCache.cacheProductName(id, name);
  }
  
  String getProductName(String? id) {
    return _advancedCache.getProductName(id);
  }
  
  Map<String, String> get productNameCache => _advancedCache.productNameCache;

  // Warehouse Names
  Future<void> fetchAndCacheWarehouses(SupabaseClient client) async {
    await _advancedCache.fetchAndCacheWarehouses(client);
  }
  
  void cacheWarehouseName(String id, String name) {
    _advancedCache.cacheWarehouseName(id, name);
  }
  
  String getWarehouseName(String? id) {
    return _advancedCache.getWarehouseName(id);
  }
  
  Map<String, String> get warehouseNameCache => _advancedCache.warehouseNameCache;

  // Supplier Names
  Future<void> fetchAndCacheSuppliers(SupabaseClient client) async {
    await _advancedCache.fetchAndCacheSuppliers(client);
  }
  
  void cacheSupplierName(String id, String name) {
    _advancedCache.cacheSupplierName(id, name);
  }
  
  String getSupplierName(String? id) {
    return _advancedCache.getSupplierName(id);
  }
  
  Map<String, String> get supplierNameCache => _advancedCache.supplierNameCache;

  // Fixer Names
  Future<void> fetchAndCacheFixers(SupabaseClient client) async {
    await _advancedCache.fetchAndCacheFixers(client);
  }
  
  void cacheFixerName(String id, String name) {
    _advancedCache.cacheFixerName(id, name);
  }
  
  String getFixerName(String? id) {
    return _advancedCache.getFixerName(id);
  }
  
  Map<String, String> get fixerNameCache => _advancedCache.fixerNameCache;

  // Customer Names
  Future<void> fetchAndCacheCustomers(SupabaseClient client) async {
    await _advancedCache.fetchAndCacheCustomers(client);
  }
  
  void cacheCustomerName(String id, String name) {
    _advancedCache.cacheCustomerName(id, name);
  }
  
  String getCustomerName(String? id) {
    return _advancedCache.getCustomerName(id);
  }
  
  Map<String, String> get customerNameCache => _advancedCache.customerNameCache;

  // Fetch tất cả caches một lúc
  Future<void> fetchAllCaches(SupabaseClient client) async {
    await _advancedCache.fetchAllCaches(client);
  }

  // Clear all caches
  Future<void> clearAllCaches() async {
    await _advancedCache.clearAllCaches();
  }
  
  // Force refresh specific cache
  Future<void> invalidateProductsCache(SupabaseClient client) async {
    await _advancedCache.invalidateProductsCache(client);
  }
  
  Future<void> invalidateWarehousesCache(SupabaseClient client) async {
    await _advancedCache.invalidateWarehousesCache(client);
  }
  
  Future<void> invalidateSuppliersCache(SupabaseClient client) async {
    await _advancedCache.invalidateSuppliersCache(client);
  }
  
  Future<void> invalidateFixersCache(SupabaseClient client) async {
    await _advancedCache.invalidateFixersCache(client);
  }
  
  Future<void> invalidateCustomersCache(SupabaseClient client) async {
    await _advancedCache.invalidateCustomersCache(client);
  }

  // New methods from AdvancedCacheManager
  Future<void> initialize() async {
    await _advancedCache.initialize();
  }

  void startBackgroundSync(SupabaseClient client) {
    _advancedCache.startBackgroundSync(client);
  }

  void stopBackgroundSync() {
    _advancedCache.stopBackgroundSync();
  }

  Map<String, dynamic> getCacheStats() {
    return _advancedCache.getCacheStats();
  }

  void printCacheStats() {
    _advancedCache.printCacheStats();
  }
}

