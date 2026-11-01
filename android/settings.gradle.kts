pluginManagement {
    val flutterSdkPath =
        run {
            val properties = java.util.Properties()
            file("local.properties").inputStream().use { properties.load(it) }
            val flutterSdkPath = properties.getProperty("flutter.sdk")
            require(flutterSdkPath != null) { "flutter.sdk not set in local.properties" }
            flutterSdkPath
        }

    includeBuild("$flutterSdkPath/packages/flutter_tools/gradle")

    repositories {
        // === 国内镜像（maven.google.com / dl.google.com 等直连会长时间挂起）===
        // 默认【不】保留官方兜底：官方云 CDN 能建连但会挂起等待，
        // 一旦镜像缺件，Gradle 就会卡在超时上，比直接失败更糟。
        // 若确实遇到镜像缺件，用 dev-env 设置 DSH_USE_OFFICIAL=1 再构建。
        val aliyunGoogle = "https://maven.aliyun.com/repository/google"
        val aliyunPublic = "https://maven.aliyun.com/repository/public"
        val aliyunGradlePlugin = "https://maven.aliyun.com/repository/gradle-plugin"

        maven { url = uri(aliyunGoogle); name = "AliyunGoogle" }
        maven { url = uri(aliyunPublic); name = "AliyunPublic" }
        maven { url = uri(aliyunGradlePlugin); name = "AliyunGradlePlugin" }

        if (System.getenv("DSH_USE_OFFICIAL") == "1") {
            google()
            mavenCentral()
            gradlePluginPortal()
        }
    }
}

plugins {
    id("dev.flutter.flutter-plugin-loader") version "1.0.0"
    id("com.android.application") version "9.1.0" apply false
    id("org.jetbrains.kotlin.android") version "2.4.0" apply false
}

include(":app")
