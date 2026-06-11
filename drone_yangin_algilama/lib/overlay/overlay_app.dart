import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/detection_uploader.dart';
import '../services/flame_detector.dart';

/// OverlayApp
/// ------------------------------------------------------------------
/// Ekran ustu gorunum TAMAMEN KALDIRILDI.
///
/// Bu widget artik telefon ekraninda hicbir sey cizmiyor -- sadece:
///   1) FlameDetector (PyTorch modeli) ile kare analizi yapiyor,
///   2) Tespit varsa DetectionUploader ile Firebase'e (gorsel + Firestore
///      kaydi + yerel bildirim) gonderiyor.
///
/// Gorsellestirme = Firebase Storage'a yuklenen ISARETLENMIS resim.
/// Ekran ustu = tamamen seffaf, dokunuslara KAPALI bos katman.
/// ------------------------------------------------------------------
const _frameChannel = EventChannel('drone_yangin/frames');
const _overlayControlChannel = MethodChannel('drone_yangin/overlay_control');

class OverlayApp extends StatefulWidget {
  const OverlayApp({super.key});

  @override
  State<OverlayApp> createState() => _OverlayAppState();
}

class _OverlayAppState extends State<OverlayApp> {
  StreamSubscription? _frameSub;
  bool _modelReady = false;
  bool _isProcessing = false;

  @override
  void initState() {
    super.initState();
    // ignore: avoid_print
    print('[TANI] OverlayApp.initState() -> ${DateTime.now()}');
    _bootstrap();
  }

  Future<void> _bootstrap() async {
    // ignore: avoid_print
    print('[TANI] _bootstrap() basladi -> ${DateTime.now()}');
    try {
      await FlameDetector.instance.load().timeout(
        const Duration(seconds: 30),
        onTimeout: () {
          throw TimeoutException('Model yukleme 30 saniyede tamamlanmadi');
        },
      );
      // ignore: avoid_print
      print('[TANI] Model yuklendi -> ${DateTime.now()}');

      await DetectionUploader.instance.init();
      // ignore: avoid_print
      print('[TANI] DetectionUploader hazir -> ${DateTime.now()}');

      if (!mounted) return;
      _modelReady = true;

      _frameSub = _frameChannel.receiveBroadcastStream().listen(
        _onFrame,
        onError: (e, _) => debugPrint('Frame stream hatasi: $e'),
      );
      // ignore: avoid_print
      print('[TANI] frame stream dinlemeye baslandi -> ${DateTime.now()}');
    } catch (e, st) {
      // ignore: avoid_print
      print('[TANI] _bootstrap() HATA: $e\n$st -> ${DateTime.now()}');
    }
  }

  Future<void> _onFrame(dynamic event) async {
    if (!_modelReady || _isProcessing) return;
    if (event is! Map) return;

    final bytes = event['bytes'];
    final width = event['width'] as int? ?? 0;
    final height = event['height'] as int? ?? 0;
    final ts = event['timestamp'] as int? ?? 0;
    if (bytes is! Uint8List || width == 0 || height == 0) return;

    _isProcessing = true;
    try {
      final result = await FlameDetector.instance.analyzeJpegFrame(
        jpegBytes: bytes,
        frameWidth: width,
        frameHeight: height,
        timestampMs: ts,
      );

      if (result.flameDetected) {
        // await etmiyoruz: Firebase yukleme arka planda surerken kare isleme tikanmasin.
        unawaited(
          DetectionUploader.instance.reportDetection(
            result: result,
            jpegBytes: bytes,
          ),
        );
      }
    } catch (e) {
      debugPrint('Analiz hatasi: $e');
    } finally {
      _isProcessing = false;
    }
  }

  @override
  void dispose() {
    _frameSub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Ekran ustu tamamen seffaf ve bos -- dokunuslara hic karismaz.
    // Tum is arka planda (model + Firebase); gorsel bildirim = sistem bildirimi.
    return const MaterialApp(
      debugShowCheckedModeBanner: false,
      home: IgnorePointer(
        ignoring: true,
        child: SizedBox.expand(),
      ),
    );
  }
}

/// "Durdur" gibi komutlari overlay'den native servise iletmek icin yardimci.
Future<void> stopOverlayService() =>
    _overlayControlChannel.invokeMethod('stopService');
