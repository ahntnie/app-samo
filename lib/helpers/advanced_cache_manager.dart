import 'package:hive_flutter/hive_flutter.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'dart:async';

/// Advanced Cache Manager với persistent storage và background sync
///
/// CHIẾN LƯỢC:
/// 1. Persistent Cache (Hive) - Data vẫn còn khi tắt app
/// 2. Background Sync - Fetch data mới trong background
/// 3. Smart Invalidation - Tự động refresh khi có thay đổi
/// 4. Multi-layer Cache - Memory (fast) + Disk (persistent)
class AdvancedCacheManager {
  static final AdvancedCacheManager _instance =
      AdvancedCacheManager._internal();
  factory AdvancedCacheManager() => _instance;
  AdvancedCacheManager._internal();

  // Hive boxes for persistent storage
  Box<Map<dynamic, dynamic>>? _productBox;
  Box<Map<dynamic, dynamic>>? _warehouseBox;
  Box<Map<dynamic, dynamic>>? _supplierBox;
  Box<Map<dynamic, dynamic>>? _fixerBox;
  Box<Map<dynamic, dynamic>>? _customerBox;
  Box<Map<dynamic, dynamic>>? _metadataBox;

  // In-memory cache (L1 - Fastest)
  final Map<String, String> _memoryProductCache = {};
  final Map<String, String> _memoryWarehouseCache = {};
  final Map<String, String> _memorySupplierCache = {};
  final Map<String, String> _memoryFixerCache = {};
  final Map<String, String> _memoryCustomerCache = {};

  // Background sync timers
  Timer? _backgroundSyncTimer;

  // Cache settings
  static const Duration _cacheExpiration = Duration(minutes: 10);
  static const Duration _backgroundSyncInterval = Duration(minutes: 5);

  bool _isInitialized = false;

  /// Initialize Hive và load persistent cache
  Future<void> initialize() async {
    if (_isInitialized) return;

    try {
      await Hive.initFlutter();

      // Open boxes
      _productBox = await Hive.openBox<Map>('products_cache');
      _warehouseBox = await Hive.openBox<Map>('warehouses_cache');
      _supplierBox = await Hive.openBox<Map>('suppliers_cache');
      _fixerBox = await Hive.openBox<Map>('fixers_cache');
      _customerBox = await Hive.openBox<Map>('customers_cache');
      _metadataBox = await Hive.openBox<Map>('cache_metadata');

      // Load disk cache vào memory
      await _loadDiskCacheToMemory();

      _isInitialized = true;
      print('✅ AdvancedCacheManager initialized');
    } catch (e) {
      print('❌ Error initializing AdvancedCacheManager: $e');
      _isInitialized = false;
    }
  }

  /// Load data từ disk cache vào memory cache
  Future<void> _loadDiskCacheToMemory() async {
    try {
      // Products
      if (_productBox != null && _productBox!.isNotEmpty) {
        final data = _productBox!.get('data');
        if (data != null) {
          _memoryProductCache.clear();
          data.forEach((key, value) {
            _memoryProductCache[key.toString()] = value.toString();
          });
        }
      }

      // Warehouses
      if (_warehouseBox != null && _warehouseBox!.isNotEmpty) {
        final data = _warehouseBox!.get('data');
        if (data != null) {
          _memoryWarehouseCache.clear();
          data.forEach((key, value) {
            _memoryWarehouseCache[key.toString()] = value.toString();
          });
        }
      }

      // Suppliers
      if (_supplierBox != null && _supplierBox!.isNotEmpty) {
        final data = _supplierBox!.get('data');
        if (data != null) {
          _memorySupplierCache.clear();
          data.forEach((key, value) {
            _memorySupplierCache[key.toString()] = value.toString();
          });
        }
      }

      // Fixers
      if (_fixerBox != null && _fixerBox!.isNotEmpty) {
        final data = _fixerBox!.get('data');
        if (data != null) {
          _memoryFixerCache.clear();
          data.forEach((key, value) {
            _memoryFixerCache[key.toString()] = value.toString();
          });
        }
      }

      // Customers
      if (_customerBox != null && _customerBox!.isNotEmpty) {
        final data = _customerBox!.get('data');
        if (data != null) {
          _memoryCustomerCache.clear();
          data.forEach((key, value) {
            _memoryCustomerCache[key.toString()] = value.toString();
          });
        }
      }

      print('✅ Loaded ${_memoryProductCache.length} products from disk cache');
      print(
        '✅ Loaded ${_memoryWarehouseCache.length} warehouses from disk cache',
      );
      print(
        '✅ Loaded ${_memorySupplierCache.length} suppliers from disk cache',
      );
      print('✅ Loaded ${_memoryFixerCache.length} fixers from disk cache');
      print(
        '✅ Loaded ${_memoryCustomerCache.length} customers from disk cache',
      );
    } catch (e) {
      print('❌ Error loading disk cache: $e');
    }
  }

