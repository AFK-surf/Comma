// Top-level build file where you can add configuration options common to all sub-projects/modules.
plugins {
    alias(libs.plugins.android.test) apply false
    alias(libs.plugins.android.application) apply false
    alias(libs.plugins.android.library) apply false
    alias(libs.plugins.aboutlibraries) apply false
}

// Gradle downloads Robolectric's Android framework jars, so they come from its
// dependency cache (shared between CI runners) with its timeouts and retries.
// The unit tests read them offline from this directory instead of fetching
// them from Maven Central while they run.
// One configuration per SDK: in one, Gradle would keep only the newer version.
val robolectricSdk35: Configuration by configurations.creating { isTransitive = false }
val robolectricSdk37: Configuration by configurations.creating { isTransitive = false }
dependencies {
    robolectricSdk35(libs.robolectric.androidAll.sdk35)
    robolectricSdk37(libs.robolectric.androidAll.sdk37)
}
tasks.register<Sync>("robolectricJars") {
    from(robolectricSdk35, robolectricSdk37)
    into(layout.buildDirectory.dir("robolectric"))
}
