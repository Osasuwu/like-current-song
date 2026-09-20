import java.util.Properties

plugins {
    id("com.android.application")
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// Release signing is read from android/key.properties, which is gitignored: the
// keystore and its passwords never enter the repository. Without that file a
// release build still succeeds — contributors and CI are not made to hold a key
// — but it is signed with the per-machine debug key, and such an APK must not be
// published: nobody could upgrade it in place from a build signed anywhere else.
val keystorePropertiesFile = rootProject.file("key.properties")
val keystoreProperties = Properties().apply {
    if (keystorePropertiesFile.exists()) {
        keystorePropertiesFile.inputStream().use(::load)
    }
}
val missingKeystoreProperties = if (keystorePropertiesFile.exists()) {
    listOf("storeFile", "storePassword", "keyAlias", "keyPassword")
        .filter { keystoreProperties.getProperty(it).isNullOrBlank() }
} else {
    emptyList()
}

// A half-filled key.properties — the state it is in between copying the
// example and finishing it — must not be treated as a key. It is reported
// below, but only when a release is actually being built: an incomplete file
// is no reason to break `flutter run`.
val hasReleaseKeystore =
    keystorePropertiesFile.exists() && missingKeystoreProperties.isEmpty()

android {
    namespace = "com.osasuwu.like_spotify"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_17.toString()
    }

    defaultConfig {
        applicationId = "com.osasuwu.like_spotify"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        if (hasReleaseKeystore) {
            create("release") {
                storeFile = rootProject.file(keystoreProperties.getProperty("storeFile"))
                storePassword = keystoreProperties.getProperty("storePassword")
                keyAlias = keystoreProperties.getProperty("keyAlias")
                keyPassword = keystoreProperties.getProperty("keyPassword")
            }
        }
    }

    buildTypes {
        release {
            signingConfig =
                signingConfigs.getByName(if (hasReleaseKeystore) "release" else "debug")
        }
    }
}

// Say out loud which key a release artifact is signed with, so a debug-signed
// one cannot be published by accident. This hangs off the task graph rather
// than a task action so that it still reports on an up-to-date build, and it
// speaks at warning level because `flutter build` hides Gradle's lifecycle
// output — a silent "which key was this?" is the whole hazard.
gradle.taskGraph.whenReady {
    val buildsRelease = hasTask(":app:assembleRelease") || hasTask(":app:bundleRelease")
    if (!buildsRelease) return@whenReady
    if (missingKeystoreProperties.isNotEmpty()) {
        throw GradleException(
            "android/key.properties is incomplete - missing " +
                "${missingKeystoreProperties.joinToString(", ")}. Fill it in " +
                "(see android/key.properties.example) or delete it to build " +
                "debug-signed. Refusing to silently sign with the debug key.",
        )
    }
    if (hasReleaseKeystore) {
        logger.warn("Warning: release signing uses the key from android/key.properties.")
    } else {
        logger.warn(
            "Warning: release signing uses the DEBUG KEY - android/key.properties is " +
                "absent. Fine for local testing; do not publish this artifact.",
        )
    }
}

dependencies {
    implementation("androidx.work:work-runtime-ktx:2.10.1")
    implementation("androidx.media:media:1.7.0")
    implementation("androidx.localbroadcastmanager:localbroadcastmanager:1.1.0")

    testImplementation("junit:junit:4.13.2")
    // android.jar's org.json is a stub under local unit tests; use the real one.
    testImplementation("org.json:json:20240303")
}

flutter {
    source = "../.."
}