  /// Kiểm tra cache có hết hạn chưa
  bool _isCacheExpired(String key) {
    if (_metadataBox == null) return true;

    final metadata = _metadataBox!.get(key);
    if (metadata == null) return true;

    final lastFetched = metadata['lastFetched'] as int?;
    if (lastFetched == null) return true;

    final lastFetchedTime = DateTime.fromMillisecondsSinceEpoch(lastFetched);
    return DateTime.now().difference(lastFetchedTime) > _cacheExpiration;
  }

  /// Cập nhật metadata timestamp
  Future<void> _updateMetadata(String key) async {
    if (_metadataBox == null) return;

    await _metadataBox!.put(key, {
      'lastFetched': DateTime.now().millisecondsSinceEpoch,
    });
  }

  // ============================================================================
  // PRODUCTS
  // ============================================================================

  Future<void> fetchAndCacheProducts(
    SupabaseClient client, {
    bool force = false,
  }) async {
    if (!_isInitialized) await initialize();

    // Nếu có cache trong memory và chưa hết hạn, skip
    if (!force &&
        _memoryProductCache.isNotEmpty &&
        !_isCacheExpired('products')) {
      return;
    }

    try {
      final response = await client
          .from('products_name')
          .select('id, products');

      _memoryProductCache.clear();
      final diskData = <String, String>{};

      for (var product in response) {
        final id = product['id'].toString();
        final name = product['products'] as String;
        _memoryProductCache[id] = name;
        diskData[id] = name;
      }

      // Lưu xuống disk
      await _productBox?.put('data', diskData);
      await _updateMetadata('products');

      print('✅ Fetched and cached ${_memoryProductCache.length} products');
    } catch (e) {
      print('❌ Error fetching products: $e');
    }
  }

  String getProductName(String? id) {
    if (id == null) return 'Không xác định';
    return _memoryProductCache[id] ?? 'Không xác định';
  }

  void cacheProductName(String id, String name) {
    _memoryProductCache[id] = name;
    // Async update disk (không block UI)
    Future.microtask(() async {
      final diskData = _productBox?.get('data');
      final data = Map<String, String>.from(diskData ?? {});
      data[id] = name;
      await _productBox?.put('data', data);
    });
  }

  Map<String, String> get productNameCache =>
      Map.unmodifiable(_memoryProductCache);

  // ============================================================================
  // WAREHOUSES
  // ============================================================================

  Future<void> fetchAndCacheWarehouses(
    SupabaseClient client, {
    bool force = false,
  }) async {
    if (!_isInitialized) await initialize();

    if (!force &&
        _memoryWarehouseCache.isNotEmpty &&
        !_isCacheExpired('warehouses')) {
      return;
    }

    try {
      final response = await client.from('warehouses').select('id, name');

      _memoryWarehouseCache.clear();
      final diskData = <String, String>{};

      for (var warehouse in response) {
        final id = warehouse['id'].toString();
        final name = warehouse['name'] as String;
        _memoryWarehouseCache[id] = name;
        diskData[id] = name;
      }

      await _warehouseBox?.put('data', diskData);
      await _updateMetadata('warehouses');

      print('✅ Fetched and cached ${_memoryWarehouseCache.length} warehouses');
    } catch (e) {
      print('❌ Error fetching warehouses: $e');
    }
  }

  String getWarehouseName(String? id) {
    if (id == null) return 'Không xác định';
    return _memoryWarehouseCache[id] ?? 'Không xác định';
  }

  void cacheWarehouseName(String id, String name) {
    _memoryWarehouseCache[id] = name;
    Future.microtask(() async {
      final diskData = _warehouseBox?.get('data');
      final data = Map<String, String>.from(diskData ?? {});
      data[id] = name;
      await _warehouseBox?.put('data', data);
    });
  }

