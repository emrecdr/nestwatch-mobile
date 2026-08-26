plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "com.nestwatch.mobile"

    // Pinned above Flutter's default (36) because flutter_secure_storage 11 ships AAR
    // metadata requiring compileSdk >= 37, and the build fails at
    // :app:checkDebugAarMetadata without it.
    //
    // Safe to raise on its own: compileSdk decides which APIs are available to compile
    // against. It does not opt the app into new runtime behaviour (that is targetSdk)
    // and does not narrow which devices can install it (that is minSdk, still 24).
    compileSdk = 37
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // Fixed before the first Play upload — an applicationId can never be changed
        // afterwards. See docs/PLAN.md §9.
        applicationId = "com.nestwatch.mobile"
        // Flutter's default is 24, which already clears both plugin floors
        // (mobile_scanner 23, flutter_secure_storage 24).
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    buildTypes {
        release {
            // TODO: Add your own signing config for the release build.
            // Signing with the debug keys for now, so `flutter run --release` works.
            signingConfig = signingConfigs.getByName("debug")
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

flutter {
    source = "../.."
}
