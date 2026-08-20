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
// takeIf: CI always sets KEYSTORE_FILE, to "" when no keystore secret exists —
// an empty string is not null, so without this `file("")` would blow up.
val envStoreFile: String? = System.getenv("KEYSTORE_FILE")?.takeIf { it.isNotBlank() }
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
            // NB: ABI selection is NOT done here. Flutter's gradle plugin sets
            // ndk.abiFilters itself from --target-platform, after this block,
            // so anything set here is silently overwritten (and conflicts
            // outright with the splits filters --split-per-abi installs).
            // The universal build passes --target-platform instead; see
            // .github/workflows/build.yml.
        }
    }
}

// Drop x86 slices from RELEASE builds only.
//
// Three layers had to line up here, which is why this looks over-engineered:
//   - ndk.abiFilters does not work: Flutter's gradle plugin sets it itself
//     from --target-platform, after our buildTypes block, and it conflicts
//     outright with the splits filters --split-per-abi installs.
//   - --target-platform drops Flutter's own libapp.so but NOT plugin
//     natives, which arrive as prebuilt jniLibs inside AARs — media_kit's
//     libmpv.so alone is 15MB per ABI.
//   - so the x86 exclusion happens at PACKAGING time, which nothing
//     downstream overrides.
// Release only, so debug/profile still run on an x86_64 emulator.
androidComponents {
    onVariants(selector().withBuildType("release")) { variant ->
        variant.packaging.jniLibs.excludes.addAll(
            listOf("lib/x86/**", "lib/x86_64/**")
        )
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
