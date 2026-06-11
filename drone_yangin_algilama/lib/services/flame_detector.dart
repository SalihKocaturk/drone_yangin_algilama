import 'dart:typed_data';

import 'package:pytorch_lite/pytorch_lite.dart';

import 'detection_models.dart';

/// FlameDetector
/// ------------------------------------------------------------------
/// assets/model.pt (TorchScript) dosyasini cihaz hafizasina yukler ve
/// gelen JPEG kareleri modele besleyerek alev tespiti + bounding box
/// sonuclarini dondurur.
///
/// pytorch_lite, modeli native PyTorch Mobile (org.pytorch:pytorch_android_lite)
/// uzerinden calistirir; "ModelObjectDetection" arayuzu YOLO-tarzi
/// (sinif + normalize bbox + confidence) ciktisi ureten modeller icindir.
///
/// NOT: Modelinizin gercek girdi/cikti seklini biliyorsaniz `inputSize`,
/// `confidenceThreshold` ve etiket dosyasini (assets/labels.txt) buna gore
/// guncelleyin. Etiketlerden "alev" / "flame" / "fire" iceren herhangi biri
/// pozitif (alarm) olarak kabul edilir; gerekirse `_isFlameLabel` fonksiyonunu
/// kendi sinif adlariniza gore degistirin.
/// ------------------------------------------------------------------
class FlameDetector {
  FlameDetector._();
  static final FlameDetector instance = FlameDetector._();

  ModelObjectDetection? _model;
  bool _isLoading = false;
  bool get isReady => _model != null;

  // Modelinizin egitildigi giris boyutu (kare varsayildi).
  // Colab'da "model.overrides['imgsz']" ile dogrulandi: 640
  static const int inputSize = 640;

  // Bu esigin altindaki tespitler gurultu kabul edilip yok sayilir.
  static const double confidenceThreshold = 0.45;

  /// Modeli bir kere, uygulama/servis baslarken yukler. Sonraki cagrilar no-op'tur.
  Future<void> load() async {
    // ignore: avoid_print
    print('[TANI] FlameDetector.load() cagrildi (model!=null:${_model != null}, '
        'isLoading:$_isLoading) -> ${DateTime.now()}');
    if (_model != null || _isLoading) return;
    _isLoading = true;
    try {
      // ignore: avoid_print
      print('[TANI] PytorchLite.loadObjectDetectionModel(...) CAGRILIYOR -> ${DateTime.now()}');
      _model = await PytorchLite.loadObjectDetectionModel(
        'assets/model.pt',
        // Colab export ciktisinda goruldu: cikis sekli (1, 6, 8400) -> 4 (bbox) + 2 (sinif)
        // yani model "fire" ve "smoke" olmak uzere 2 sinif iceriyor (bkz. assets/labels.txt).
        // Bu sayi modeldeki gercek sinif sayisiyla BIREBIR eslesmezse pytorch_lite
        // modeli yuklerken takilabilir/sessizce basarisiz olabilir.
        2,
        inputSize,
        inputSize,
        labelPath: 'assets/labels.txt',
        objectDetectionModelType: ObjectDetectionModelType.yolov8,
      );
      // ignore: avoid_print
      print('[TANI] PytorchLite.loadObjectDetectionModel(...) DONDU, '
          'model null mu: ${_model == null} -> ${DateTime.now()}');
    } catch (e, st) {
      // ignore: avoid_print
      print('[TANI] loadObjectDetectionModel HATA FIRLATTI: $e\n$st -> ${DateTime.now()}');
      rethrow;
    } finally {
      _isLoading = false;
    }
  }

  /// JPEG byte dizisini modele besler ve normalize edilmis tespit listesini dondurur.
  /// `frameWidth` / `frameHeight`: orijinal ekran karesinin piksel boyutlari
  /// (sonuclari ekrana geri olceklemek icin gereklidir).
  // Her N karede bir konsola "canli durum" yazdirmak icin sayac
  // (her karede yazdirmak konsolu bogar; bu yuzden seyreltiyoruz).
  int _frameLogCounter = 0;

  Future<FrameAnalysisResult> analyzeJpegFrame({
    required Uint8List jpegBytes,
    required int frameWidth,
    required int frameHeight,
    required int timestampMs,
  }) async {
    final model = _model;
    if (model == null) {
      return FrameAnalysisResult.empty(frameWidth, frameHeight, timestampMs);
    }

    final List<ResultObjectDetection?> raw = await model.getImagePrediction(
      jpegBytes,
      minimumScore: confidenceThreshold,
      iOUThreshold: 0.4,
    );

    // CANLI DURUM LOGU: model gercekten kare isliyor mu, ne goruyor -> konsola yaz.
    // Yaklasik her ~3 sn'de bir (3 FPS * 9 kare) tek satir basar; konsolu bogmaz
    // ama "calisiyor mu, ne algiliyor" sorusuna her zaman canli cevap verir.
    _frameLogCounter++;
    if (_frameLogCounter % 9 == 0) {
      final found = raw.whereType<ResultObjectDetection>().toList()
        ..sort((a, b) => b.score.compareTo(a.score));
      // ignore: avoid_print
      print(
        '[CANLI] kare islendi (#$_frameLogCounter) -> '
        '${found.isEmpty ? "esik (${confidenceThreshold.toStringAsFixed(2)}) ustunde sonuc yok" : found.take(3).map((r) => "${r.className ?? "?"}:${r.score.toStringAsFixed(2)}").join(", ")} '
        '-> ${DateTime.now()}',
      );
    }

    final detections = <FlameDetection>[];
    for (final r in raw) {
      if (r == null) continue;
      if (!_isFlameLabel(r.className ?? '')) continue;

      // pytorch_lite sonuclari 0..1 araliginda normalize bbox olarak doner
      // (rect.left/top/right/bottom). Degilse asagidaki satirlari kendi
      // modelinizin cikis formatina gore ayarlayin.
      detections.add(
        FlameDetection(
          left: r.rect.left.clamp(0.0, 1.0),
          top: r.rect.top.clamp(0.0, 1.0),
          right: r.rect.right.clamp(0.0, 1.0),
          bottom: r.rect.bottom.clamp(0.0, 1.0),
          confidence: r.score,
          label: r.className ?? 'alev',
        ),
      );
    }

    return FrameAnalysisResult(
      flameDetected: detections.isNotEmpty,
      detections: detections,
      sourceWidth: frameWidth,
      sourceHeight: frameHeight,
      timestampMs: timestampMs,
    );
  }

  bool _isFlameLabel(String label) {
    final l = label.toLowerCase();
    return l.contains('alev') || l.contains('flame') || l.contains('fire');
  }

  /// Servis/izolat kapanirken kaynaklari serbest birakmak icin (gerekirse).
  void dispose() {
    _model = null;
  }
}
