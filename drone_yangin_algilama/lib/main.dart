import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/material.dart';

import 'overlay/overlay_app.dart';
import 'root_screen.dart';

/// =====================================================================
/// GIRIS NOKTASI #1: Normal uygulama (kullanicinin gordugu ana program)
/// Login / auth YOK -> dogrudan ana kontrol arayuzu (HomeScreen) acilir.
/// =====================================================================
///
/// NOT (Firebase): google-services.json android/app/ icine konuldugu ve
/// google-services Gradle plugin'i etkin oldugu icin, Android native tarafta
/// FirebaseApp otomatik olusturulur; Dart tarafinda ekstra "options" vermeye
/// gerek yok -> Firebase.initializeApp() tek basina yeterli.
void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp();
  runApp(const DroneFireApp());
}

class DroneFireApp extends StatelessWidget {
  const DroneFireApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Drone Yangin Erken Uyari',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.red, brightness: Brightness.light),
        useMaterial3: true,
      ),
      home: const RootScreen(),
    );
  }
}

/// =====================================================================
/// GIRIS NOKTASI #2: Overlay penceresi icin AYRI Dart izolat girisi.
///
/// OverlayDetectionService.kt, kullanicinin ana uygulamayi kapatmasindan /
/// arka plana atmasindan BAGIMSIZ olarak, bu fonksiyonu YENI bir FlutterEngine
/// icinde calistirir (DartExecutor.DartEntrypoint(..., "overlayMain")).
///
/// @pragma('vm:entry-point') ZORUNLUDUR: aksi halde Flutter, derleme sirasinda
/// bu fonksiyonu "kullanilmiyor" sanip agac-budama (tree-shaking) ile siler ve
/// native taraf calisma anida bu girisi bulamaz.
/// =====================================================================
@pragma('vm:entry-point')
void overlayMain() async {
  // TESHIS: bu satir logcat'te gorunmuyorsa, native taraf overlayMain
  // giris noktasini hic calistiramiyor demektir (motor / entrypoint sorunu).
  // ignore: avoid_print
  print('[TANI] overlayMain() CAGRILDI -> ${DateTime.now()}');
  WidgetsFlutterBinding.ensureInitialized();

  // Bu izolat ANA uygulamadan TAMAMEN AYRI bir FlutterEngine'de calisir;
  // dolayisiyla Firebase'i burada da ayrica baslatmamiz gerekir
  // (aksi halde Firestore/Storage cagrilari "no Firebase App" hatasi verir).
  try {
    await Firebase.initializeApp();
    // ignore: avoid_print
    print('[TANI] overlayMain: Firebase.initializeApp() OK -> ${DateTime.now()}');
  } catch (e) {
    // ignore: avoid_print
    print('[TANI] overlayMain: Firebase.initializeApp() HATA: $e -> ${DateTime.now()}');
  }

  runApp(const OverlayApp());
  // ignore: avoid_print
  print('[TANI] runApp(OverlayApp) DONDU -> ${DateTime.now()}');
}
