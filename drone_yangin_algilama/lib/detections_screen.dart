import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';

/// DetectionsScreen
/// ------------------------------------------------------------------
/// Firestore'daki "detections" koleksiyonunu CANLI dinler (StreamBuilder)
/// ve her kaydi -- isaretlenmis (kutu cizilmis) gorsel + zaman + sinif +
/// guven skoru ile -- bir liste halinde gosterir. DetectionUploader
/// servisi her tespitte buraya yeni bir dokuman ekler; bu ekran herhangi
/// bir yenileme islemi gerekmeden anlik olarak guncellenir.
/// ------------------------------------------------------------------
class DetectionsScreen extends StatelessWidget {
  const DetectionsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final stream = FirebaseFirestore.instance
        .collection('detections')
        .orderBy('timestamp', descending: true)
        .limit(100)
        .snapshots();

    return Scaffold(
      appBar: AppBar(
        title: const Text('Tespit Gecmisi'),
        backgroundColor: Colors.red.shade800,
        foregroundColor: Colors.white,
      ),
      body: StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
        stream: stream,
        builder: (context, snapshot) {
          if (snapshot.hasError) {
            return Center(
              child: Padding(
                padding: const EdgeInsets.all(20),
                child: Text(
                  'Veriler alinamadi:\n${snapshot.error}',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: Colors.red.shade700),
                ),
              ),
            );
          }
          if (!snapshot.hasData) {
            return const Center(child: CircularProgressIndicator());
          }

          final docs = snapshot.data!.docs;
          if (docs.isEmpty) {
            return Center(
              child: Padding(
                padding: const EdgeInsets.all(20),
                child: Text(
                  'Henuz kayitli tespit yok.\n'
                  'Sistem calisirken alev/duman algilandiginda kayitlar burada anlik olarak gorunecek.',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: Colors.grey.shade600),
                ),
              ),
            );
          }

          return ListView.separated(
            padding: const EdgeInsets.all(12),
            itemCount: docs.length,
            separatorBuilder: (_, __) => const SizedBox(height: 10),
            itemBuilder: (context, index) {
              final data = docs[index].data();
              return _DetectionCard(data: data);
            },
          );
        },
      ),
    );
  }
}

class _DetectionCard extends StatelessWidget {
  final Map<String, dynamic> data;
  const _DetectionCard({required this.data});

  @override
  Widget build(BuildContext context) {
    final imageUrl = data['imageUrl'] as String?;
    final ts = data['timestamp'];
    final DateTime? dateTime = ts is Timestamp ? ts.toDate() : null;
    final count = data['detectionCount'] ?? 0;
    final labels = data['labels'] as String? ?? '';
    final topConfidence = (data['topConfidence'] as num?)?.toDouble() ?? 0.0;

    return Material(
      color: Colors.white,
      borderRadius: BorderRadius.circular(14),
      clipBehavior: Clip.antiAlias,
      elevation: 1,
      child: InkWell(
        onTap: imageUrl == null ? null : () => _openFullImage(context, imageUrl),
        child: Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: Colors.grey.shade300),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (imageUrl != null)
            AspectRatio(
              aspectRatio: 16 / 9,
              child: Image.network(
                imageUrl,
                fit: BoxFit.cover,
                loadingBuilder: (context, child, progress) {
                  if (progress == null) return child;
                  return const Center(child: CircularProgressIndicator(strokeWidth: 2));
                },
                errorBuilder: (context, error, stack) => Container(
                  color: Colors.grey.shade200,
                  alignment: Alignment.center,
                  child: const Icon(Icons.broken_image, color: Colors.grey),
                ),
              ),
            ),
          Padding(
            padding: const EdgeInsets.all(12),
            child: Row(
              children: [
                Icon(Icons.local_fire_department, color: Colors.red.shade700),
                const SizedBox(width: 8),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'ALEV ALGILANDI! ($count bölge)',
                        style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 15),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        '${labels.isEmpty ? "?" : labels} · en yüksek güven: '
                        '${(topConfidence * 100).toStringAsFixed(0)}%',
                        style: TextStyle(color: Colors.grey.shade700, fontSize: 12.5),
                      ),
                      if (dateTime != null)
                        Text(
                          _formatDateTime(dateTime),
                          style: TextStyle(color: Colors.grey.shade500, fontSize: 11.5),
                        ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    ),
      ),
    );
  }

  String _formatDateTime(DateTime dt) {
    String two(int n) => n.toString().padLeft(2, '0');
    return '${two(dt.day)}.${two(dt.month)}.${dt.year}  ${two(dt.hour)}:${two(dt.minute)}:${two(dt.second)}';
  }

  void _openFullImage(BuildContext context, String imageUrl) {
    Navigator.of(context).push(
      MaterialPageRoute(
        fullscreenDialog: true,
        builder: (_) => _FullImageViewer(imageUrl: imageUrl),
      ),
    );
  }
}

/// Karta dokunulunca acilan, yakinlastirma/kaydirma destekli (InteractiveViewer)
/// tam ekran gorsel goruntuleyici. Kapatmak icin sag ustteki X veya geri tusu.
class _FullImageViewer extends StatelessWidget {
  final String imageUrl;
  const _FullImageViewer({required this.imageUrl});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        iconTheme: const IconThemeData(color: Colors.white),
        title: const Text('Tespit Görseli'),
      ),
      body: Center(
        child: InteractiveViewer(
          minScale: 0.5,
          maxScale: 5,
          child: Image.network(
            imageUrl,
            fit: BoxFit.contain,
            loadingBuilder: (context, child, progress) {
              if (progress == null) return child;
              return const CircularProgressIndicator(color: Colors.white);
            },
            errorBuilder: (context, error, stack) => const Icon(
              Icons.broken_image,
              color: Colors.white54,
              size: 64,
            ),
          ),
        ),
      ),
    );
  }
}
