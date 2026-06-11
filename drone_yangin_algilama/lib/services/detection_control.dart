import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';

/// DetectionControl
/// ------------------------------------------------------------------
/// Ana ekran (MainActivity / lib/main.dart -> HomeScreen) ile native taraf
/// arasindaki tum izin / servis baslatma-durdurma akisini saran ince katman.
/// MethodChannel adi MainActivity.kt ile birebir eslesmelidir: "drone_yangin/control"
/// ------------------------------------------------------------------
class DetectionControl {
  DetectionControl._();
  static final DetectionControl instance = DetectionControl._();

  static const _channel = MethodChannel('drone_yangin/control');

  Future<bool> hasOverlayPermission() async {
    final result = await _channel.invokeMethod<bool>('hasOverlayPermission');
    return result ?? false;
  }

  /// Servisin sistemde GERCEKTEN calisip calismadigini sorar (UI'nin kendi
  /// hafizasindaki bayraga degil). Kullanici overlay iznini sistem ayarlarindan
  /// elle kapatirsa servis otomatik durmayabilir; bu yuzden ekrana donuldugunde
  /// bu metodla gercek durumu senkronlamak gerekir.
  Future<bool> isServiceRunning() async {
    final result = await _channel.invokeMethod<bool>('isServiceRunning');
    return result ?? false;
  }

  Future<void> requestOverlayPermission() async {
    await _channel.invokeMethod('requestOverlayPermission');
  }

  /// Bildirim izni (Android 13+) - permission_handler ile istenir.
  Future<bool> ensureNotificationPermission() async {
    final status = await Permission.notification.status;
    if (status.isGranted) return true;
    final result = await Permission.notification.request();
    return result.isGranted;
  }

  /// MediaProjection (ekran yakalama) izin dialogunu acar.
  /// Donus: kullanici izin verdi mi + sistem resultCode'u (servise iletilecek).
  Future<({bool granted, int resultCode})> requestMediaProjection() async {
    final response = await _channel.invokeMapMethod<String, dynamic>('requestMediaProjection');
    final granted = (response?['granted'] as bool?) ?? false;
    final resultCode = (response?['resultCode'] as int?) ?? 0;
    return (granted: granted, resultCode: resultCode);
  }

  /// Foreground service + overlay + MediaProjection yakalamayi baslatir.
  Future<void> startDetectionService(int resultCode) async {
    await _channel.invokeMethod('startDetectionService', {'resultCode': resultCode});
  }

  Future<void> stopDetectionService() async {
    await _channel.invokeMethod('stopDetectionService');
  }
}
