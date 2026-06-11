import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' show Color;

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:image/image.dart' as img;
import 'package:path_provider/path_provider.dart';

import 'detection_models.dart';

/// DetectionUploader — Offline-First Mimari
/// ------------------------------------------------------------------
/// Tello Wi-Fi'a bagliyken internete cikis olmaz; bu yuzden:
///
///   1. Tespit aninda gorsel ONCELIKLE lokale kaydedilir (internet gereksiz).
///   2. Bildirim hemen gosterilir (internet gereksiz).
///   3. Firestore yazmalari SDK'nin kendi offline persistence'i ile
///      kuyruga alinir; internet gelince otomatik gonderilir.
///   4. Storage yukleme denenir; basarisiz olursa lokal kuyrukta kalir.
///   5. Sonraki reportDetection() veya init() cagrısında bekleyen
///      gorseller yeniden yuklemeye calisir.
///
/// Lokal dosya yapisi:
///   <appDocDir>/drone_detections/
///       pending_queue.json          <- yuklenemeyen goruntuler kuyrugu
///       images/<timestamp>.jpg      <- isaretlenmis gorsel dosyalari
/// ------------------------------------------------------------------
class DetectionUploader {
  DetectionUploader._();
  static final DetectionUploader instance = DetectionUploader._();

  // En az kac ms arayla yukleme yapilsin (12 sn = Tello uzerindeyken
  // cok fazla kayit birikmesin diye).
  static const _cooldown = Duration(seconds: 12);
  DateTime? _lastUploadAt;
  bool _busy = false;

  final FlutterLocalNotificationsPlugin _notifications =
      FlutterLocalNotificationsPlugin();
  bool _notificationsReady = false;

  static const _channelId = 'alev_uyari_kanali';
  static const _channelName = 'Alev / Duman Uyarıları';

  // Lokal dizin referansi (init() sonrasi hazir)
  Directory? _pendingDir;
  File? _queueFile;

  // ---------------------------------------------------------------------------
  // BASLANGIC
  // ---------------------------------------------------------------------------
  Future<void> init() async {
    if (_notificationsReady) return;

    // Bildirim altyapisi
    const androidInit = AndroidInitializationSettings('@mipmap/ic_launcher');
    await _notifications.initialize(
      const InitializationSettings(android: androidInit),
    );
    const channel = AndroidNotificationChannel(
      _channelId,
      _channelName,
      description: 'Drone kamerasında alev/duman tespit edildiğinde anlık uyarı',
      importance: Importance.max,
      playSound: true,
      enableVibration: true,
    );
    await _notifications
        .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin>()
        ?.createNotificationChannel(channel);
    _notificationsReady = true;

    // Lokal kuyruk dizinini hazirla
    final appDir = await getApplicationDocumentsDirectory();
    _pendingDir = Directory('${appDir.path}/drone_detections/images')
      ..createSync(recursive: true);
    _queueFile = File('${appDir.path}/drone_detections/pending_queue.json');
    if (!_queueFile!.existsSync()) _queueFile!.writeAsStringSync('[]');

    // ignore: avoid_print
    print('[UPLOAD] init tamamlandi, kuyruk dosyasi: ${_queueFile!.path}');

    // Onceki ucustan kalmis yuklenemeyen gorselleri hemen dene
    await _flushPendingQueue();
  }

  // ---------------------------------------------------------------------------
  // ANA GIRIS NOKTASI
  // ---------------------------------------------------------------------------
  Future<void> reportDetection({
    required FrameAnalysisResult result,
    required Uint8List jpegBytes,
  }) async {
    if (!result.flameDetected || result.detections.isEmpty) return;
    if (_busy) return;

    final now = DateTime.now();
    final last = _lastUploadAt;
    if (last != null && now.difference(last) < _cooldown) return;

    _busy = true;
    _lastUploadAt = now;
    try {
      // 1) Gorsel lokale kaydet + bildirim goster (internet gerekmez)
      final annotatedJpeg = _drawDetections(jpegBytes, result);
      final localFile = await _saveLocalImage(annotatedJpeg, now);

      final sorted = [...result.detections]
        ..sort((a, b) => b.confidence.compareTo(a.confidence));
      final top = sorted.first;
      final labels = sorted.map((d) => d.label).toSet().join(', ');

      await _showLocalNotification(
        count: result.detections.length,
        topLabel: top.label,
        topConfidence: top.confidence,
        detectedAt: now,
      );

      // 2) Firestore yazma (offline-first: SDK kuyruga alir, internet gelince gonder)
      final firestoreRef = await _writeFirestore(
        localImagePath: localFile.path,
        count: result.detections.length,
        topConfidence: top.confidence,
        labels: labels,
        sourceWidth: result.sourceWidth,
        sourceHeight: result.sourceHeight,
        timestamp: now,
      );

      // 3) Storage yukleme dene; basarisiz olursa kuyruga ekle
      await _tryUploadOrEnqueue(
        localFile: localFile,
        firestoreDocId: firestoreRef,
        timestamp: now,
      );
    } catch (e, st) {
      // ignore: avoid_print
      print('[UPLOAD] reportDetection HATA: $e\n$st');
    } finally {
      _busy = false;
    }

    // 4) Bekleyen diger gorselleri yuksek sessize yukle
    unawaited(_flushPendingQueue());
  }

