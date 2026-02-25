allprojects {
    repositories {
        google()
        mavenCentral()
    }
}

// Fix for flutter_bluetooth_serial namespace issue
subprojects {
    afterEvaluate {
        if (project.name == "flutter_bluetooth_serial") {
            project.extensions.findByType(com.android.build.gradle.LibraryExtension::class)?.apply {
                namespace = "io.github.edufolly.flutterbluetoothserial"
            }
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

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
