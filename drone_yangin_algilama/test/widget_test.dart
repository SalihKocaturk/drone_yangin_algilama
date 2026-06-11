// Bu projenin temel "smoke test"i.
//
// Eski sablon, varsayilan sayac (counter) arayuzunu test ediyordu ("0", "+"
// butonu vb.). Biz ana ekrani HomeScreen ile degistirdigimiz icin o widget'lar
// artik mevcut degil; test bu yuzden basarisiz oluyordu. Asagida, gercek
// uygulamamizin ana ekranini dogrulayan guncel bir test var.

import 'package:drone_yangin_algilama/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('Ana ekran login olmadan dogrudan kontrol arayuzunu gosterir', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(const DroneFireApp());
    await tester.pumpAndSettle();

    // Login/auth ekrani YOK: dogrudan ana kontrol arayuzu gorunmeli.
    expect(find.text('Drone Yangin / Alev Erken Uyari'), findsOneWidget);

    // "Sistemi baslat" butonu ekranda olmali.
    expect(find.text('Erken Uyari Sistemini Baslat'), findsOneWidget);

    // Sayac (counter) UI'si artik yok.
    expect(find.byIcon(Icons.add), findsNothing);
  });
}
