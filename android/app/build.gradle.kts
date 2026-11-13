import java.util.Properties
import java.io.FileInputStream
import org.gradle.api.tasks.Copy

plugins {
    id("com.android.application")
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "com.toji.zorox"
    compileSdkVersion(rootProject.extra["projectCompileSdk"] as String)
    // See the projectNdk comment in the root build.gradle.kts for why this is
    // pinned instead of following flutter.ndkVersion.
    ndkVersion = rootProject.extra["projectNdk"] as String

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
        isCoreLibraryDesugaringEnabled = true
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "com.toji.zorox"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = rootProject.extra["projectTargetSdk"] as Int
        versionCode = flutter.versionCode
        versionName = flutter.versionName

        // ARM64 only: the APK must stay small. `flutter build apk
        // --target-platform android-arm64` only strips the Flutter
        // engine/app .so; plugin .so files (libvlc, libmpv, libgojni...)
        // are still packaged for every ABI without this — the +14 APK
        // carried armeabi-v7a (66.6 MB) + x86_64 (88.1 MB) of them.
        // This is what actually drops the other two ABIs.
        //
        // WHY clear() + add() and not `+=`: the Flutter Gradle plugin
        // resets abiFilters to all three ABIs in its apply()
        // (FlutterPlugin.configureAbiWithoutSplits: clear() +
        // addAll([armeabi-v7a, arm64-v8a, x86_64])), which runs BEFORE
        // this android {} block — so `abiFilters += "arm64-v8a"` only
        // ADDED arm64 to the full list and the +6 APK still shipped
        // all three ABIs. Clearing first replaces the plugin's list.
        // (gradle.properties disable-abi-filtering=true also tells the
        // plugin to skip its override entirely; both mechanisms
        // together make this robust.)
        ndk {
            abiFilters.clear()
            abiFilters.add("arm64-v8a")
        }
    }

    val keystoreProperties = Properties()
    val keystorePropertiesFile = rootProject.file("key.properties")
    if (keystorePropertiesFile.exists()) {
        keystoreProperties.load(FileInputStream(keystorePropertiesFile))
    }

    signingConfigs {
        create("release") {
            keyAlias = keystoreProperties.getProperty("keyAlias")
            keyPassword = keystoreProperties.getProperty("keyPassword")
            storeFile = if (keystoreProperties.getProperty("storeFile") != null) file(keystoreProperties.getProperty("storeFile")) else null
            storePassword = keystoreProperties.getProperty("storePassword")
        }
    }

    buildTypes {
        release {
            // Require a real signing keystore for release. Falling back to
            // the debug key would silently ship an unsigned-for-Play APK
            // (audit H13). For CI/local debug-without-keystore use
            // `flutter run --debug` or `flutter build apk --debug`.
            if (keystorePropertiesFile.exists()) {
                signingConfig = signingConfigs.getByName("release")
            } else {
                // Build still runs (so `flutter build apk --release` works
                // during local exploration without a key.properties) but the
                // resulting APK is debug-signed — never publish it.
                println("WARN: Release build is using DEBUG signing — " +
                        "key.properties not found. This APK MUST NOT be " +
                        "distributed publicly.")
                signingConfig = signingConfigs.getByName("debug")
            }

            // Code & resource shrinking (audit B8). Skip the bundled
            // proguard-android-optimize.txt rules and rely on the
            // Flutter-provided rules plus our own proguard-rules.pro for
            // plugin-specific keep rules.
            isMinifyEnabled = true
            isShrinkResources = true
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro",
            )
        }
    }

    testOptions {
        unitTests {
            // Robolectric's Android 16 sets up file descriptors through the
            // JDK's internal access, which JDK 17+ closes to it by default.
            // The app's own resources are left out: the tests here need none,
            // and including them would package Flutter's assets into a task
            // that does not wait for them.
            all { it.jvmArgs("--add-opens=java.base/jdk.internal.access=ALL-UNNAMED") }
        }
    }

    packaging {
        jniLibs {
            useLegacyPackaging = true
        }
        // Duplicate metadata from CloudStream's library dependencies.
        resources {
            excludes += setOf(
                "META-INF/versions/9/OSGI-INF/MANIFEST.MF",
                "META-INF/DEPENDENCIES",
                "META-INF/LICENSE*",
                "META-INF/NOTICE*",
                // NOTE: a TorrServer entry used to live here, but
                // packaging.resources.excludes only excludes JAVA RESOURCES
                // (META-INF etc.) — NOT Flutter assets under assets/. The
                // desktop binaries are Flutter assets copied by the
                // copyFlutterAssetsRelease task, so they need the exclude
                // on that task + the mergeReleaseAssets safety net below.
            )
        }
    }

    // TorrServer desktop binaries (~103 MB uncompressed, ~87 MB in the
    // +6 APK): only the desktop Dart plugin loads them from the asset
    // bundle (Linux/macOS/Windows). Android runs TorrServer from the Go
    // AAR and iOS from the xcframework, so these are dead weight in the
    // APK. The package declares them as `assets/torrserver/` in its
    // pubspec (packages/flutter_torrent_server), so they arrive as
    // Flutter assets at
    // assets/flutter_assets/packages/flutter_torrent_server/assets/torrserver/
    // and must be excluded at the Flutter-asset copy step, not via
    // packaging.resources.excludes (which never matched them — that is
    // why the +6 APK still carried all six binaries).
    //
    // Two independent mechanisms, so a silent failure of one still
    // leaves the other:
    // (1) Exclude them from the Flutter plugin's copyFlutterAssetsRelease
    //     Copy task — they never reach the merged assets. The task's
    //     source is the Flutter intermediate dir with include
    //     "flutter_assets/**", so the exclude pattern is relative to
    //     that dir (verified against FlutterTaskHelper.getAssets).
    // (2) Safety net: after mergeReleaseAssets, delete the folder from
    //     the merged assets output if it is there anyway. Uses only
    //     standard Gradle APIs (layout.buildDirectory); deleteRecursively
    //     on a missing path is a no-op, so this cannot break the build.
    tasks.named<Copy>("copyFlutterAssetsRelease") {
        exclude("flutter_assets/packages/flutter_torrent_server/assets/torrserver/**")
    }
    tasks.named("mergeReleaseAssets") {
        doLast {
            layout.buildDirectory
                .dir("intermediates/merged_assets/release/mergeReleaseAssets/out/flutter_assets/packages/flutter_torrent_server/assets/torrserver")
                .get().asFile.deleteRecursively()
        }
    }
}


flutter {
    source = "../.."
}

configurations.configureEach {
    // background_downloader declares `androidx.test:monitor` as a plain
    // `implementation` (its android/build.gradle:49), so a test-instrumentation
    // library ends up in the release runtime classpath and ships in the APK.
    // Nothing in its main sources references it - no androidx.test import, no
    // InstrumentationRegistry - so it is dead weight, and it is exactly the
    // reflection-heavy kind of artifact that AGP 9's strictFullModeForKeepRules
    // will complain about. If a build ever fails resolving an androidx.test
    // symbol, the package started using it and this exclude must go.
    //
    // Only from the app's own classpaths, which are what ship. The unit
    // tests' classpaths extend them, so excluding everywhere took it from the
    // tests too, and Robolectric's runner cannot start without it.
    if (name.contains("Test") || !name.endsWith("Classpath")) return@configureEach
    exclude(group = "androidx.test", module = "monitor")
}

dependencies {
    implementation("androidx.tvprovider:tvprovider:1.0.0")
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.5")
    testImplementation("junit:junit:4.13.2")
    testImplementation("org.robolectric:robolectric:4.17")
}
