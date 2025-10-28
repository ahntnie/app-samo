import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:timezone/timezone.dart' as tz;
import 'package:timezone/data/latest.dart' as tz;
import 'dart:convert';

class NotificationService {
  static final FlutterLocalNotificationsPlugin
  _flutterLocalNotificationsPlugin = FlutterLocalNotificationsPlugin();
  static bool _isAppInForeground = true;
  static late SupabaseClient _tenantClient;
  static String? _tenantUrl;
  static String? _tenantAnonKey;

  static Future<void> init(
    SupabaseClient tenantClient, {
    String? tenantUrl,
    String? tenantAnonKey,
    bool shouldGetFCMToken = false, // ✅ Chỉ lấy token khi đăng nhập lần đầu
  }) async {
    _tenantClient = tenantClient;
    _tenantUrl = tenantUrl;
    _tenantAnonKey = tenantAnonKey;
    tz.initializeTimeZones();
    final vietnam = tz.getLocation('Asia/Ho_Chi_Minh');
    tz.setLocalLocation(vietnam);

    // Request notification permissions first
    final NotificationSettings settings = await FirebaseMessaging.instance
        .requestPermission(
          alert: true,
          badge: true,
          sound: true,
          provisional: false,
        );
    print('User granted permission: ${settings.authorizationStatus}');

    // Set up foreground message handling
    FirebaseMessaging.onMessage.listen((RemoteMessage message) async {
      print('Got a message whilst in the foreground!');
      print('Message data: ${message.data}');

      // Handle notification when app is in foreground
      if (_isAppInForeground) {
        // If message contains a notification payload
        if (message.notification != null) {
          print('Message contains notification: ${message.notification}');
          await showNotification(
            DateTime.now().millisecondsSinceEpoch %
                2147483647, // Dynamic ID to avoid conflicts
            message.notification?.title ?? 'New Message',
            message.notification?.body ?? '',
            message.data['payload'] ?? 'foreground_message',
          );
        }
        // If message only contains data payload
        else if (message.data.isNotEmpty) {
          await showNotification(
            DateTime.now().millisecondsSinceEpoch % 2147483647,
            message.data['title'] ?? 'New Message',
            message.data['body'] ?? '',
            message.data['payload'] ?? 'foreground_data_message',
          );
        }
      }
    });

    const AndroidInitializationSettings initializationSettingsAndroid =
        AndroidInitializationSettings('@mipmap/ic_launcher');
    const DarwinInitializationSettings initializationSettingsIOS =
        DarwinInitializationSettings(
          requestAlertPermission: true,
          requestBadgePermission: true,
          requestSoundPermission: true,
          defaultPresentAlert: true,
          defaultPresentBadge: true,
          defaultPresentSound: true,
        );
    const InitializationSettings initializationSettings =
        InitializationSettings(
          android: initializationSettingsAndroid,
          iOS: initializationSettingsIOS,
        );

    const AndroidNotificationChannel channel = AndroidNotificationChannel(
      'high_importance_channel',
      'High Importance Notifications',
      description: 'This channel is used for important notifications.',
      importance: Importance.max,
      playSound: true,
      enableVibration: true,
      showBadge: true,
      enableLights: true,
    );

    await _flutterLocalNotificationsPlugin
        .resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin
        >()
        ?.createNotificationChannel(channel);

    await _flutterLocalNotificationsPlugin.initialize(
      initializationSettings,
      onDidReceiveNotificationResponse: (NotificationResponse response) async {
        // Handle notification tap
        print('Notification tapped: ${response.payload}');
      },
    );

    // ✅ CHỈ lấy và lưu FCM token khi đăng nhập lần đầu tiên
    if (shouldGetFCMToken) {
      try {
        final fcmToken = await FirebaseMessaging.instance.getToken();
        print('✅ FCM token (first login): $fcmToken');
        if (fcmToken != null) {
          await _saveDeviceToken(fcmToken);
        } else {
          print('Không thể lấy FCM token');
        }
      } catch (e) {
        print('Lỗi khi lấy FCM token: $e');
      }
    } else {
      print('⏭️ Skip FCM token retrieval (already logged in)');
    }

    // Lập lịch thông báo định kỳ
    await scheduleDailyNotification(
      1,
      "Nhắc Thu Hồi Công Nợ",
      "Kiểm tra công nợ khách hàng",
      14,
      0,
      checkDebtReminders,
    );

    await scheduleDailyNotification(
      2,
      "Nhắc Bán Sản Phẩm",
      "Kiểm tra sản phẩm tồn kho lâu",
      9,
      0,
      checkOverdueProducts,
    );

    await scheduleDailyNotification(
      3,
      "Nhắc Nhở Bán Hàng",
      "Kiểm tra doanh số trong ngày",
      20,
      0,
      checkNoSalesToday,
    );
  }

