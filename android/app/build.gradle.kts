plugins {
    id("com.android.application")
    // START: FlutterFire Configuration
    id("com.google.gms.google-services")
    // END: FlutterFire Configuration
    id("org.jetbrains.kotlin.android")
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "com.nexta.etacherv4"
    compileSdk = 35
    ndkVersion = "27.0.12077973"

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    kotlinOptions {
        jvmTarget = "17"
    }

    defaultConfig {
        applicationId = "com.nexta.etacherv4"
        minSdk = 21
        targetSdk = 35
        versionCode = 1
        versionName = "1.0"
        // Thêm cấu hình cho OneSignal
        manifestPlaceholders["onesignal_app_id"] = "a47a518e-3506-48ce-ad29-b0c71c56f8b9"
        manifestPlaceholders["onesignal_google_project_number"] = "" // Để trống nếu không dùng
    }

    buildTypes {
        release {
            signingConfig = signingConfigs.getByName("debug")
        }
    }
}

flutter {
    source = "../.."
}

dependencies {
    implementation("com.onesignal:OneSignal:5.1.8") // Cập nhật phiên bản tương thích với onesignal_flutter: ^5.2.2
}