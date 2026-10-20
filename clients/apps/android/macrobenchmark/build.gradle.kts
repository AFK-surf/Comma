plugins { alias(libs.plugins.android.test) }

android {
    namespace = "surf.comma.android.macrobenchmark"
    compileSdk { version = release(37) }
    buildToolsVersion = "37.0.0"
    defaultConfig {
        minSdk = 35
        targetSdk = 37
        testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"
        missingDimensionStrategy("environment", "dev")
    }
    targetProjectPath = ":app"
    // The driver must run in its own process to compile, stop and restart the target app.
    experimentalProperties["android.experimental.self-instrumenting"] = true
    buildTypes {
        create("benchmark") {
            isDebuggable = true
            matchingFallbacks += "release"
            signingConfig = signingConfigs.getByName("debug")
        }
    }
    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
}
androidComponents.beforeVariants(androidComponents.selector().withBuildType("debug")) {
    it.enable = false
}
dependencies {
    implementation(libs.androidx.benchmark.macro)
    implementation(libs.androidx.uiautomator)
    implementation(libs.androidx.junit)
    implementation(libs.androidx.test.runner)
}