  static void updateAppState(bool isForeground) {
    _isAppInForeground = isForeground;
    print('App state updated: isForeground = $_isAppInForeground');
  }

  /// Gửi thông báo đến TẤT CẢ thiết bị thông qua Supabase Edge Function
  static Future<void> sendNotificationToAll(
    String title,
    String body, {
    Map<String, dynamic>? data,
  }) async {
    try {
      print('Sending notification to all devices: $title - $body');
      
      if (_tenantUrl == null || _tenantAnonKey == null) {
        print('Error: Tenant credentials not set. Call NotificationService.init() first.');
        return;
      }
      
      // Gọi Edge Function từ main Supabase project (không phải tenant)
      final mainClient = Supabase.instance.client;
      final response = await mainClient.functions.invoke(
        'send-fcm-notification',
        body: {
          'title': title,
          'body': body,
          'data': data ?? {},
          'tenant_url': _tenantUrl,
          'tenant_anon_key': _tenantAnonKey,
        },
      );

      if (response.status == 200) {
        final result = response.data;
        print('Notification sent successfully: ${jsonEncode(result)}');
      } else {
        print('Error sending notification: ${response.status} - ${response.data}');
      }
    } catch (e) {
      print('Exception sending notification to all devices: $e');
    }
  }

  static Future<void> _saveDeviceToken(String token) async {
    try {
      final existingToken =
          await _tenantClient
              .from('device_tokens')
              .select()
              .eq('fcm_token', token)
              .maybeSingle();
      print('Kiểm tra FCM existingToken: $token');
      if (existingToken == null) {
        await _tenantClient.from('device_tokens').insert({
          'fcm_token': token,
          'created_at': DateTime.now().toIso8601String(),
        });
        print('Đã lưu FCM token: $token');
      } else {
        print('FCM token đã tồn tại: $token');
      }
    } catch (e) {
      print('Lỗi khi lưu FCM token: $e');
    }
  }

  static Future<void> showNotification(
    int id,
    String title,
    String body,
    String payload,
  ) async {
    print('Attempting to show notification: $title - $body');

    try {
      await FirebaseMessaging.instance
          .setForegroundNotificationPresentationOptions(
            alert: true,
            badge: true,
            sound: true,
          );
          
      const AndroidNotificationDetails androidPlatformChannelSpecifics =
          AndroidNotificationDetails(
            'high_importance_channel',
            'High Importance Notifications',
            channelDescription:
                'This channel is used for important notifications.',
            importance: Importance.max,
            priority: Priority.high,
            showWhen: true,
            playSound: true,
            enableVibration: true,
            fullScreenIntent: true,
            category: AndroidNotificationCategory.message,
            visibility: NotificationVisibility.public,
            ticker: 'New notification',
            ongoing: false,
            channelShowBadge: true,
            autoCancel: true,
            styleInformation: BigTextStyleInformation(''),
          );
      const DarwinNotificationDetails iOSPlatformChannelSpecifics =
          DarwinNotificationDetails(
            presentAlert: true,
            presentBadge: true,
            presentSound: true,
            presentBanner: true,
            presentList: true,
            sound: 'default',
            badgeNumber: 1,
            interruptionLevel: InterruptionLevel.timeSensitive,
            threadIdentifier: 'high_importance_channel',
          );
      const NotificationDetails platformChannelSpecifics = NotificationDetails(
        android: androidPlatformChannelSpecifics,
        iOS: iOSPlatformChannelSpecifics,
      );

      await _flutterLocalNotificationsPlugin.show(
        id,
        title,
        body,
        platformChannelSpecifics,
        payload: payload,
      );
      print('Notification shown successfully');
    } catch (e) {
      print('Error showing notification: $e');
    }
  }

  static Future<void> scheduleDailyNotification(
    int id,
    String title,
    String body,
    int hour,
    int minute,
    Function callback,
  ) async {
    await _flutterLocalNotificationsPlugin.zonedSchedule(
      id,
      title,
      body,
      _nextInstanceOfTime(hour, minute),
      const NotificationDetails(
        android: AndroidNotificationDetails(
          'daily_channel',
          'Daily Reminders',
          importance: Importance.max,
          priority: Priority.high,
        ),
      ),
      androidScheduleMode: AndroidScheduleMode.exactAllowWhileIdle,
      matchDateTimeComponents: DateTimeComponents.time,
      payload: 'daily',
    );

    await callback();
  }