  Map<String, String> get warehouseNameCache =>
      Map.unmodifiable(_memoryWarehouseCache);

  // ============================================================================
  // SUPPLIERS
  // ============================================================================

  Future<void> fetchAndCacheSuppliers(
    SupabaseClient client, {
    bool force = false,
  }) async {
    if (!_isInitialized) await initialize();

    if (!force &&
        _memorySupplierCache.isNotEmpty &&
        !_isCacheExpired('suppliers')) {
      return;
    }

    try {
      final response = await client.from('suppliers').select('id, name');

      _memorySupplierCache.clear();
      final diskData = <String, String>{};

      for (var supplier in response) {
        final id = supplier['id'].toString();
        final name = supplier['name'] as String;
        _memorySupplierCache[id] = name;
        diskData[id] = name;
      }

      await _supplierBox?.put('data', diskData);
      await _updateMetadata('suppliers');

      print('✅ Fetched and cached ${_memorySupplierCache.length} suppliers');
    } catch (e) {
      print('❌ Error fetching suppliers: $e');
    }
  }

  String getSupplierName(String? id) {
    if (id == null) return 'Không xác định';
    return _memorySupplierCache[id] ?? 'Không xác định';
  }

  void cacheSupplierName(String id, String name) {
    _memorySupplierCache[id] = name;
    Future.microtask(() async {
      final diskData = _supplierBox?.get('data');
      final data = Map<String, String>.from(diskData ?? {});
      data[id] = name;
      await _supplierBox?.put('data', data);
    });
  }

  Map<String, String> get supplierNameCache =>
      Map.unmodifiable(_memorySupplierCache);

  // ============================================================================
  // FIXERS
  // ============================================================================

  Future<void> fetchAndCacheFixers(
    SupabaseClient client, {
    bool force = false,
  }) async {
    if (!_isInitialized) await initialize();

    if (!force && _memoryFixerCache.isNotEmpty && !_isCacheExpired('fixers')) {
      return;
    }

    try {
      final response = await client.from('fix_units').select('id, name');

      _memoryFixerCache.clear();
      final diskData = <String, String>{};

      for (var fixer in response) {
        final id = fixer['id'].toString();
        final name = fixer['name'] as String;
        _memoryFixerCache[id] = name;
        diskData[id] = name;
      }

      await _fixerBox?.put('data', diskData);
      await _updateMetadata('fixers');

      print('✅ Fetched and cached ${_memoryFixerCache.length} fixers');
    } catch (e) {
      print('❌ Error fetching fixers: $e');
    }
  }

  String getFixerName(String? id) {
    if (id == null) return 'Không xác định';
    return _memoryFixerCache[id] ?? 'Không xác định';
  }

  void cacheFixerName(String id, String name) {
    _memoryFixerCache[id] = name;
    Future.microtask(() async {
      final diskData = _fixerBox?.get('data');
      final data = Map<String, String>.from(diskData ?? {});
      data[id] = name;
      await _fixerBox?.put('data', data);
    });
  }

  Map<String, String> get fixerNameCache => Map.unmodifiable(_memoryFixerCache);

  // ============================================================================
  // CUSTOMERS
  // ============================================================================

  Future<void> fetchAndCacheCustomers(
    SupabaseClient client, {
    bool force = false,
  }) async {
    if (!_isInitialized) await initialize();

    if (!force &&
        _memoryCustomerCache.isNotEmpty &&
        !_isCacheExpired('customers')) {
      return;
    }

    try {
      final response = await client.from('customers').select('id, name');

      _memoryCustomerCache.clear();
      final diskData = <String, String>{};

      for (var customer in response) {
        final id = customer['id'].toString();
        final name = customer['name'] as String;
        _memoryCustomerCache[id] = name;
        diskData[id] = name;
      }

      await _customerBox?.put('data', diskData);
      await _updateMetadata('customers');

      print('✅ Fetched and cached ${_memoryCustomerCache.length} customers');
    } catch (e) {
      print('❌ Error fetching customers: $e');
    }
  }

  String getCustomerName(String? id) {
    if (id == null) return 'Không xác định';
    return _memoryCustomerCache[id] ?? 'Không xác định';
  }

