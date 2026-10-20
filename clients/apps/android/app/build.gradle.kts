import java.util.Properties
import java.security.KeyStore
import java.security.PrivateKey

plugins {
    alias(libs.plugins.android.application)
    alias(libs.plugins.aboutlibraries)
}

fun String.asBuildConfigString(): String =
    "\"${replace("\\", "\\\\").replace("\"", "\\\"")}\""

val localProperties = providers.fileContents(rootProject.layout.projectDirectory.file("local.properties"))
    .asText.map { Properties().apply { load(it.reader()) } }.orElse(Properties())
// Emulator -> host loopback. For a phone, use adb reverse tcp:8787 tcp:8787 with
// -Pcomma.devBaseUrl=http://127.0.0.1:8787, or supply a reachable LAN URL.
val devBaseUrl = providers.gradleProperty("comma.devBaseUrl")
    .orElse(providers.environmentVariable("COMMA_DEV_BASE_URL"))
    .orElse(localProperties.map { it.getProperty("comma.devBaseUrl", "http://10.0.2.2:8787") })
// ASR credentials come only from untracked local.properties. Internal builds require
// an explicit opt-in; release and benchmark always keep voice input unavailable.
val debugAsrApiKey = localProperties.map { it.getProperty("DOUBAO_ASR_API_KEY", "").trim() }
val debugAsrResourceId = localProperties.map { it.getProperty("DOUBAO_ASR_RESOURCE_ID", "").trim() }
val internalAsr = providers.gradleProperty("comma.internal.asr").map {
    require(it == "true" || it == "false") { "comma.internal.asr must be true or false" }
    it == "true"
}.orElse(false)

fun internalSetting(name: String) = providers.environmentVariable(name)
    .orElse(localProperties.map { it.getProperty(name, "") })
val internalKeystore = internalSetting("COMMA_INTERNAL_KEYSTORE").map {
    val path = it.ifBlank { "${System.getProperty("user.home")}/.comma-android/internal.keystore" }
    rootProject.file(if (path.startsWith("~/")) System.getProperty("user.home") + path.drop(1) else path)
}
val internalKeyAlias = internalSetting("COMMA_INTERNAL_KEY_ALIAS")
val internalStorePassword = internalSetting("COMMA_INTERNAL_STORE_PASSWORD")
val internalKeyPassword = internalSetting("COMMA_INTERNAL_KEY_PASSWORD")

// Production versions come from version.properties. CI gives staging its own increasing code.
val appVersion = Properties().apply {
    rootProject.file("version.properties").reader().use { load(it) }
}
val appVersionCode = appVersion.getProperty("versionCode")?.toIntOrNull()
    ?.takeIf { it > 0 } ?: throw GradleException("version.properties needs a positive integer versionCode")
val appVersionName = appVersion.getProperty("versionName")?.trim()
    ?.takeIf { it.isNotEmpty() } ?: throw GradleException("version.properties needs a versionName")
val stagingBuildCode = providers.gradleProperty("comma.stagingVersionCode").map {
    it.toIntOrNull()?.takeIf { code -> code in 1..2100000000 }
        ?: throw GradleException("comma.stagingVersionCode must be in 1..2100000000")
}

fun gitOutput(vararg arguments: String) = providers.exec {
    workingDir(rootProject.projectDir)
    commandLine("git", *arguments)
}.standardOutput.asText.map { it.trim() }
// Only changes inside this Android project mark an internal build dirty.
// Lambdas stored by the configuration cache may use only their parameters, not script properties.
val internalVersionName = providers.provider { appVersionName }.zip(gitOutput("rev-parse", "--short", "HEAD")) { name, sha ->
    "$name-$sha"
}.zip(gitOutput("status", "--porcelain", "--untracked-files=normal", "--", ".")) { version, status ->
    version + if (status.isNotEmpty()) "-dirty" else ""
}

// Validate only packaging/signing tasks, so test/lint and other build types need no key.
val signingFile = internalKeystore.get()
// The keystore must stay outside the whole Git checkout, not only outside this Android project.
val repositoryRoot = generateSequence(rootProject.projectDir.canonicalFile) { it.parentFile }
    .firstOrNull { File(it, ".git").exists() } ?: rootProject.projectDir.canonicalFile
val signingOutsideRepository = !signingFile.canonicalFile.toPath()
    .startsWith(repositoryRoot.toPath())
