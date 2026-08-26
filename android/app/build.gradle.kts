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
        // Required by flutter_local_notifications 10+, which uses java.time APIs that do
        // not exist below API 26. Without it the build fails at :app:checkDebugAarMetadata
        // — the plugin declares the requirement in its AAR metadata rather than letting
        // it surface as a runtime crash on an old phone.
        isCoreLibraryDesugaringEnabled = true
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

dependencies {
    // Version pinned by flutter_local_notifications' own README and build.gradle.
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.4")
}
