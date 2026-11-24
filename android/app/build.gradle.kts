plugins { id("com.android.application"); id("org.jetbrains.kotlin.android") }

android {
    namespace = "app.spotless.android"
    compileSdk = 35
    ndkVersion = "27.2.12479018"
    defaultConfig {
        applicationId = "app.ztunes.android"
        minSdk = 26
        targetSdk = 35
        versionCode = 1
        versionName = "0.1.0-mvp"
        ndk { abiFilters += "arm64-v8a" }
    }
    compileOptions { sourceCompatibility = JavaVersion.VERSION_17; targetCompatibility = JavaVersion.VERSION_17 }
    kotlinOptions { jvmTarget = "17" }
    sourceSets["main"].assets.setSrcDirs(listOf(file("src/main/assets")))
    // Package the full SvelteKit app, built with Android's Tauri-compatible host shims.
    sourceSets["main"].assets.setSrcDirs(listOf(file("../../ui/build")))
}
dependencies {
    implementation("net.java.dev.jna:jna:5.14.0@aar")
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-android:1.8.1")
    implementation("androidx.webkit:webkit:1.12.1")
}
