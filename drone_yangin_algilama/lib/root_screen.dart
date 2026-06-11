import 'package:flutter/material.dart';

import 'alerts_screen.dart';
import 'detections_screen.dart';
import 'home_screen.dart';

/// RootScreen
/// ------------------------------------------------------------------
/// Alt sekme cubugu (BottomNavigationBar) ile iki ekran arasinda gecis:
///   1) "Kontrol"   -> HomeScreen (sistemi baslat/durdur)
///   2) "Tespitler" -> DetectionsScreen (Firebase'e dusen kayitlarin
///                     CANLI listesi: isaretlenmis gorsel + zaman + skor)
/// IndexedStack kullanilir; boylece sekmeler arasi gecince Firestore
/// stream'i sifirdan kurulmaz, ekran durumu korunur.
/// ------------------------------------------------------------------
class RootScreen extends StatefulWidget {
  const RootScreen({super.key});

  @override
  State<RootScreen> createState() => _RootScreenState();
}

class _RootScreenState extends State<RootScreen> {
  int _index = 0;

  static const _screens = [
    HomeScreen(),
    DetectionsScreen(),
    AlertsScreen(),
  ];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: IndexedStack(index: _index, children: _screens),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _index,
        onDestinationSelected: (i) => setState(() => _index = i),
        destinations: const [
          NavigationDestination(icon: Icon(Icons.dashboard_outlined), selectedIcon: Icon(Icons.dashboard), label: 'Kontrol'),
          NavigationDestination(icon: Icon(Icons.local_fire_department_outlined), selectedIcon: Icon(Icons.local_fire_department), label: 'Tespitler'),
          NavigationDestination(icon: Icon(Icons.warning_amber_outlined), selectedIcon: Icon(Icons.warning_amber_rounded), label: 'Tehlikeler'),
        ],
      ),
    );
  }
}