  void cacheCustomerName(String id, String name) {
    _memoryCustomerCache[id] = name;
    Future.microtask(() async {
      final diskData = _customerBox?.get('data');
      final data = Map<String, String>.from(diskData ?? {});
      data[id] = name;
      await _customerBox?.put('data', data);
    });
  }

  Map<String, String> get customerNameCache =>
      Map.unmodifiable(_memoryCustomerCache);

  // ============================================================================
  // BATCH OPERATIONS
  // ============================================================================

  /// Fetch tất cả caches một lúc
  Future<void> fetchAllCaches(
    SupabaseClient client, {
    bool force = false,
  }) async {
    await Future.wait([
      fetchAndCacheProducts(client, force: force),
      fetchAndCacheWarehouses(client, force: force),
      fetchAndCacheSuppliers(client, force: force),
      fetchAndCacheFixers(client, force: force),
      fetchAndCacheCustomers(client, force: force),
    ]);
  }

  /// Start background sync
  void startBackgroundSync(SupabaseClient client) {
    _backgroundSyncTimer?.cancel();

    _backgroundSyncTimer = Timer.periodic(_backgroundSyncInterval, (timer) {
      print('🔄 Background sync triggered');
      fetchAllCaches(client, force: false); // Chỉ refresh nếu hết hạn
    });

    print(
      '✅ Background sync started (every ${_backgroundSyncInterval.inMinutes} minutes)',
    );
  }

  /// Stop background sync
  void stopBackgroundSync() {
    _backgroundSyncTimer?.cancel();
    _backgroundSyncTimer = null;
    print('⏹️ Background sync stopped');
  }

  // ============================================================================
  // INVALIDATION
  // ============================================================================

  /// Force refresh specific cache
  Future<void> invalidateProductsCache(SupabaseClient client) async {
    await _metadataBox?.delete('products');
    await fetchAndCacheProducts(client, force: true);
  }

  Future<void> invalidateWarehousesCache(SupabaseClient client) async {
    await _metadataBox?.delete('warehouses');
    await fetchAndCacheWarehouses(client, force: true);
  }

  Future<void> invalidateSuppliersCache(SupabaseClient client) async {
    await _metadataBox?.delete('suppliers');
    await fetchAndCacheSuppliers(client, force: true);
  }

  Future<void> invalidateFixersCache(SupabaseClient client) async {
    await _metadataBox?.delete('fixers');
    await fetchAndCacheFixers(client, force: true);
  }

  Future<void> invalidateCustomersCache(SupabaseClient client) async {
    await _metadataBox?.delete('customers');
    await fetchAndCacheCustomers(client, force: true);
  }

  /// Clear all caches (memory + disk)
  Future<void> clearAllCaches() async {
    _memoryProductCache.clear();
    _memoryWarehouseCache.clear();
    _memorySupplierCache.clear();
    _memoryFixerCache.clear();
    _memoryCustomerCache.clear();

    await _productBox?.clear();
    await _warehouseBox?.clear();
    await _supplierBox?.clear();
    await _fixerBox?.clear();
    await _customerBox?.clear();
    await _metadataBox?.clear();

    print('🗑️ All caches cleared');
  }

  // ============================================================================
  // STATS & DEBUG
  // ============================================================================

  Map<String, dynamic> getCacheStats() {
    return {
      'products': _memoryProductCache.length,
      'warehouses': _memoryWarehouseCache.length,
      'suppliers': _memorySupplierCache.length,
      'fixers': _memoryFixerCache.length,
      'customers': _memoryCustomerCache.length,
      'backgroundSyncActive': _backgroundSyncTimer?.isActive ?? false,
    };
  }

  void printCacheStats() {
    final stats = getCacheStats();
    print('📊 Cache Stats:');
    print('   Products: ${stats['products']}');
    print('   Warehouses: ${stats['warehouses']}');
    print('   Suppliers: ${stats['suppliers']}');
    print('   Fixers: ${stats['fixers']}');
    print('   Customers: ${stats['customers']}');
    print('   Background Sync: ${stats['backgroundSyncActive']}');
  }

  /// Dispose (cleanup)
  Future<void> dispose() async {
    stopBackgroundSync();
    await _productBox?.close();
    await _warehouseBox?.close();
    await _supplierBox?.close();
    await _fixerBox?.close();
    await _customerBox?.close();
    await _metadataBox?.close();
    print('🔒 AdvancedCacheManager disposed');
  }
}
