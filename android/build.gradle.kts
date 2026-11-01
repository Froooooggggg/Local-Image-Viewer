allprojects {
    repositories {
        // === 国内镜像（不保留官方兜底，理由见 settings.gradle.kts）===
        val aliyunGoogle = "https://maven.aliyun.com/repository/google"
        val aliyunPublic = "https://maven.aliyun.com/repository/public"

        maven { url = uri(aliyunGoogle); name = "AliyunGoogle" }
        maven { url = uri(aliyunPublic); name = "AliyunPublic" }

        if (System.getenv("DSH_USE_OFFICIAL") == "1") {
            google()
            mavenCentral()
        }
    }
}

val newBuildDir: Directory =
    rootProject.layout.buildDirectory
        .dir("../../build")
        .get()
rootProject.layout.buildDirectory.value(newBuildDir)

subprojects {
    val newSubprojectBuildDir: Directory = newBuildDir.dir(project.name)
    project.layout.buildDirectory.value(newSubprojectBuildDir)
}
subprojects {
    project.evaluationDependsOn(":app")
}

// === 统一第三方插件的 compileSdk ===
// 背景：file_picker 8.x 自身以 android-34 编译，而它依赖的
// flutter_plugin_android_lifecycle 要求 android-36，构建时 AAR 元数据校验会失败：
//   ":file_picker is currently compiled against android-34"
// 这里把所有 Android 库模块的 compileSdk 抬到 36，与本应用保持一致。
// 只影响编译期使用的 API 等级，不改变 minSdk / targetSdk 的运行时行为。
//
// 注意上面的 evaluationDependsOn(":app") 会让部分子项目提前完成评估，
// 此时再调用 afterEvaluate 会报 "project is already evaluated"，因此需要分情况处理。
fun alignCompileSdk(project: Project) {
    project.extensions.configure<com.android.build.gradle.LibraryExtension>("android") {
        compileSdk = 36
    }
}

subprojects {
    val applyAlignment = {
        if (plugins.hasPlugin("com.android.library")) {
            alignCompileSdk(this)
        }
    }
    if (state.executed) {
        // 已经评估完成：立即配置（configuration cache 下跳过，交由正常构建路径）。
        try {
            applyAlignment()
        } catch (_: Throwable) {
            // 配置缓存等场景下忽略，不影响构建结果。
        }
    } else {
        afterEvaluate { applyAlignment() }
    }
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