  // ---------------------------------------------------------------------------
  // GORSEL CIZIM
  // ---------------------------------------------------------------------------
  Uint8List _drawDetections(Uint8List jpegBytes, FrameAnalysisResult result) {
    final decoded = img.decodeJpg(jpegBytes);
    if (decoded == null) return jpegBytes;

    final w = decoded.width;
    final h = decoded.height;
    final boxColor = img.ColorRgb8(255, 23, 23);

    for (final d in result.detections) {
      final x1 = (d.left * w).clamp(0, w - 1).round();
      final y1 = (d.top * h).clamp(0, h - 1).round();
      final x2 = (d.right * w).clamp(0, w - 1).round();
      final y2 = (d.bottom * h).clamp(0, h - 1).round();

      img.drawRect(decoded, x1: x1, y1: y1, x2: x2, y2: y2,
          color: boxColor, thickness: 4);
      img.drawString(
        decoded,
        '${d.label} ${(d.confidence * 100).toStringAsFixed(0)}%',
        font: img.arial24,
        x: x1 + 4,
        y: (y1 - 26).clamp(0, h - 1),
        color: boxColor,
      );
    }
    return Uint8List.fromList(img.encodeJpg(decoded, quality: 85));
  }

  // ---------------------------------------------------------------------------
  // LOKAL KAYIT
  // ---------------------------------------------------------------------------
  Future<File> _saveLocalImage(Uint8List bytes, DateTime ts) async {
    final Directory dir;
    if (_pendingDir != null) {
      dir = _pendingDir!;
    } else {
      final appDir = await getApplicationDocumentsDirectory();
      dir = Directory('${appDir.path}/drone_detections/images')
        ..createSync(recursive: true);
    }
    final file = File('${dir.path}/detection_${ts.millisecondsSinceEpoch}.jpg');
    await file.writeAsBytes(bytes);
    // ignore: avoid_print
    print('[UPLOAD] gorsel lokale kaydedildi: ${file.path}');
    return file;
  }

  // ---------------------------------------------------------------------------
  // FIRESTORE YAZMA (offline-first)
  // ---------------------------------------------------------------------------
  Future<String> _writeFirestore({
    required String localImagePath,
    required int count,
    required double topConfidence,
    required String labels,
    required int sourceWidth,
    required int sourceHeight,
    required DateTime timestamp,
  }) async {
    final ref = await FirebaseFirestore.instance.collection('detections').add({
      'timestamp': Timestamp.fromDate(timestamp),
      'detectionCount': count,
      'topConfidence': topConfidence,
      'labels': labels,
      'sourceWidth': sourceWidth,
      'sourceHeight': sourceHeight,
      'imageUrl': null, // Storage yukleme basarili olunca guncellenir
      'localImagePath': localImagePath,
      'uploaded': false,
    });
    // ignore: avoid_print
    print('[UPLOAD] Firestore kaydi olusturuldu (offline ok): ${ref.id}');
    return ref.id;
  }

  // ---------------------------------------------------------------------------
  // STORAGE YUKLEME DENEMESI — basarisizsa kuyruga ekle
  // ---------------------------------------------------------------------------
  Future<void> _tryUploadOrEnqueue({
    required File localFile,
    required String firestoreDocId,
    required DateTime timestamp,
  }) async {
    try {
      final url = await _uploadToStorage(localFile, timestamp);
      // Yukleme basarili: Firestore kaydini guncelle, lokal dosyayi sil
      await FirebaseFirestore.instance
          .collection('detections')
          .doc(firestoreDocId)
          .update({'imageUrl': url, 'uploaded': true});
      await localFile.delete();
      // ignore: avoid_print
      print('[UPLOAD] Storage yuklemesi BASARILI, lokal silindi.');
    } catch (e) {
      // ignore: avoid_print
      print('[UPLOAD] Storage yukleme basarisiz (muhtemelen internet yok): $e');
      _enqueue(localFile.path, firestoreDocId);
    }
  }

