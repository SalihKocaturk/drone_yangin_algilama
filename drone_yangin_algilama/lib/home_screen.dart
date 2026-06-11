import 'package:flutter/material.dart';

import 'services/detection_control.dart';

/// HomeScreen
/// ------------------------------------------------------------------
/// Uygulamanin TEK ekrani: login/auth YOK, dogrudan kontrol arayuzu.
/// Pilotun yapmasi gereken 3 adim:
///   1) "Diger uygulamalarin uzerinde goster" izni ver
///   2) Ekran yakalama (MediaProjection) iznini onayla
///   3) "Erken Uyari Sistemini Baslat" -> foreground service + overlay acilir
///
/// Sistem baslatildiktan sonra bu ekranin acik kalmasina gerek yoktur;
/// kullanici Tello App'e gecebilir, overlay katmani ekranda asili kalir.
/// ------------------------------------------------------------------
class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

enum _ServiceState { idle, requestingPermissions, running }

class _HomeScreenState extends State<HomeScreen> with WidgetsBindingObserver {
  final _control = DetectionControl.instance;

  _ServiceState _state = _ServiceState.idle;
  bool _overlayPermissionGranted = false;
  String? _statusMessage;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _refreshPermissionStatus();
    _refreshServiceStatus();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  // Kullanici sistem ayarlarindan donunce izin durumunu yenile
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _refreshPermissionStatus();
      _refreshServiceStatus();
    }
  }

  Future<void> _refreshPermissionStatus() async {
    final granted = await _control.hasOverlayPermission();
    if (mounted) setState(() => _overlayPermissionGranted = granted);
  }

  /// Ekrana her donuste, gosterilen durumu sistemdeki GERCEK servis durumuyla
  /// senkronlar. Boylece kullanici ornegin overlay iznini sistem ayarlarindan
  /// elle kapatip geri donduğunde ekranda yanlislikla "calisiyor" yazmaz.
  Future<void> _refreshServiceStatus() async {
    final running = await _control.isServiceRunning();
    if (!mounted) return;
    setState(() {
      if (running) {
        _state = _ServiceState.running;
      } else if (_state == _ServiceState.running) {
        // UI "calisiyor" saniyordu ama servis gercekte durmus/durdurulmus.
        _state = _ServiceState.idle;
        _statusMessage = 'Servis sistem tarafindan durduruldu (orn. izin geri alindi). '
            'Devam etmek icin tekrar baslatin.';
      }
    });
  }

  Future<void> _onStartPressed() async {
    setState(() {
      _state = _ServiceState.requestingPermissions;
      _statusMessage = null;
    });

    // 1) Overlay izni
    if (!await _control.hasOverlayPermission()) {
      await _control.requestOverlayPermission();
      await _refreshPermissionStatus();
      if (!_overlayPermissionGranted) {
        setState(() {
          _state = _ServiceState.idle;
          _statusMessage = 'Devam etmek icin "diger uygulamalarin uzerinde goster" iznini vermelisiniz.';
        });
        return;
      }
    }

    // 2) Bildirim izni (Android 13+)
    await _control.ensureNotificationPermission();

    // 3) MediaProjection (ekran yakalama) izni
    final projection = await _control.requestMediaProjection();
    if (!projection.granted) {
      setState(() {
        _state = _ServiceState.idle;
        _statusMessage = 'Ekran yakalama izni verilmedi. Sistem baslatilamadi.';
      });
      return;
    }

    // 4) Foreground service + overlay + canli analiz baslat
    await _control.startDetectionService(projection.resultCode);

    setState(() {
      _state = _ServiceState.running;
      _statusMessage = 'Sistem aktif. Tello App\'e gecebilirsiniz; uyari katmani ekranda kalacaktir.';
    });
  }

  Future<void> _onStopPressed() async {
    await _control.stopDetectionService();
    setState(() {
      _state = _ServiceState.idle;
      _statusMessage = 'Sistem durduruldu.';
    });
  }

  @override
  Widget build(BuildContext context) {
    final running = _state == _ServiceState.running;
    final busy = _state == _ServiceState.requestingPermissions;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Drone Yangin / Alev Erken Uyari'),
        backgroundColor: Colors.red.shade800,
        foregroundColor: Colors.white,
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _StatusCard(running: running),
              const SizedBox(height: 20),
              _PermissionRow(
                label: 'Ekran ustu katman izni',
                granted: _overlayPermissionGranted,
              ),
              const SizedBox(height: 28),
              if (_statusMessage != null) ...[
                Text(
                  _statusMessage!,
                  style: TextStyle(color: Colors.grey.shade700),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 16),
              ],
              SizedBox(
                height: 56,
                child: ElevatedButton.icon(
                  onPressed: busy
                      ? null
                      : (running ? _onStopPressed : _onStartPressed),
                  icon: busy
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                        )
                      : Icon(running ? Icons.stop_circle : Icons.play_circle_fill),
                  label: Text(
                    busy
                        ? 'Izinler kontrol ediliyor...'
                        : (running ? 'Erken Uyari Sistemini Durdur' : 'Erken Uyari Sistemini Baslat'),
                    style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
                  ),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: running ? Colors.grey.shade700 : Colors.red.shade700,
                    foregroundColor: Colors.white,
                  ),
                ),
              ),
              const SizedBox(height: 24),
              const _InfoBox(),
            ],
          ),
        ),
      ),
    );
  }
}

class _StatusCard extends StatelessWidget {
  final bool running;
  const _StatusCard({required this.running});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: running ? Colors.green.shade50 : Colors.grey.shade100,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: running ? Colors.green.shade300 : Colors.grey.shade300),
      ),
      child: Row(
        children: [
          Icon(
            running ? Icons.visibility : Icons.visibility_off,
            color: running ? Colors.green.shade700 : Colors.grey.shade500,
            size: 32,
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  running ? 'Canli analiz CALISIYOR' : 'Sistem beklemede',
                  style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                ),
                Text(
                  running
                      ? 'Saniyede ~3 kare yakalaniyor ve PyTorch modeline besleniyor.'
                      : 'Baslatmak icin asagidaki butona dokunun.',
                  style: TextStyle(color: Colors.grey.shade600, fontSize: 13),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _PermissionRow extends StatelessWidget {
  final String label;
  final bool granted;
  const _PermissionRow({required this.label, required this.granted});

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Icon(
          granted ? Icons.check_circle : Icons.error_outline,
          color: granted ? Colors.green : Colors.orange,
          size: 20,
        ),
        const SizedBox(width: 8),
        Text(label),
        const Spacer(),
        Text(
          granted ? 'Verildi' : 'Gerekli',
          style: TextStyle(color: granted ? Colors.green : Colors.orange, fontWeight: FontWeight.w600),
        ),
      ],
    );
  }
}

class _InfoBox extends StatelessWidget {
  const _InfoBox();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Colors.blue.shade50,
        borderRadius: BorderRadius.circular(12),
      ),
      child: const Text(
        'Nasil calisir?\n'
        '1) Telefonu Tello drone Wi-Fi agina baglayin ve Tello App / Tello FPV uygulamasini acin.\n'
        '2) Bu uygulamada "Baslat" deyip izinleri onaylayin.\n'
        '3) Tello App\'e gecin: seffaf uyari katmani ekranda kalmaya devam eder ve '
        'dokunuslariniza karismaz; alev algilanirsa ust kisimda kirmizi uyari ve '
        'bolge etrafinda cerceve belirir.',
        style: TextStyle(fontSize: 12.5, height: 1.4),
      ),
    );
  }
}
