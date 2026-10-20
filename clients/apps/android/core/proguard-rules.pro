# The engine (src/main/cpp/engine.cpp) calls these by name.
-keep class surf.comma.android.core.EngineHost { *; }
-keep class surf.comma.android.core.HermesNative { *; }
# Hermes reaches its platform support (Intl, Unicode) by name through fbjni.
-keep class com.facebook.hermes.** { *; }
-keep class com.facebook.jni.** { *; }
# React Native's Hermes profiler (react-android, taken for its JSI alone) loads through SoLoader, which is left out.
-dontwarn com.facebook.soloader.SoLoader
