// kotlin 脚本的 import 必须在最前面（Gradle 允许它在 plugins 之前）
import java.util.Properties

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// ===== 发布签名 =====
//
// 仓库里**不含任何密钥素材**。默认用 Android 调试证书签名，
// 这样 clone 下来 `flutter build apk --release` 得到的包可以直接安装。
//
// ===== 为什么用调试证书 =====
// 调试证书是 Android SDK 自动生成的（`~/.android/debug.keystore`），
// 人人都有、口令就是 `android`，因此它**不具备防篡改能力** ——
// 任何人都能签一个同包名、更高版本号的包来替换它。
//
// 对这个应用来说这个取舍可以接受：它不上架商店、只查本人数据、
// 不接收外部内容；而代价换来的是「拿到源码就能构建出一个能装的包」。
//
// 要正式签名（例如将来上架）：在 `android/key.properties` 里写
//     storeFile=/绝对路径/your.keystore
//     storePassword=***
//     keyAlias=***
//     keyPassword=***
// 下面的逻辑会**优先用它**。该文件与 *.keystore / *.jks 都已被
// .gitignore 排除，不会进仓库。
val keystorePropsFile = rootProject.file("key.properties")
val keystoreProps = Properties().apply {
    if (keystorePropsFile.exists()) {
        keystorePropsFile.inputStream().use { load(it) }
    }
}
val hasOwnKey = keystoreProps.getProperty("storeFile") != null

android {
    namespace = "com.sdjzu.hijianzhu"
    // 显式钉住编译 SDK，不用 flutter.compileSdkVersion。
    // 原因：本机 SDK 目录里装的是 `android-37.0`（带小版本号的非标准目录名），
    // 而 Gradle 按 `android-<compileSdk>` 去找平台，于是报
    // "Failed to find target with hash string 'android-37'"。
    // 钉到 36（Flutter 自身的默认值、且本机目录名规范）可绕开这个问题。
    compileSdk = 36
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
        // flutter_local_notifications 用到了 Java 8 的 time API，
        // 在低于 API 26 的设备上必须靠 desugaring 补齐，否则构建期就报错。
        isCoreLibraryDesugaringEnabled = true
    }

    defaultConfig {
        applicationId = "com.sdjzu.hijianzhu"
        // minSdk 24：与鸿蒙版的目标区间（HarmonyOS 6.0/API20 起的设备）大致对应，
        // 同时满足所有依赖的最低要求（onnxruntime 要 21、device_calendar 要 21）。
        minSdk = 24
        targetSdk = 36
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        if (hasOwnKey) {
            create("release") {
                storeFile = file(keystoreProps.getProperty("storeFile"))
                storePassword = keystoreProps.getProperty("storePassword")
                keyAlias = keystoreProps.getProperty("keyAlias")
                keyPassword = keystoreProps.getProperty("keyPassword")
            }
        }
    }

    buildTypes {
        release {
            // 有自有密钥（key.properties）就用它；没有则退回调试证书，
            // 保证 `flutter build apk --release` 开箱即得可安装的包。
            signingConfig = if (hasOwnKey) {
                signingConfigs.getByName("release")
            } else {
                signingConfigs.getByName("debug")
            }
        }
    }
}

dependencies {
    // 与上面的 isCoreLibraryDesugaringEnabled 配套
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.5")

    // 显式钉住 androidx.core。
    //
    // 为什么需要：flutter_local_notifications 18.x 的 Java 源码直接用到了
    // androidx.core 的 IconCompat / NotificationCompat，但它自己只声明了
    // `implementation "androidx.core:core:1.3.0"`（库级依赖不会传递给消费方），
    // 于是本项目编译该插件的 Java 时报「找不到符号: 类 IconCompat」。
    // 在 app 里补一条显式依赖即可把 androidx.core 放到它的编译类路径上。
    // 这里用较新的 1.13.1（与其它插件一致），而不是它声明的 1.3.0。
    implementation("androidx.core:core:1.13.1")
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

flutter {
    source = "../.."
}
