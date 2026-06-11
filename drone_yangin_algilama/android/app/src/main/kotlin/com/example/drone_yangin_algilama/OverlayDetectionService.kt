package com.example.drone_yangin_algilama

import android.app.*
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.graphics.PixelFormat
import android.hardware.display.DisplayManager
import android.hardware.display.VirtualDisplay
import android.media.Image
import android.media.ImageReader
import android.media.projection.MediaProjection
import android.media.projection.MediaProjectionManager
import android.os.*
import android.util.DisplayMetrics
import android.view.Gravity
import android.view.WindowManager
import androidx.core.app.NotificationCompat
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.dart.DartExecutor
import io.flutter.embedding.engine.loader.FlutterLoader
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel
import java.io.ByteArrayOutputStream
import java.nio.ByteBuffer

/**
 * OverlayDetectionService
 * ------------------------------------------------------------------
 * 1) FOREGROUND SERVICE: Android'in uygulamayi arka planda oldurmemesi icin
 *    surekli bir bildirimle on planda kalir (foregroundServiceType=mediaProjection).
 *
 * 2) OVERLAY WINDOW: TYPE_APPLICATION_OVERLAY + FLAG_NOT_FOCUSABLE | FLAG_NOT_TOUCHABLE
 *    ile ekranin en ustunde, click-through (dokunmatigi engellemeyen), seffaf bir
 *    katman olusturur. Icinde ayri bir FlutterEngine + FlutterView host edilir;
 *    bu engine "overlayMain" adli ikinci bir Dart entry point'i calistirir
 *    (bkz. lib/main.dart -> @pragma('vm:entry-point') overlayMain).
 *
 * 3) MEDIAPROJECTION: VirtualDisplay + ImageReader ile canli ekran goruntusu
 *    yakalanir. Performans icin saniyede ~3 kareye dusurulur (frame skipping),
 *    JPEG'e sikistirilir ve EventChannel ile Flutter (overlay) tarafina akitilir.
 *    Flutter tarafi PyTorch modelini calistirip sonucu ayni katman uzerinde cizer.
 * ------------------------------------------------------------------
 */
class OverlayDetectionService : Service() {

    companion object {
        const val ACTION_START = "ACTION_START"
        const val ACTION_STOP = "ACTION_STOP"
        const val EXTRA_RESULT_CODE = "EXTRA_RESULT_CODE"
        const val EXTRA_RESULT_DATA = "EXTRA_RESULT_DATA"

        private const val NOTIFICATION_CHANNEL_ID = "drone_yangin_channel"
        private const val NOTIFICATION_ID = 1001

        // Frame skipping: ~3 FPS yeterli (alev tespiti icin yuksek FPS gereksiz,
        // CPU/GPU/pil tuketimini ciddi sekilde azaltir).
        private const val TARGET_FPS = 3
        private const val FRAME_INTERVAL_MS = 1000L / TARGET_FPS

        // Flutter'daki ikinci giris noktasinin adi (bkz. lib/main.dart):
        // @pragma('vm:entry-point')
        // void overlayMain() { ... }
        private const val OVERLAY_ENTRYPOINT = "overlayMain"
        private const val OVERLAY_FRAME_CHANNEL = "drone_yangin/frames"
    }

    private lateinit var windowManager: WindowManager
    private var overlayFlutterEngine: FlutterEngine? = null
    private var overlayView: io.flutter.embedding.android.FlutterView? = null
    private var frameEventSink: EventChannel.EventSink? = null

    private var mediaProjection: MediaProjection? = null
    private var virtualDisplay: VirtualDisplay? = null
    private var imageReader: ImageReader? = null

    private val mainHandler = Handler(Looper.getMainLooper())
    private val backgroundThread = HandlerThread("FrameCaptureThread").apply { start() }
    private val backgroundHandler = Handler(backgroundThread.looper)

