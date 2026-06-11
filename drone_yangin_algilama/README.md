# Drone Yangın / Alev Erken Uyarı Sistemi

DJI Tello drone ile uçuş sırasında gerçek zamanlı alev ve duman tespiti yapan, tespitleri Firebase'e kaydeden ve anlık bildirim gönderen Android + NodeMCU tabanlı prototip sistem.

---

## Sistem Mimarisi

```
┌─────────────────────┐     Wi-Fi (lokal)     ┌─────────────────────┐
│   DJI Tello Drone   │ ──────────────────── │   Android Telefon   │
│  (FPV kamera akışı) │                       │   Flutter Uygulaması│
└─────────────────────┘                       │   + PyTorch YOLOv8  │
                                              └────────┬────────────┘
                                                       │ internet (mobil veri)
                                              ┌────────▼────────────┐
┌─────────────────────┐     Wi-Fi (internet)  │   Firebase          │
│   NodeMCU V3        │ ──────────────────── │   • Firestore DB    │
│   Alev Sensörü      │                       │   • Storage         │
└─────────────────────┘                       └─────────────────────┘
```

**Android uygulaması:**
<img width="392" height="850" alt="ezgif-10308e3b0fa844cd" src="https://github.com/user-attachments/assets/7a94ae30-fde8-4a8d-b8bb-a8c67b369b02" />

- Tello'nun kamera görüntüsünü MediaProjection ile yakalar
- YOLOv8 TorchScript modelini cihaz üzerinde çalıştırır (on-device inference)
- Alev/duman tespitinde kare üzerine bounding box çizer ve Firebase Storage'a yükler
- Firestore'a tespit kaydı (zaman, güven skoru, sınıf, görsel URL) düşer
- Anlık yerel bildirim gönderir
- Tello Wi-Fi'da internet olmadığından tespitler önce lokale kaydedilir, internet gelince otomatik senkronize edilir

**NodeMCU V3:**
- Fiziksel alev sensörü (dijital çıkış, D1/GPIO5) okur
- Sensör tetiklendiğinde Firestore'a zaman damgalı tehlike kaydı gönderir

---

## Kurulum

### 1. Firebase Projesi

1. [Firebase Console](https://console.firebase.google.com)'da yeni proje oluştur
2. Android uygulaması ekle — package: `com.example.drone_yangin_algilama`
3. `google-services.json` dosyasını `android/app/` klasörüne koy
4. Firestore Database → test modunda oluştur
5. Storage → test modunda oluştur

> ⚠️ `google-services.json` **kesinlikle** Git'e commit edilmemeli (`.gitignore`'a ekli).

### 2. Flutter Uygulaması

```bash
flutter pub get
flutter run --release
```

**Gerekli izinler (otomatik istenir):**
- Ekran üstünde göster (SYSTEM_ALERT_WINDOW)
- Ekran yakalama (MediaProjection)
- Bildirim gönderme (Android 13+)

### 3. YOLOv8 Modeli

Modeli Google Colab'da dışa aktar:

```python
from ultralytics import YOLO
yolo = YOLO("best.pt")
yolo.export(format="torchscript", imgsz=640, optimize=True)
```

Oluşan `best.torchscript` dosyasını `assets/model.pt` olarak kaydet.

> Model dosyası büyük olduğundan Git'e eklenmez. Git LFS kullanılabilir.

### 4. NodeMCU Kurulumu

**Arduino IDE'de gerekli kütüphaneler:**
- `NTPClient` (Fabrice Weinberg)
- `ArduinoJson` (Benoit Blanchon — v6)

`nodemcu_firebase/nodemcu_firebase.ino` dosyasını açıp şu sabitleri doldur:

```cpp
#define WIFI_SSID     "WIFI_ADINIZ"
#define WIFI_PASSWORD "WIFI_SIFRENIZ"
#define API_KEY       "FIREBASE_WEB_API_KEY"   // Firebase Console > Proje Ayarları > Web API Anahtarı
#define PROJECT_ID    "FIREBASE_PROJE_ID"       // Firebase Console > Proje Ayarları > Proje Kimliği
```

> ⚠️ `.ino` dosyası `.gitignore`'a eklidir — WiFi şifresi ve API key repo'ya gitmez.

**Devre bağlantısı:**

```
Alev Sensörü DO  →  NodeMCU D1 (GPIO5)
Alev Sensörü GND →  NodeMCU GND
Alev Sensörü VCC →  NodeMCU 3.3V
```

---

## Uygulama Ekranları
<img width="392" height="850" alt="ezgif-10308e3b0fa844cd" src="https://github.com/user-attachments/assets/7a94ae30-fde8-4a8d-b8bb-a8c67b369b02" />

| Sekme | İçerik |
|-------|--------|
| **Kontrol** | Sistemi başlat / durdur, izin durumu |
| **Tespitler** | Kamera tespitleri — bounding box'lı görsel, güven skoru, zaman |
| **Tehlikeler** | NodeMCU sensör uyarıları — zaman damgalı tehlike listesi |

---

## Teknik Notlar

- **Offline-first:** Tello Wi-Fi'ında internet olmadığından tespitler önce cihaza kaydedilir; normal ağa geçince Firebase'e otomatik yüklenir
- **Cooldown:** Aynı tespit için en az 12 sn (kamera) / 15 sn (NodeMCU) arayla kayıt gönderilir
- **Model:** YOLOv8, `fire` ve `smoke` sınıfları — güven eşiği: %45
- **R8/ProGuard:** PyTorch Lite uyumluluğu için release buildde `isMinifyEnabled = false`

---

## Güvenlik Uyarısı

Bu proje bir **prototip**tir. Firestore ve Storage test modundadır (herkese açık okuma/yazma). Üretim ortamına geçmeden önce:

- Firestore güvenlik kurallarını sıkılaştır
- Firebase Authentication ekle
- Storage kurallarını yalnızca kimliği doğrulanmış kullanıcılarla sınırla
