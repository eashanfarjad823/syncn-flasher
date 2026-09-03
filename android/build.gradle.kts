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

// The usb_serial plugin (0.5.2, unmaintained) pins compileSdk 33, but its own
// AndroidX dependencies require 34+, so its AAR metadata check fails.
//
// This must be registered BEFORE the evaluationDependsOn block below, which
// forces subprojects to evaluate — afterEvaluate throws once that has happened.
// Reflection is used rather than the typed AGP extension because the Android
// Gradle Plugin is not on this root script's buildscript classpath.
subprojects {
    afterEvaluate {
        val androidExt = project.extensions.findByName("android")
        if (androidExt != null) {
            runCatching {
                androidExt.javaClass
                    .getMethod("compileSdkVersion", Int::class.javaPrimitiveType)
                    .invoke(androidExt, 36)
            }
        }
    }
}

subprojects {
    project.evaluationDependsOn(":app")
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
