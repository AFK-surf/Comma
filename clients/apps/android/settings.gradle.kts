pluginManagement {
    repositories {
        google {
            content {
                includeGroupByRegex("com\\.android.*")
                includeGroupByRegex("com\\.google.*")
                includeGroupByRegex("androidx.*")
            }
        }
        mavenCentral()
        gradlePluginPortal()
    }
}
plugins {
    id("org.gradle.toolchains.foojay-resolver-convention") version "1.0.0"
}
dependencyResolutionManagement {
    repositoriesMode.set(RepositoriesMode.FAIL_ON_PROJECT_REPOS)
    repositories {
        google { content { excludeGroup("org.robolectric") } }
        // Maven lists this GCS mirror at https://maven.apache.org/repository/.
        // Only Robolectric's large test runtimes use it. Other dependencies keep their repositories.
        maven {
            name = "robolectricAndroidRuntime"
            url = uri("https://maven-central.storage-download.googleapis.com/maven2/")
            content { includeModule("org.robolectric", "android-all-instrumented") }
        }
        mavenCentral {
            content { excludeModule("org.robolectric", "android-all-instrumented") }
        }
    }
}

rootProject.name = "comma"
include(":app")
include(":scroll")
include(":core")

include(":macrobenchmark")
