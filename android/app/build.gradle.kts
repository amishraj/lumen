import java.util.Properties

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// Release signing: reads android/key.properties locally, or the
// KEYSTORE_* environment variables in CI (see .github/workflows/build.yml).
// Falls back to the debug keystore ONLY when neither exists, so
// `flutter run --release` keeps working before the keystore is set up.
val keyProps = Properties().apply {
    val f = rootProject.file("key.properties")
    if (f.exists()) f.inputStream().use { load(it) }
}
val envStoreFile: String? = System.getenv("KEYSTORE_FILE")
val hasReleaseKeys = keyProps.getProperty("storeFile") != null || envStoreFile != null

android {
    namespace = "org.lumen.lumen"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        applicationId = "org.lumen.lumen"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = maxOf(flutter.minSdkVersion, 21) // media_kit requires API 21+
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        if (hasReleaseKeys) {
            create("release") {
                storeFile = file(envStoreFile ?: keyProps.getProperty("storeFile"))
                storePassword = System.getenv("KEYSTORE_PASSWORD")
                    ?: keyProps.getProperty("storePassword")
                keyAlias = System.getenv("KEY_ALIAS")
                    ?: keyProps.getProperty("keyAlias")
                keyPassword = System.getenv("KEY_PASSWORD")
                    ?: keyProps.getProperty("keyPassword")
            }
        }
    }

    buildTypes {
        release {
            signingConfig = if (hasReleaseKeys) signingConfigs.getByName("release")
                else signingConfigs.getByName("debug")
            // R8 + resource shrinking: the release Java/Kotlin used to ship
            // unshrunk and unobfuscated.
            isMinifyEnabled = true
            isShrinkResources = true
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro"
            )
            // No TV or phone this app targets runs x86; dropping the slices
            // cuts the universal APK by two ABI copies of libmpv + AOT.
            ndk { abiFilters += listOf("arm64-v8a", "armeabi-v7a") }
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
