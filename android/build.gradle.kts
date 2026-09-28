group = "com.vaam.otel_zone"
version = "1.0-SNAPSHOT"

buildscript {
    val kotlinVersion = "2.3.20"
    repositories {
        google()
        mavenCentral()
    }

    dependencies {
        classpath("com.android.tools.build:gradle:9.0.1")
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
    namespace = "com.vaam.otel_zone"

    compileSdk = 36

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        minSdk = 24
    }

    testOptions {
        unitTests {
            isIncludeAndroidResources = true
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

dependencies {
    // The Pigeon-generated handler holds suspend functions, which need
    // coroutines on the classpath.
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-android:1.8.1")
    // Installs the crash handler before Application.onCreate without the app
    // writing a line.
    implementation("androidx.startup:startup-runtime:1.1.1")
    testImplementation("org.jetbrains.kotlin:kotlin-test")
    // android.jar's org.json is a stub that throws in unit tests; the real
    // implementation has to be on the test classpath for CrashStore's JSON to
    // be exercised at all.
    testImplementation("org.json:json:20240303")
}
