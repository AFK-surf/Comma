// The client core and its Kotlin API. The core is the TypeScript one (clients/packages/core), run by Hermes
// (clients/packages/core/native/engine.cpp, which the iOS app shares, through src/main/cpp/jni.cpp); what it needs of
// the platform (requests, the credential store, SQLite) is in Kotlin.
// `bundleCore` compiles the core's script to Hermes bytecode with the repository's Node tools, so `pnpm install`
// must have run at the repository root.
plugins {
    alias(libs.plugins.android.library)
}

/** Runs the core's bundle script: its bytecode is an asset of every variant. */
@CacheableTask
abstract class BundleCore @Inject constructor(private val exec: ExecOperations) : DefaultTask() {
    @get:InputFiles
    @get:PathSensitive(PathSensitivity.RELATIVE)
    abstract val sources: ConfigurableFileCollection

    @get:Internal
    abstract val packageDir: DirectoryProperty

    @get:OutputDirectory
    abstract val assets: DirectoryProperty

    @get:Internal
    abstract val scratch: DirectoryProperty

    @TaskAction
    fun bundle() {
        exec.exec {
            workingDir = packageDir.get().asFile
            commandLine(
                "node", "scripts/mobile-bundle.ts",
                scratch.get().file("core.js").asFile.path,
                assets.get().file("core.hbc").asFile.path,
            )
        }
    }
}

val repositoryRoot = rootProject.layout.projectDirectory.dir("../../..")

val bundleCore = tasks.register<BundleCore>("bundleCore") {
    description = "Compiles the client core to Hermes bytecode."
    val packages = repositoryRoot.dir("clients/packages")
    sources.from(fileTree(packages) {
        include("core/src/**", "core/scripts/**", "core/package.json")
        include("core-kernel/src/**", "chat-contract/src/**", "session-contract/src/**")
        include("recommendation-contract/src/**", "mesh/src/**", "i18n/src/**", "i18n/messages/**")
        exclude("**/*.test.ts", "**/test/**", "**/testing/**")
    })
    sources.from(repositoryRoot.file("pnpm-lock.yaml"))
    sources.from(rootProject.layout.projectDirectory.file("gradle/libs.versions.toml"))
    packageDir.set(repositoryRoot.dir("clients/packages/core"))
    scratch.set(layout.buildDirectory.dir("intermediates/core-script"))
}

android {
    namespace = "surf.comma.android.core"
    compileSdk {
        version = release(37)
    }
    buildToolsVersion = "37.0.0"
    ndkVersion = "27.2.12479018"

    defaultConfig {
        minSdk = 35
        ndk { abiFilters += "arm64-v8a" }
        externalNativeBuild { cmake { arguments += listOf("-DANDROID_STL=c++_shared") } }
        consumerProguardFiles("proguard-rules.pro")
        testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"
    }
    buildFeatures { prefab = true }
    externalNativeBuild { cmake { path = file("src/main/cpp/CMakeLists.txt") } }

    // Hermes and fbjni each bring the C++ runtime the NDK puts in too. The device tests' APK also gets the libraries
    // the core links from both this module and their packages.
    packaging {
        jniLibs { pickFirsts += listOf("**/libc++_shared.so", "**/libhermes.so", "**/libfbjni.so", "**/libjsi.so") }
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
}

// `-Pcomma.clientCore=false` builds without the core's bytecode (and so without Node): the unit tests run a test core
// and never load it, and CI runs them so.
val withClientCore = providers.gradleProperty("comma.clientCore").orNull != "false"

androidComponents.onVariants { variant ->
    if (withClientCore) variant.sources.assets?.addGeneratedSourceDirectory(bundleCore, BundleCore::assets)
}

dependencies {
    api(libs.kotlinx.coroutines.android)
    api(libs.okhttp)
    implementation(libs.hermes.android)
    implementation(libs.nativeloader)
    // Only for its JSI: none of React Native's own libraries or classes.
    implementation(libs.react.android) { isTransitive = false }
    implementation(libs.androidx.sqlite.bundled)
    testImplementation(libs.junit)
    testImplementation(libs.kotlinx.coroutines.test)
    testImplementation(libs.okhttp.mockwebserver)
    testImplementation(libs.org.json)
    // Device tests run the Hermes the app carries. React Native's resources refer to AppCompat, which the app gets
    // with Material.
    androidTestImplementation(libs.junit)
    androidTestImplementation(libs.androidx.test.runner)
    androidTestImplementation(libs.material)
}
