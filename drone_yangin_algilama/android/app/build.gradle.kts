plugins {
    id("com.android.application")
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
    // Firebase: google-services.json'daki yapilandirmayi SDK'lara actirir.
    id("com.google.gms.google-services")
}

android {
    namespace = "com.example.drone_yangin_algilama"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
        // flutter_local_notifications bunu zorunlu kiliyor (Java 8+ API'lerini
        // eski Android surumlerinde kullanabilmek icin "desugaring").
        isCoreLibraryDesugaringEnabled = true
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_17.toString()
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "com.example.drone_yangin_algilama"
        // NOT: TYPE_APPLICATION_OVERLAY (Android 8 / API 26) ve MediaProjection
        // foreground service tipi (Android 14 / API 34) icin minSdk 26+ gereklidir.
        minSdk = maxOf(flutter.minSdkVersion, 26)
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    // pytorch_lite (org.pytorch:pytorch_android_lite) bazi .so dosyalarini
    // birden fazla bagimlilik uzerinden getirebilir; cakismayi onler.
    packaging {
        jniLibs {
            pickFirsts += listOf("**/libc++_shared.so", "**/libfbjni.so")
        }
    }

    // not: Firebase bagimliliklarini Flutter pubspec.yaml uzerinden (firebase_core,
    // cloud_firestore, vb.) ekleyecegiz; bu paketler kendi native AAR'larini
    // otomatik getirir. Burada elle "implementation(...)" eklemeye gerek YOK.

    buildTypes {
        release {
            // TODO: Add your own signing config for the release build.
            // Signing with the debug keys for now, so `flutter run --release` works.
            signingConfig = signingConfigs.getByName("debug")

            // KRITIK FIX: R8/ProGuard kod kuculme+gizleme (minification), pytorch_lite
            // plugin'inin reflection ile cagirdigi org.pytorch.* siniflarini
            // kaldiriyor/yeniden adlandiriyor (obfuscated stack izlerindeki
            // V0.j.p, B0.C.r vb. buradan geliyor). Sonuc: NativePeer yanlis/eksik
            // native kutuphane adi ariyor -> ClassNotFoundException / UnsatisfiedLinkError.
            // Prototip asamasinda en guvenilir cozum minifikasyonu tamamen kapatmak.
            isMinifyEnabled = false
            isShrinkResources = false
        }
    }
}

flutter {
    source = "../.."
}

dependencies {
    // core library desugaring icin zorunlu kutuphane (flutter_local_notifications)
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.4")
}
