package com.example.drone_yangin_algilama

import android.app.Activity
import android.content.Intent
import android.media.projection.MediaProjectionManager
import android.net.Uri
import android.os.Build
import android.provider.Settings
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/**
 * MainActivity: SADECE kontrol/izin akislarindan sorumludur (login/auth YOK,
 * dogrudan ana kontrol arayuzu acilir).
 *
 * Gorevleri:
 *  - "Diger uygulamalarin uzerinde goster" (overlay) izni isteme
 *  - MediaProjection (ekran yakalama) izin dialogunu tetikleme
 *  - OverlayDetectionService'i baslatma / durdurma
 *
 * Asil canli yakalama + overlay cizimi OverlayDetectionService icinde, ayri bir
 * FlutterEngine + WindowManager katmaninda calisir; boylece MainActivity kapansa
 * veya kullanici Tello App'e gecse bile katman ekranda kalmaya devam eder.
 */
class MainActivity : FlutterActivity() {

    companion object {
        private const val CONTROL_CHANNEL = "drone_yangin/control"
        private const val MEDIA_PROJECTION_REQUEST_CODE = 4242
    }

    private var pendingProjectionResult: MethodChannel.Result? = null
    private var cachedProjectionData: Intent? = null
    private lateinit var mediaProjectionManager: MediaProjectionManager

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        mediaProjectionManager =
            getSystemService(android.content.Context.MEDIA_PROJECTION_SERVICE) as MediaProjectionManager

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CONTROL_CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {

                    // 1) "Diger uygulamalarin uzerinde goster" izni var mi?
                    "hasOverlayPermission" -> result.success(Settings.canDrawOverlays(this))

                    // Servis GERCEKTEN calisiyor mu? (UI'nin kendi hafizasindaki bayraga
                    // degil, sistemin gercek durumuna gore senkron kalmasi icin).
                    // Onemli: kullanici "Diger uygulamalarin uzerinde goster" iznini
                    // sistem ayarlarindan elle kapatirsa Android servisi OTOMATIK
                    // DURDURMAZ; servis arka planda calismaya devam edebilir ama
                    // overlay penceresi artik cizilemez. Bu yuzden gercek durumu
                    // ActivityManager uzerinden soruyoruz.
                    "isServiceRunning" -> {
                        val am = getSystemService(android.app.ActivityManager::class.java)
                        val running = am?.getRunningServices(Int.MAX_VALUE)?.any {
                            it.service.className == OverlayDetectionService::class.java.name
                        } ?: false
                        result.success(running)
                    }

                    // 2) Kullaniciyi sistem ayar ekranina yonlendirip izni iste
                    "requestOverlayPermission" -> {
                        if (!Settings.canDrawOverlays(this)) {
                            startActivity(
                                Intent(
                                    Settings.ACTION_MANAGE_OVERLAY_PERMISSION,
                                    Uri.parse("package:$packageName")
                                )
                            )
                        }
                        result.success(null)
                    }

                    // 3) MediaProjection izin dialogunu tetikle ("Baslat / Start now")
                    "requestMediaProjection" -> {
                        pendingProjectionResult = result

                        // KRITIK: Android 14+ (UPSIDE_DOWN_CAKE) izin dialogunda kullaniciya
                        // "Tek bir uygulama" / "Tum ekran" secimi sunar. "Tek bir uygulama"
                        // secilirse (veya sistem oyle davranirsa), kullanici Tello App'e
                        // GECER GECMEZ Android projeksiyonu OTOMATIK DURDURUR (cunku izin
                        // verilen uygulama artik on planda degil) -> onStop() tetiklenir ->
                        // servis cokup yeniden baslar -> "Model yukleniyor" sonsuz dongusu.
                        //
                        // Cozum: MediaProjectionConfig.createConfigForDefaultDisplay() ile
                        // "tum ekran" yakalamayi PROGRAMATIK olarak zorluyoruz; boylece secim
                        // ekrani atlanir ve projeksiyon, hangi uygulamaya gecilirse gecilsin
                        // calismaya devam eder (Tello App ustunde calismamiz gerektigi
                        // icin tam da bize lazim olan davranis budur).
                        val captureIntent =
                            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
                                mediaProjectionManager.createScreenCaptureIntent(
                                    android.media.projection.MediaProjectionConfig
                                        .createConfigForDefaultDisplay()
                                )
                            } else {
                                mediaProjectionManager.createScreenCaptureIntent()
                            }

                        startActivityForResult(captureIntent, MEDIA_PROJECTION_REQUEST_CODE)
                    }

                    // 4) Servisi baslat: izin sonucu (resultCode + data Intent) servise tasinir;
                    //    MediaProjection servis icinde bu veriyle yeniden olusturulur.
                    "startDetectionService" -> {
                        val resultCode = call.argument<Int>("resultCode") ?: Activity.RESULT_CANCELED
                        val intent = Intent(this, OverlayDetectionService::class.java).apply {
                            action = OverlayDetectionService.ACTION_START
                            putExtra(OverlayDetectionService.EXTRA_RESULT_CODE, resultCode)
                            putExtra(OverlayDetectionService.EXTRA_RESULT_DATA, cachedProjectionData)
                        }
                        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                            startForegroundService(intent)
                        } else {
                            startService(intent)
                        }
                        result.success(null)
                    }

                    "stopDetectionService" -> {
                        startService(
                            Intent(this, OverlayDetectionService::class.java).apply {
                                action = OverlayDetectionService.ACTION_STOP
                            }
                        )
                        result.success(null)
                    }

                    else -> result.notImplemented()
                }
            }
    }

    @Deprecated("Deprecated in Java, but onActivityResult API >=21 icin hala gecerli")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode == MEDIA_PROJECTION_REQUEST_CODE) {
            cachedProjectionData = data
            pendingProjectionResult?.success(
                mapOf(
                    "granted" to (resultCode == Activity.RESULT_OK && data != null),
                    "resultCode" to resultCode
                )
            )
            pendingProjectionResult = null
        }
    }
}