  Future<String> _uploadToStorage(File file, DateTime ts) async {
    final fileName = 'detection_${ts.millisecondsSinceEpoch}.jpg';
    final ref = FirebaseStorage.instance.ref('detections/$fileName');
    await ref.putFile(file, SettableMetadata(contentType: 'image/jpeg'));
    return ref.getDownloadURL();
  }

  // ---------------------------------------------------------------------------
  // KUYRUK YONETIMI
  // ---------------------------------------------------------------------------
  void _enqueue(String localPath, String firestoreDocId) {
    try {
      final qf = _queueFile;
      if (qf == null) return;
      final list = _readQueue(qf);
      list.add({'path': localPath, 'docId': firestoreDocId});
      qf.writeAsStringSync(jsonEncode(list));
      // ignore: avoid_print
      print('[UPLOAD] Kuyruga eklendi. Toplam bekleyen: ${list.length}');
    } catch (e) {
      // ignore: avoid_print
      print('[UPLOAD] Kuyruga eklenirken hata: $e');
    }
  }

  Future<void> _flushPendingQueue() async {
    final qf = _queueFile;
    if (qf == null || !qf.existsSync()) return;

    final list = _readQueue(qf);
    if (list.isEmpty) return;

    // ignore: avoid_print
    print('[UPLOAD] Bekleyen ${list.length} gorsel yukleniyor...');
    final remaining = <Map<String, dynamic>>[];

    for (final entry in list) {
      final path = entry['path'] as String? ?? '';
      final docId = entry['docId'] as String? ?? '';
      final file = File(path);
      if (!file.existsSync()) continue; // zaten silinmis, atla

      try {
        final ts = DateTime.fromMillisecondsSinceEpoch(
          int.tryParse(
                  path.split('_').last.replaceAll('.jpg', '')) ??
              DateTime.now().millisecondsSinceEpoch,
        );
        final url = await _uploadToStorage(file, ts);
        if (docId.isNotEmpty) {
          await FirebaseFirestore.instance
              .collection('detections')
              .doc(docId)
              .update({'imageUrl': url, 'uploaded': true});
        }
        await file.delete();
        // ignore: avoid_print
        print('[UPLOAD] Bekleyen gorsel yuklendi: $docId');
      } catch (e) {
        // Hala internet yok, kuyrukta kalmaya devam et
        remaining.add(entry);
        // ignore: avoid_print
        print('[UPLOAD] Bekleyen gorsel HALA yuklenemedi: $e');
      }
    }

    qf.writeAsStringSync(jsonEncode(remaining));
  }

  List<Map<String, dynamic>> _readQueue(File qf) {
    try {
      final raw = jsonDecode(qf.readAsStringSync());
      if (raw is List) return raw.cast<Map<String, dynamic>>();
    } catch (_) {}
    return [];
  }

  // ---------------------------------------------------------------------------
  // BILDIRIM
  // ---------------------------------------------------------------------------
  Future<void> _showLocalNotification({
    required int count,
    required String topLabel,
    required double topConfidence,
    required DateTime detectedAt,
  }) async {
    if (!_notificationsReady) await init();

    String two(int n) => n.toString().padLeft(2, '0');
    final timeStr =
        '${two(detectedAt.hour)}:${two(detectedAt.minute)}:${two(detectedAt.second)}';
    final pct = (topConfidence * 100).toStringAsFixed(0);
    final bodyText = '$count bölge algılandı · $topLabel %$pct güven · $timeStr';

    final androidDetails = AndroidNotificationDetails(
      _channelId,
      _channelName,
      channelDescription: 'Drone kamerasında alev/duman tespit edildiğinde anlık uyarı',
      importance: Importance.max,
      priority: Priority.high,
      color: const Color.fromARGB(255, 211, 47, 47),
      icon: '@mipmap/ic_launcher',
      styleInformation: BigTextStyleInformation(
        bodyText,
        contentTitle: '🔥 ALEV ALGILANDI!',
        summaryText: 'Drone Yangın Algılama',
      ),
      visibility: NotificationVisibility.public,
      timeoutAfter: 8000,
    );

    await _notifications.show(
      DateTime.now().millisecondsSinceEpoch.remainder(100000),
      '🔥 ALEV ALGILANDI!',
      bodyText,
      NotificationDetails(android: androidDetails),
    );
    // ignore: avoid_print
    print('[UPLOAD] Bildirim gosterildi -> $timeStr');
  }
}