val missingSigningSettings = listOf(
    "COMMA_INTERNAL_KEY_ALIAS" to internalKeyAlias.get(),
    "COMMA_INTERNAL_STORE_PASSWORD" to internalStorePassword.get(),
    "COMMA_INTERNAL_KEY_PASSWORD" to internalKeyPassword.get(),
).filter { it.second.isBlank() }.map { it.first }
val validateInternalSigning = tasks.register("validateInternalSigningConfig") {
    val file = signingFile
    val outsideRepository = signingOutsideRepository
    val configured = missingSigningSettings.isEmpty()
    val alias = internalKeyAlias.get()
    val storeSecret = internalStorePassword.get()
    val keySecret = internalKeyPassword.get()
    doLast {
        check(outsideRepository && file.isFile && configured) {
            "Internal signing is not configured. Run scripts/create-internal-keystore.sh, " +
                "save its password in a password manager, and configure COMMA_INTERNAL_KEYSTORE, " +
                "COMMA_INTERNAL_KEY_ALIAS, COMMA_INTERNAL_STORE_PASSWORD and " +
                "COMMA_INTERNAL_KEY_PASSWORD via environment variables or local.properties. " +
                "The keystore must exist outside the repository; there is no debug-key fallback."
        }
        val storeChars = storeSecret.toCharArray()
        val keyChars = keySecret.toCharArray()
        try {
            val store = KeyStore.getInstance(file, storeChars)
            check(store.getKey(alias, keyChars) is PrivateKey)
        } catch (_: Exception) {
            throw GradleException("Cannot open the internal signing key. Check the keystore, alias " +
                "and passwords in environment variables or local.properties. Signing settings are not logged.")
        } finally {
            storeChars.fill('\u0000')
            keyChars.fill('\u0000')
        }
    }
}
tasks.matching { it.name in setOf("assembleStagingInternal", "bundleStagingInternal",
    "validateSigningStagingInternal", "packageStagingInternal") }
    .configureEach { dependsOn(validateInternalSigning) }
tasks.matching { it.name.contains("StagingInternal") }
    .configureEach { mustRunAfter(validateInternalSigning) }

android {
    namespace = "surf.comma.android"
    compileSdk { version = release(37) }
    // The SDK packages CI provides (.github/actions/setup-android); AGP would otherwise download its default.
    buildToolsVersion = "37.0.0"
    // The NDK the client core is built with; packaging strips native libraries with its tools.
    ndkVersion = "27.2.12479018"
    defaultConfig {
        applicationId = "surf.comma.android"
        minSdk = 35
        targetSdk = 37
        versionCode = appVersionCode
        versionName = appVersionName
        testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"
        // The client core is built for arm64 alone; another ABI's libraries could not run without it.
        ndk { abiFilters += "arm64-v8a" }
        buildConfigField("String", "DOUBAO_ASR_API_KEY", "\"\"")
        buildConfigField("String", "DOUBAO_ASR_RESOURCE_ID", "\"\"")
        // Sync traffic counters in logcat (no ids, text or credentials); on in debug and internal only.
        buildConfigField("boolean", "SYNC_DIAGNOSTICS", "false")
    }
    flavorDimensions += "environment"
    productFlavors {
        create("dev") {
            dimension = "environment"
            applicationIdSuffix = ".dev"
            resValue("string", "app_name", "Comma Dev")
            buildConfigField("String", "BACKEND_BASE_URL", devBaseUrl.get().asBuildConfigString())
        }
        create("staging") {
            dimension = "environment"
            applicationIdSuffix = ".staging"
            resValue("string", "app_name", "Comma Staging")
            buildConfigField("String", "BACKEND_BASE_URL", "\"https://salix-staging.cue.surf\"")
        }
        create("prod") {
            dimension = "environment"
            resValue("string", "app_name", "Comma")
            buildConfigField("String", "BACKEND_BASE_URL", "\"https://salix.comma.surf\"")
        }
    }
    signingConfigs {
        create("internal") {
            storeFile = signingFile
            keyAlias = internalKeyAlias.get()
            storePassword = internalStorePassword.get()
            keyPassword = internalKeyPassword.get()
        }
    }
    buildTypes {
        debug {
            buildConfigField("String", "DOUBAO_ASR_API_KEY", debugAsrApiKey.get().asBuildConfigString())
            buildConfigField("String", "DOUBAO_ASR_RESOURCE_ID", debugAsrResourceId.get().asBuildConfigString())
            buildConfigField("boolean", "SYNC_DIAGNOSTICS", "true")
        }
        // AGP 9.3 enables code shrinking, obfuscation and resource shrinking together.
        release { optimization { enable = true } }
        create("internal") {
            initWith(getByName("release"))
            isDebuggable = false
            signingConfig = signingConfigs.getByName("internal")
            matchingFallbacks += "release"
            buildConfigField("boolean", "SYNC_DIAGNOSTICS", "true")
            if (internalAsr.get()) {
                buildConfigField("String", "DOUBAO_ASR_API_KEY", debugAsrApiKey.get().asBuildConfigString())
                buildConfigField("String", "DOUBAO_ASR_RESOURCE_ID", debugAsrResourceId.get().asBuildConfigString())
            }
        }
        create("benchmark") {
            initWith(getByName("release"))
            isDebuggable = false
            signingConfig = signingConfigs.getByName("debug")
            matchingFallbacks += "release"
        }
    }
    sourceSets {
        // initWith copies build settings, not source sets. Reuse release's no-op factories.
        getByName("internal").setRoot("src/release")
        getByName("debug").kotlin.directories.add("src/fixtures/java")
        getByName("debug").res.directories.add("src/fixtures/res")
        getByName("benchmark").kotlin.directories.add("src/fixtures/java")
        getByName("benchmark").res.directories.add("src/fixtures/res")
    }
    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
    buildFeatures { buildConfig = true; resValues = true }
    // The client core's module and the libraries it links (Hermes, fbjni) each bring the same shared libraries.
    packaging {
        jniLibs {
            pickFirsts += listOf("**/libc++_shared.so", "**/libhermes.so", "**/libfbjni.so", "**/libjsi.so")
            // React Native's own libraries come with the JSI the client core takes from it, and are not used.
            excludes += listOf("**/libreactnative.so", "**/libhermestooling.so")
        }
    }
    testOptions {
        unitTests.isIncludeAndroidResources = true
        unitTests.all {
            it.systemProperty("robolectric.dependency.repo.url", "https://repo.maven.apache.org/maven2")
            // Background work runs where it is started (surf.comma.android.ui.Background).
            it.systemProperty("comma.background", "inline")
        }
    }
}

