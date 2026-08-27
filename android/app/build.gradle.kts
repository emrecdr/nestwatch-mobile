import java.io.FileInputStream
import java.util.Properties

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// The upload key, when this machine has one.
//
// `android/key.properties` is deliberately untracked — see android/key.properties.example
// for the four lines it needs. A build on a machine without it is a build that cannot
// produce a release anybody else should install.
val keystorePropertiesFile = rootProject.file("key.properties")
val hasUploadKey = keystorePropertiesFile.exists()
val keystoreProperties = Properties().apply {
    if (hasUploadKey) FileInputStream(keystorePropertiesFile).use { load(it) }
}

// Refuse the Play upload path without a real key, rather than emitting an .aab signed
// with the debug certificate that ships in every Flutter checkout. That artifact looks
// exactly like a finished one.
//
// Checked against the requested tasks rather than at packaging time so the message
// arrives before the build spends two minutes, and so ordinary debug work is untouched.
if (!hasUploadKey && gradle.startParameter.taskNames.any { it.contains("bundle", ignoreCase = true) }) {
    throw GradleException(
        "No android/key.properties, so there is no upload key to sign with.\n" +
        "  A release bundle signed with the debug certificate is not shippable, and\n" +
        "  this refuses to make one rather than let it look finished.\n" +
        "  See android/key.properties.example, and docs/PLAN.md §5 on store paperwork."
    )
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

    signingConfigs {
        create("release") {
            // Absent on a machine that has no upload key. The block still has to exist
            // for `buildTypes` to name it, so it is configured from whatever was found
            // and the decision about whether that is good enough is made below.
            keyAlias = keystoreProperties.getProperty("keyAlias")
            keyPassword = keystoreProperties.getProperty("keyPassword")
            storeFile = keystoreProperties.getProperty("storeFile")?.let { file(it) }
            storePassword = keystoreProperties.getProperty("storePassword")
        }
    }

    buildTypes {
        release {
            // Debug keys stay for `flutter run --release`, which is a real thing to want
            // locally — profile mode does not exercise obfuscation or R8. What must never
            // happen is a *shippable* artifact signed with them, and that is a different
            // task: `bundleRelease` is the Play upload path, and it fails outright above
            // rather than producing something that looks finished.
            //
            // Play would reject a debug certificate anyway. The reason not to rely on
            // that is the same reason for every other check here: a rejection at the far
            // end of an upload is a worse place to learn it than a build that refuses.
            signingConfig = if (hasUploadKey) {
                signingConfigs.getByName("release")
            } else {
                signingConfigs.getByName("debug")
            }

            // R8 is not configured here on purpose. Flutter enables code shrinking for
            // every release build and documents that `--no-shrink` has no effect, so a
            // `isMinifyEnabled = true` line would read as though it were doing something.
            // Dart-level obfuscation is a build flag rather than a Gradle setting:
            //   flutter build appbundle --obfuscate --split-debug-info=build/symbols
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
