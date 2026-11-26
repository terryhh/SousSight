group = "dev.soussight.ai_logic_hybrid"
version = "1.0-SNAPSHOT"

buildscript {
    val kotlinVersion = "2.4.0"
    repositories {
        google()
        mavenCentral()
    }

    dependencies {
        classpath("com.android.tools.build:gradle:9.1.0")
        classpath("org.jetbrains.kotlin:kotlin-gradle-plugin:$kotlinVersion")
    }
}

allprojects {
    repositories {
        google()
        mavenCentral()
    }
}

plugins {
    id("com.android.library")
}

android {
    namespace = "dev.soussight.ai_logic_hybrid"

    compileSdk = 36

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    sourceSets {
        getByName("main") {
            java.srcDirs("src/main/kotlin")
        }
        getByName("test") {
            java.srcDirs("src/test/kotlin")
        }
    }

    defaultConfig {
        // firebase-ai-ondevice and ML Kit GenAI declare minSdk 26.
        minSdk = 26
    }

    testOptions {
        unitTests {
            all {
                it.useJUnitPlatform()

                it.outputs.upToDateWhen { false }

                it.testLogging {
                    events("passed", "skipped", "failed", "standardOut", "standardError")
                    showStandardStreams = true
                }
            }
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

// Versions verified on maven.google.com (2026-11-25). firebase-ai-ondevice is not in the
// Firebase BoM; 16.0.0-beta08 pairs with firebase-ai 18.2.0 (both depend on
// firebase-ai-ondevice-interop 16.0.0-beta08). FlutterFire's BoM 35.1.0 recommends firebase-ai
// 18.1.0; a BoM is a non-strict platform constraint, so Gradle resolves the higher 18.2.0.
val firebaseAiVersion = "18.2.0"
val firebaseAiOnDeviceVersion = "16.0.0-beta08"
// The ML Kit GenAI version firebase-ai-ondevice 16.0.0-beta08 pulls in (via genai-prompt).
// Needed at compile time only to read GenAiException error codes (BUSY, battery quota, ...).
val mlkitGenAiVersion = "1.0.0-beta5"
val coroutinesVersion = "1.10.2"

dependencies {
    implementation("com.google.firebase:firebase-ai:$firebaseAiVersion")
    implementation("com.google.firebase:firebase-ai-ondevice:$firebaseAiOnDeviceVersion")
    implementation("com.google.mlkit:genai-common:$mlkitGenAiVersion")
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-android:$coroutinesVersion")

    testImplementation("org.jetbrains.kotlin:kotlin-test-junit5")
    testRuntimeOnly("org.junit.platform:junit-platform-launcher")
}