// Only dev has a benchmark variant; every release remains fixture-free.
androidComponents.beforeVariants(androidComponents.selector().withBuildType("benchmark")) {
    if (it.productFlavors.none { flavor -> flavor.second == "dev" }) it.enable = false
}
androidComponents.beforeVariants(androidComponents.selector().withBuildType("internal")) {
    if (it.productFlavors.none { flavor -> flavor.second == "staging" }) it.enable = false
}
androidComponents.onVariants(androidComponents.selector().withBuildType("internal")) {
    it.outputs.forEach { output ->
        output.versionName.set(internalVersionName)
        if (stagingBuildCode.isPresent) output.versionCode.set(stagingBuildCode)
    }
}

dependencies {
    implementation("io.coil-kt.coil3:coil-core:3.3.0")
    implementation("io.coil-kt.coil3:coil-gif:3.3.0")
    implementation(libs.androidx.media3.exoplayer)
    implementation(libs.androidx.dynamicanimation)
    implementation(libs.material)
    implementation(libs.androidx.work.runtime)
    implementation(libs.androidx.customview)
    implementation(libs.androidx.activity.ktx)
    implementation(libs.androidx.core.ktx)
    implementation(libs.androidx.lifecycle.runtime.ktx)
    implementation(libs.androidx.lifecycle.process)
    implementation(libs.androidx.lifecycle.viewmodel.ktx)
    implementation(project(":scroll"))
    implementation(project(":core"))
    implementation(libs.ratex.android)
    implementation(libs.kotlinx.coroutines.android)
    implementation(libs.okhttp)
    implementation(libs.androidx.credentials)
    implementation(libs.androidx.credentials.play.services.auth)
    implementation(libs.googleid)
    debugImplementation(libs.androidx.metrics.performance)
    "benchmarkImplementation"(libs.androidx.metrics.performance)
    implementation(libs.androidx.profileinstaller)
    testImplementation(libs.junit)
    testImplementation(libs.robolectric)
    testImplementation(libs.kotlinx.coroutines.test)
    testImplementation(libs.org.json)
    testImplementation(libs.sqlite.jdbc)
    androidTestImplementation(libs.androidx.espresso.core)
    androidTestImplementation(libs.androidx.junit)
}

apply(from = rootProject.file("gradle/check-scroll-usage.gradle.kts"))