  static tz.TZDateTime _nextInstanceOfTime(int hour, int minute) {
    final vietnam = tz.getLocation('Asia/Ho_Chi_Minh');
    final tz.TZDateTime now = tz.TZDateTime.now(vietnam);
    tz.TZDateTime scheduledDate = tz.TZDateTime(
      vietnam,
      now.year,
      now.month,
      now.day,
      hour,
      minute,
    );
    if (scheduledDate.isBefore(now)) {
      scheduledDate = scheduledDate.add(const Duration(days: 1));
    }
    return scheduledDate;
  }

  static Future<void> checkDebtReminders() async {
    final now = DateTime.now();

    final response = await _tenantClient
        .from('sale_orders')
        .select('customer, price, currency, created_at')
        .eq('account', 'Công nợ')
        .eq('iscancelled', false);

    if (response.isEmpty) {
      print('Không có đơn hàng công nợ nào để kiểm tra');
      return;
    }

    final orders = response;
    if (orders.isEmpty) return;

    Map<String, Map<String, dynamic>> latestOrdersByCustomer = {};
    for (var order in orders) {
      final customer = order['customer'] as String?;
      if (customer == null) continue;
      final createdAt = DateTime.parse(order['created_at'] as String);
      if (!latestOrdersByCustomer.containsKey(customer) ||
          createdAt.isAfter(
            DateTime.parse(latestOrdersByCustomer[customer]!['created_at']),
          )) {
        latestOrdersByCustomer[customer] = {
          'price': order['price'] as num,
          'currency': order['currency'] as String,
          'created_at': order['created_at'],
        };
      }
    }

    Map<String, Map<String, num>> totalDebtByCustomer = {};
    int notificationId = 0;
    for (var order in orders) {
      final customer = order['customer'] as String?;
      if (customer == null) continue;
      final price = order['price'] as num;
      final currency = order['currency'] as String;
      if (!totalDebtByCustomer.containsKey(customer)) {
        totalDebtByCustomer[customer] = {currency: 0};
      }
      totalDebtByCustomer[customer]![currency] =
          (totalDebtByCustomer[customer]![currency] ?? 0) + price;
    }

    for (var customer in latestOrdersByCustomer.keys) {
      final latestOrder = latestOrdersByCustomer[customer]!;
      final createdAt = DateTime.parse(latestOrder['created_at']);
      final daysSinceOrder = now.difference(createdAt).inDays;

      if (daysSinceOrder >= 6) {
        final debt = totalDebtByCustomer[customer]!;
        final debtMessage = debt.entries
            .map((entry) => "${entry.value} ${entry.key}")
            .join(", ");
        final title = "Nhắc Thu Hồi Công Nợ";
        final message =
            "Khách hàng $customer còn nợ $debtMessage với đơn hàng gần nhất cách đây $daysSinceOrder ngày. Hãy liên hệ thu hồi công nợ chứ hết mẹ nó tiền rồi";

        await showNotification(
          notificationId++,
          title,
          message,
          'debt_reminder',
        );
      }
    }
  }

  static Future<void> checkOverdueProducts() async {
    final now = DateTime.now();

    final response = await _tenantClient
        .from('products')
        .select('name, import_transfer_date')
        .not('import_transfer_date', 'is', null)
        .not('status', 'eq', 'Đã bán');

    if (response.isEmpty) {
      print('Không có sản phẩm nhập kho nào để kiểm tra');
      return;
    }

    final products = response;
    if (products.isEmpty) return;

    int notificationId = 100;
    for (var product in products) {
      final importDate = DateTime.parse(
        product['import_transfer_date'] as String,
      );
      final daysSinceImport = now.difference(importDate).inDays;

      if (daysSinceImport > 7) {
        final productName = product['name'] as String?;
        if (productName == null) continue;
        final title = "Nhắc Bán Sản Phẩm";
        final message =
            "Sản phẩm $productName đã nhập kho $daysSinceImport ngày. Bán nhanh kẻo lỗ chết bây giờ";

        await showNotification(
          notificationId++,
          title,
          message,
          'overdue_product',
        );
      }
    }
  }

  static Future<void> checkNoSalesToday() async {
    final now = DateTime.now();
    final startOfDay = DateTime(now.year, now.month, now.day);
    final endOfDay = startOfDay.add(const Duration(days: 1));

    final response = await _tenantClient
        .from('sale_orders')
        .select('created_at')
        .gte('created_at', startOfDay.toIso8601String())
        .lt('created_at', endOfDay.toIso8601String())
        .eq('iscancelled', false);

    if (response.isEmpty) {
      await showNotification(
        4000,
        "Nhắc Nhở Bán Hàng",
        "Hôm nay móm rồi. Không bán được hàng nên nhịn cơm",
        'no_sales_today',
      );
    }
  }
}
