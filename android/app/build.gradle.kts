import java.util.Properties
import javax.inject.Inject

plugins {
    alias(libs.plugins.android.application)
    alias(libs.plugins.kotlin.compose)
    alias(libs.plugins.kotlin.serialization)
}

// Written by `make android` on first run; git-ignored.
val keystoreProps = Properties().apply {
    val f = rootProject.file("keystore.properties")
    if (f.exists()) f.inputStream().use { load(it) }
}

android {
    namespace = "local.critter.phone"
    compileSdk = 37

    defaultConfig {
        applicationId = "local.critter.phone"
        minSdk = 29
        targetSdk = 37
        versionCode = 1
        versionName = "1.0"
    }

    signingConfigs {
        create("release") {
            if (keystoreProps.isNotEmpty()) {
                storeFile = file(keystoreProps.getProperty("storeFile"))
                storePassword = keystoreProps.getProperty("storePassword")
                keyAlias = keystoreProps.getProperty("keyAlias")
                keyPassword = keystoreProps.getProperty("keyPassword")
            }
        }
    }

    buildTypes {
        release {
            isMinifyEnabled = false
            if (keystoreProps.isNotEmpty()) signingConfig = signingConfigs.getByName("release")
        }
        // Same applicationId and, with the keystore, the same key: `installDebug` replaces the release app on the
        // phone in place and keeps its pairing and settings.
        debug {
            if (keystoreProps.isNotEmpty()) signingConfig = signingConfigs.getByName("release")
        }
    }

    buildFeatures { compose = true }

    // The board's sounds are opened as file descriptors by SoundPool, which needs them stored uncompressed.
    androidResources { noCompress += "wav" }

    testOptions {
        unitTests.all { it.useJUnitPlatform() }
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_21
        targetCompatibility = JavaVersion.VERSION_21
    }
}

kotlin {
    jvmToolchain(21)
}

// The bundled skins and sounds have one source of truth, the repo root: copied into the
// generated assets as skins/<name>/manifest.json and sounds/<theme>/<state>.wav.
abstract class CopyCritterAssets : DefaultTask() {
    @get:InputDirectory
    @get:PathSensitive(PathSensitivity.RELATIVE)
    abstract val skinsDir: DirectoryProperty

    @get:InputDirectory
    @get:PathSensitive(PathSensitivity.RELATIVE)
    abstract val soundsDir: DirectoryProperty

    @get:OutputDirectory
    abstract val outputDir: DirectoryProperty

    @get:Inject
    abstract val files: FileSystemOperations

    @TaskAction
    fun copy() {
        files.sync {
            from(skinsDir) {
                include("*/manifest.json")
                into("skins")
            }
            from(soundsDir) { into("sounds") }
            into(outputDir)
        }
    }
}

androidComponents.onVariants { variant ->
    val copyAssets = tasks.register<CopyCritterAssets>("copy${variant.name.replaceFirstChar { it.uppercase() }}CritterAssets") {
        skinsDir.set(rootProject.layout.projectDirectory.dir("../Skins"))
        soundsDir.set(rootProject.layout.projectDirectory.dir("../Sounds"))
        outputDir.set(layout.buildDirectory.dir("generated/critterAssets/${variant.name}"))
    }
    variant.sources.assets?.addGeneratedSourceDirectory(copyAssets, CopyCritterAssets::outputDir)
}

dependencies {
    implementation(project(":core"))
    implementation(platform(libs.compose.bom))
    implementation(libs.compose.ui)
    implementation(libs.compose.material3)
    implementation(libs.androidx.activity.compose)
    implementation(libs.androidx.lifecycle.runtime.compose)
    implementation(libs.androidx.core.ktx)
    implementation(libs.kotlinx.coroutines.android)
    implementation(libs.camerax.core)
    implementation(libs.camerax.camera2)
    implementation(libs.camerax.lifecycle)
    implementation(libs.camerax.view)
    implementation(libs.zxing.core)

    testImplementation(kotlin("test"))
    testImplementation(libs.junit.jupiter)
    testRuntimeOnly(libs.junit.platform.launcher)
}