    private var lastFrameTimestamp = 0L
    private var screenDensity = 0
    private var screenWidth = 0
    private var screenHeight = 0

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        windowManager = getSystemService(Context.WINDOW_SERVICE) as WindowManager
        createNotificationChannel()
        readScreenMetrics()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_START -> {
                startForeground(NOTIFICATION_ID, buildNotification())
                val resultCode = intent.getIntExtra(EXTRA_RESULT_CODE, Activity_RESULT_CANCELED())
                val data: Intent? = intent.getParcelableExtra(EXTRA_RESULT_DATA)
                if (resultCode == Activity_RESULT_OK() && data != null) {
                    startProjection(resultCode, data)
                    showOverlayWindow()
                } else {
                    stopSelf()
                }
            }
            ACTION_STOP -> {
                stopEverything()
            }
        }
        return START_STICKY // Sistem servisi kapatirsa yeniden baslatmaya calisir
    }

    override fun onDestroy() {
        stopEverything()
        backgroundThread.quitSafely()
        super.onDestroy()
    }

    // Activity.RESULT_OK / RESULT_CANCELED sabitlerine servis icinden erismek icin kucuk yardimcilar
    private fun Activity_RESULT_OK() = Activity.RESULT_OK
    private fun Activity_RESULT_CANCELED() = Activity.RESULT_CANCELED

    // ============================================================================================
    // 1) FOREGROUND SERVICE BILDIRIMI
    // ============================================================================================

    private fun createNotificationChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel(
                NOTIFICATION_CHANNEL_ID,
                "Alev Algilama Servisi",
                NotificationManager.IMPORTANCE_LOW
            ).apply {
                description = "Arka planda canli goruntu analizi calisiyor"
                setShowBadge(false)
            }
            val nm = getSystemService(NotificationManager::class.java)
            nm.createNotificationChannel(channel)
        }
    }

    private fun buildNotification(): Notification {
        val stopIntent = Intent(this, OverlayDetectionService::class.java).apply { action = ACTION_STOP }
        val stopPending = PendingIntent.getService(
            this, 0, stopIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )
        return NotificationCompat.Builder(this, NOTIFICATION_CHANNEL_ID)
            .setContentTitle("Erken Uyari Sistemi Aktif")
            .setContentText("Drone goruntusu canli olarak analiz ediliyor (alev algilama)")
            .setSmallIcon(android.R.drawable.ic_menu_view)
            .setOngoing(true)
            .addAction(android.R.drawable.ic_menu_close_clear_cancel, "Durdur", stopPending)
            .build()
    }

    // ============================================================================================
    // 2) OVERLAY WINDOW (seffaf, click-through, non-focusable katman + ayri FlutterEngine)
    // ============================================================================================

    private fun readScreenMetrics() {
        val dm = DisplayMetrics()
        windowManager.defaultDisplay.getRealMetrics(dm)
        screenWidth = dm.widthPixels
        screenHeight = dm.heightPixels
        screenDensity = dm.densityDpi
    }

    private fun showOverlayWindow() {
        if (overlayView != null) return // zaten gosteriliyor

        // --- Ayri bir FlutterEngine olustur ve "overlayMain" giris noktasini calistir ---
        val loader = FlutterLoader()
        loader.startInitialization(applicationContext)
        loader.ensureInitializationCompleteAsync(applicationContext, null, mainHandler) {
            val engine = FlutterEngine(applicationContext)
            overlayFlutterEngine = engine

            // "overlayMain" Dart giris noktasini calistir (bkz. lib/main.dart):
            //   @pragma('vm:entry-point')
            //   void overlayMain() { ... }
            // DartEntrypoint, uygulamanin app bundle yolunu + entrypoint fonksiyon adini
            // kullanarak ayri/izole bir Dart izolatini bu FlutterEngine icinde baslatir.
            val entrypoint = DartExecutor.DartEntrypoint(
                loader.findAppBundlePath(),
                OVERLAY_ENTRYPOINT
            )
            engine.dartExecutor.executeDartEntrypoint(entrypoint)

            // Flutter (overlay) <-> Native frame kosusu icin EventChannel
            EventChannel(engine.dartExecutor.binaryMessenger, OVERLAY_FRAME_CHANNEL)
                .setStreamHandler(object : EventChannel.StreamHandler {
                    override fun onListen(args: Any?, sink: EventChannel.EventSink?) {
                        frameEventSink = sink
                    }
                    override fun onCancel(args: Any?) {
                        frameEventSink = null
                    }
                })

            // Overlay'in kendisini kapatmasi icin (orn. "Durdur" butonuna basinca)
            MethodChannel(engine.dartExecutor.binaryMessenger, "drone_yangin/overlay_control")
                .setMethodCallHandler { call, result ->
                    when (call.method) {
                        "stopService" -> {
                            stopEverything()
                            result.success(null)
                        }
                        else -> result.notImplemented()
                    }
                }

            attachFlutterViewToWindow(engine)
        }
    }

    private fun attachFlutterViewToWindow(engine: FlutterEngine) {
        // *** KRITIK FIX: SurfaceView yerine TextureView ile render et ***
        // Varsayilan FlutterView (ozellikle Impeller/Vulkan backend ile) kendi
        // bagimsiz android.view.SurfaceView'ini olusturur. SurfaceView, normal
        // view hiyerarsisinin DISINDA ayri bir Surface/pencere katmanidir ve
        // Android, ust pencerenin FLAG_NOT_TOUCHABLE / FLAG_NOT_FOCUSABLE
        // bayraklarindan BAGIMSIZ olarak dokunuslari yakalayabilir
        // ("...SurfaceView... Android'in en son surumune gore optimize edilmemis.
        // Ekran dokunuslari gecikebilir veya algilanmayabilir." sistem uyarisi
        // tam da bunu soyluyordu - ekranin "kilitlenmis" gibi davranmasinin sebebi buydu).
        //
        // FlutterTextureView ise normal View hiyerarsisi icinde composite edilen
        // bir TextureView kullanir; bagimsiz bir Surface/pencere katmani OLMADIGI
        // icin dokunuslar dogrudan parent pencerenin (overlay'in) bayraklarina
        // tabi olur ve click-through duzgun calisir.
        val textureView = io.flutter.embedding.android.FlutterTextureView(applicationContext)
        val flutterView = io.flutter.embedding.android.FlutterView(applicationContext, textureView)
        flutterView.attachToFlutterEngine(engine)
        overlayView = flutterView

        val overlayType = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O)
            WindowManager.LayoutParams.TYPE_APPLICATION_OVERLAY
        else
            @Suppress("DEPRECATION") WindowManager.LayoutParams.TYPE_PHONE

        // *** EN KRITIK KISIM: click-through / non-focusable overlay ***
        // FLAG_NOT_FOCUSABLE  -> klavye/giris odagini ALMAZ (alttaki Tello App etkilenmez)
        // FLAG_NOT_TOUCHABLE  -> dokunma olaylarini YAKALAMAZ, doğrudan alttaki uygulamaya iletilir
        // FLAG_LAYOUT_IN_SCREEN / LAYOUT_NO_LIMITS -> tam ekran, status bar uzerinde de cizim
        // FLAG_HARDWARE_ACCELERATED -> akici overlay render
        val params = WindowManager.LayoutParams(
            WindowManager.LayoutParams.MATCH_PARENT,
            WindowManager.LayoutParams.MATCH_PARENT,
            overlayType,
            WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE or
                WindowManager.LayoutParams.FLAG_NOT_TOUCHABLE or
                WindowManager.LayoutParams.FLAG_LAYOUT_IN_SCREEN or
                WindowManager.LayoutParams.FLAG_LAYOUT_NO_LIMITS or
                WindowManager.LayoutParams.FLAG_HARDWARE_ACCELERATED or
                WindowManager.LayoutParams.FLAG_WATCH_OUTSIDE_TOUCH,
            PixelFormat.TRANSLUCENT // seffaf arka plan
        ).apply {
            gravity = Gravity.TOP or Gravity.START
            x = 0
            y = 0
        }

        windowManager.addView(flutterView, params)
    }

    // ============================================================================================
    // 3) MEDIAPROJECTION: canli ekran yakalama (frame skipping ile ~3 FPS)
    // ============================================================================================

    private fun startProjection(resultCode: Int, data: Intent) {
        val projectionManager =
            getSystemService(Context.MEDIA_PROJECTION_SERVICE) as MediaProjectionManager
        mediaProjection = projectionManager.getMediaProjection(resultCode, data)

        // Kayit sirasinda sistemin gosterecegi zorunlu callback (Android 14+ icin de gerekli)
        // ONEMLI: Bu callback "backgroundHandler" (FrameCaptureThread) uzerinde tetiklenir.
        // stopEverything() ise FlutterView.detachFromFlutterEngine() ve WindowManager
        // islemleri icerir; bunlar @UiThread olarak isaretlidir ve SADECE ana thread'den
        // cagrilabilir. Arka plan thread'inden dogrudan cagirmak
        // "Methods marked with @UiThread must be executed on the main thread" crash'ine
        // (ve servisin surekli yeniden baslayip "Model yukleniyor"da takili kalmasina) yol aciyordu.
        // Cozum: temizligi mainHandler (ana/UI thread Looper'i) uzerinden calistir.
        mediaProjection?.registerCallback(object : MediaProjection.Callback() {
            override fun onStop() {
                mainHandler.post { stopEverything() }
            }
        }, backgroundHandler)

        // ImageReader: ekran ciktisini RGBA_8888 formatinda kareler halinde alir.
        // maxImages=2 -> bellek tuketimini sinirli tutar (en guncel kareyi isleriz, eskileri ataris).
        imageReader = ImageReader.newInstance(
            screenWidth, screenHeight, PixelFormat.RGBA_8888, 2
        )

        imageReader?.setOnImageAvailableListener({ reader ->
            // --- FRAME SKIPPING: hedeflenen FPS'in altindaki kareleri yok say ---
            val now = SystemClock.elapsedRealtime()
            val image = reader.acquireLatestImage()
            if (image == null) return@setOnImageAvailableListener

            if (now - lastFrameTimestamp < FRAME_INTERVAL_MS) {
                image.close() // bu kareyi isleme almadan birak (CPU tasarrufu)
                return@setOnImageAvailableListener
            }
            lastFrameTimestamp = now

            try {
                processFrame(image)
            } finally {
                image.close()
            }
        }, backgroundHandler)

        virtualDisplay = mediaProjection?.createVirtualDisplay(
            "DroneYanginCapture",
            screenWidth, screenHeight, screenDensity,
            DisplayManager.VIRTUAL_DISPLAY_FLAG_AUTO_MIRROR,
            imageReader?.surface,
            null,
            backgroundHandler
        )
    }

    /**
     * Yakalanan kareyi (Image -> JPEG byte[]) Flutter tarafina (overlay engine, EventChannel
     * uzerinden) gonderir. Flutter orada PyTorch modeline besler ve sonucu cizer.
     *
     * Not: Image -> Bitmap donusumu burada yapilip JPEG'e sikistiriliyor; boylece Dart
     * tarafinda hem 'image' paketiyle decode kolaylasiyor hem de kanal uzerinden tasinan
     * veri boyutu kuculuyor (performans).
     */
    private fun processFrame(image: Image) {
        val sink = frameEventSink ?: return

        val planes = image.planes
        val buffer: ByteBuffer = planes[0].buffer
        val pixelStride = planes[0].pixelStride
        val rowStride = planes[0].rowStride
        val rowPadding = rowStride - pixelStride * screenWidth

        val bitmap = android.graphics.Bitmap.createBitmap(
            screenWidth + rowPadding / pixelStride,
            screenHeight,
            android.graphics.Bitmap.Config.ARGB_8888
        )
        bitmap.copyPixelsFromBuffer(buffer)

        // Gercek ekran boyutuna kirp (rowPadding nedeniyle olusan fazlaligi temizle)
        val cropped = android.graphics.Bitmap.createBitmap(bitmap, 0, 0, screenWidth, screenHeight)
        bitmap.recycle()

        val jpegStream = ByteArrayOutputStream()
        // Kalite 60: model girisi icin yeterli, agirligi dusuk -> kanal/iframe gecikmesini azaltir
        cropped.compress(android.graphics.Bitmap.CompressFormat.JPEG, 60, jpegStream)
        cropped.recycle()

        val jpegBytes = jpegStream.toByteArray()

        mainHandler.post {
            // EventChannel ana thread'den beslenmelidir
            frameEventSink?.success(
                mapOf(
                    "bytes" to jpegBytes,
                    "width" to screenWidth,
                    "height" to screenHeight,
                    "timestamp" to SystemClock.elapsedRealtime()
                )
            )
        }
    }

    // ============================================================================================
    // TEMIZLIK
    // ============================================================================================

    private fun stopEverything() {
        try {
            virtualDisplay?.release()
            imageReader?.setOnImageAvailableListener(null, null)
            imageReader?.close()
            mediaProjection?.stop()
        } catch (_: Exception) {
        }
        virtualDisplay = null
        imageReader = null
        mediaProjection = null

        overlayView?.let {
            try {
                windowManager.removeView(it)
            } catch (_: Exception) {
            }
        }
        overlayView?.detachFromFlutterEngine()
        overlayView = null

        overlayFlutterEngine?.destroy()
        overlayFlutterEngine = null
        frameEventSink = null

        stopForeground(true)
        stopSelf()
    }
}
