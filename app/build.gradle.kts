// Импорт обязателен: в Kotlin DSL `java` — это расширение Gradle, поэтому
// полное имя java.util.Properties внутри скрипта не резолвится.
import java.util.Properties

plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
}

/**
 * Релизный ключ. Пароли лежат в keystore.properties в корне проекта, файл
 * вне git. Пример содержимого:
 *
 *     storeFile=souchastnik-release.jks
 *     storePassword=...
 *     keyAlias=souchastnik
 *     keyPassword=...
 *
 * Сам ключ создаётся один раз:
 *
 *     keytool -genkeypair -v -keystore souchastnik-release.jks \
 *         -alias souchastnik -keyalg RSA -keysize 4096 -validity 10000
 *
 * Ключ и пароли положить в бэкап: Android не примет обновление, подписанное
 * другим ключом, и потеря keystore означает, что обновить уже установленное
 * приложение нельзя ничем, кроме удаления и переустановки.
 */
val keystoreProps = rootProject.file("keystore.properties")
    .takeIf { it.exists() }
    ?.let { file ->
        val props = Properties()
        file.inputStream().use { stream -> props.load(stream) }
        props
    }

// Путь Hexagon SDK: local.properties (hexagon.sdk.dir) или HEXAGON_SDK_ROOT.
// В git не коммитится. Без SDK собираемся только с CPU — как до NPU.
val hexagonSdkRoot: String = run {
    val props = Properties()
    rootProject.file("local.properties").takeIf { it.exists() }?.inputStream()?.use {
        props.load(it)
    }
    props.getProperty("hexagon.sdk.dir")
        ?: System.getenv("HEXAGON_SDK_ROOT")
        ?: ""
}

android {
    namespace = "dev.souchastnik"
    compileSdk = 35

    defaultConfig {
        applicationId = "dev.souchastnik"
        minSdk = 28
        targetSdk = 35
        versionCode = 1
        versionName = "1.0"

        ndk { abiFilters += "arm64-v8a" }

        externalNativeBuild {
            cmake {
                // GGML_LLAMAFILE выключен: на Android даёт проблемы сборки,
                // выигрыш для наших коротких промптов несущественный.
                //
                // Ядра ggml-cpu собираются во ВСЕХ вариантах под arm64 и
                // выбираются на устройстве в рантайме (GGML_BACKEND_DL +
                // GGML_CPU_ALL_VARIANTS): семь libggml-cpu-android_*.so от
                // armv8.0 (без dotprod: Kirin 710, Snapdragon 680/662, Helio
                // G35) до armv9.2 (i8mm, SVE, SME). Каждый вариант умеет
                // сказать через ggml_backend_score(), подходит ли он этому CPU;
                // выбор и загрузка -- load_cpu_backend() в llama_bridge.cpp.
                //
                // Раньше стоял жёсткий -DGGML_CPU_ARM_ARCH=armv8.2-a+dotprod+fp16:
                // быстро на Dimensity 700 (без него префилл ~11 т/с вместо ~73),
                // но на ядрах без dotprod процесс :engine падал по SIGILL.
                // Один -march под все телефоны не бывает: у A73 нет dotprod,
                // у A76 нет i8mm, а компилятор без флага не даёт ни того, ни
                // другого. При кросс-сборке GGML_NATIVE выключен, поэтому
                // варианты -- единственный способ получить и то, и другое.
                arguments += listOf(
                    "-DCMAKE_BUILD_TYPE=Release",
                    "-DGGML_BACKEND_DL=ON",
                    "-DGGML_CPU_ALL_VARIANTS=ON",
                    "-DLLAMA_CURL=OFF",
                    "-DLLAMA_BUILD_TOOLS=OFF",
                    "-DLLAMA_BUILD_EXAMPLES=OFF",
                    "-DLLAMA_BUILD_TESTS=OFF",
                    "-DGGML_LLAMAFILE=OFF",
                    "-DGGML_OPENMP=OFF",
                )
                // NPU (Hexagon HTP). OpenCL/Adreno не включаем.
                if (hexagonSdkRoot.isNotBlank()) {
                    arguments += listOf(
                        "-DGGML_HEXAGON=ON",
                        "-DHEXAGON_SDK_ROOT=$hexagonSdkRoot",
                        "-DHEXAGON_TOOLS_ROOT=$hexagonSdkRoot/tools/HEXAGON_Tools/19.0.07",
                        // hexagon_fun.cmake делает string(FIND ${PREBUILT_LIB_DIR} ...)
                        // ещё на host-сборке ARM libggml-hexagon.so; без значения cmake падает.
                        "-DPREBUILT_LIB_DIR=toolv19_v79",
                    )
                } else {
                    logger.lifecycle(
                        "souchastnik: Hexagon SDK не задан (hexagon.sdk.dir / HEXAGON_SDK_ROOT) — сборка без NPU")
                }
                cppFlags += "-O3"
            }
        }
    }

    // КРИТИЧНО: legacy packaging = нативные библиотеки распаковываются в
    // nativeLibraryDir реальным файлом. Модель лежит там как libmodel-*.so,
    // и мы её mmap-им напрямую по пути. Без этого файла на диске нет и
    // mmap невозможен.
    packaging {
        jniLibs {
            useLegacyPackaging = true
            // HTP-skel -- DSP ELF, llvm-strip ломает файл (как libmodel-*.so).
            keepDebugSymbols += setOf(
                "**/libggml-htp-*.so",
                "**/libmodel-*.so",
            )
        }
    }

    buildFeatures {
        aidl = true
    }

    externalNativeBuild {
        cmake {
            path = file("src/main/cpp/CMakeLists.txt")
            // htp/CMakeLists.txt llama.cpp требует ≥ 3.22.2
            version = "3.31.6"
        }
    }

    signingConfigs {
        if (keystoreProps != null) {
            create("release") {
                storeFile = rootProject.file(keystoreProps.getProperty("storeFile"))
                storePassword = keystoreProps.getProperty("storePassword")
                keyAlias = keystoreProps.getProperty("keyAlias")
                keyPassword = keystoreProps.getProperty("keyPassword")
            }
        }
    }

    buildTypes {
        release {
            isMinifyEnabled = false
            // Есть keystore.properties -- подписываем настоящим ключом.
            // Нет -- остаётся debug-ключ, как было для спайка: тогда
            // `installRelease` на телефон работает, но ПУБЛИКОВАТЬ такой APK
            // нельзя. Подпись должна быть постоянной, иначе обновления с
            // GitHub Releases и F-Droid не встанут поверх установленного.
            signingConfig = if (keystoreProps != null) {
                signingConfigs.getByName("release")
            } else {
                logger.warn(
                    "souchastnik: keystore.properties нет, релиз подписывается " +
                        "DEBUG-ключом. Публиковать такой APK нельзя."
                )
                signingConfigs.getByName("debug")
            }
        }
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
    kotlinOptions {
        jvmTarget = "17"
    }
}

dependencies {
    implementation("androidx.core:core-ktx:1.13.1")
    implementation("androidx.appcompat:appcompat:1.7.0")
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-android:1.9.0")
}
