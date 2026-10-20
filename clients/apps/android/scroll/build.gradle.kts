/*
 * Copyright (C) 2023 Helixform
 * Modified by the comma authors.
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *      http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

plugins {
    alias(libs.plugins.android.library)
}

android {
    namespace = "surf.comma.android.scroll"
    compileSdk {
        version = release(37)
    }
    buildToolsVersion = "37.0.0"

    defaultConfig {
        minSdk = 35
    }

    buildTypes {
        release {
            consumerProguardFiles("proguard-rules.pro")
        }
    }

    lint {
        // Compatibility branches and framework implementation patterns need these exemptions.
        // Keep them module-local so app lint checks remain enabled.
        disable += setOf(
            "ClickableViewAccessibility",
            "ObsoleteSdkInt",
            "Recycle",
            "SwitchIntDef",
        )
    }

    testOptions {
        unitTests.isIncludeAndroidResources = true
        unitTests.all {
            it.systemProperty("robolectric.dependency.repo.url", "https://repo.maven.apache.org/maven2")
        }
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
}

dependencies {
    api(libs.androidx.annotation)
    api(libs.androidx.core)
    implementation(libs.androidx.collection)
    api(libs.androidx.customview)
    implementation(libs.androidx.customview.poolingcontainer)
    testImplementation(libs.junit)
    testImplementation(libs.robolectric)
}
