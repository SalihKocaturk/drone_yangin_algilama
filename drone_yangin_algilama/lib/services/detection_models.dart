/// Modelden donen tek bir alev tespitini temsil eder.
/// Koordinatlar 0.0 - 1.0 arasinda NORMALIZE edilmis olarak tutulur
/// (genislik/yukseklik ile carpilarak ekran piksellerine cevrilir).
class FlameDetection {
  final double left;
  final double top;
  final double right;
  final double bottom;
  final double confidence;
  final String label;

  const FlameDetection({
    required this.left,
    required this.top,
    required this.right,
    required this.bottom,
    required this.confidence,
    this.label = 'alev',
  });

  double get width => right - left;
  double get height => bottom - top;
}

/// Tek bir karenin (frame) model tarafindan islenmis sonucu.
class FrameAnalysisResult {
  final bool flameDetected;
  final List<FlameDetection> detections;
  final int sourceWidth;
  final int sourceHeight;
  final int timestampMs;

  const FrameAnalysisResult({
    required this.flameDetected,
    required this.detections,
    required this.sourceWidth,
    required this.sourceHeight,
    required this.timestampMs,
  });

  factory FrameAnalysisResult.empty(int w, int h, int ts) => FrameAnalysisResult(
        flameDetected: false,
        detections: const [],
        sourceWidth: w,
        sourceHeight: h,
        timestampMs: ts,
      );
}
