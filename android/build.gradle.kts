allprojects {
    repositories {
        google()
        mavenCentral()
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

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}

// 完整替換您 build.gradle.kts 最底部的 subprojects 區塊
subprojects {
    plugins.withId("com.android.library") {
        if (name == "on_audio_query_android") {
            extensions.configure<com.android.build.api.dsl.LibraryExtension> {
                // 1. 修復 Namespace 缺失問題
                namespace = "com.lucasjosino.on_audio_query"
                
                // 2. 將該套件的 Java 編譯目標鎖定為 1.8
                compileOptions {
                    sourceCompatibility = JavaVersion.VERSION_1_8
                    targetCompatibility = JavaVersion.VERSION_1_8
                }
            }

            // 3. 使用全新 Kotlin 2.0+ 規格，強制將 Kotlin 編譯目標鎖定為 1.8 (JVM_1_8)
            tasks.withType<org.jetbrains.kotlin.gradle.tasks.KotlinJvmCompile>().configureEach {
                compilerOptions {
                    jvmTarget.set(org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_1_8)
                }
            }
        }
    }
}
