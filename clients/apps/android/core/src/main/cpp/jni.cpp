// The client core's engine (packages/core/native/engine.cpp) for the Android app. HermesEngine.kt starts the core's
// thread and calls `run` on it, so Java classes resolve there as they do anywhere in the app; the engine's calls to the
// app go to the Kotlin EngineHost on that thread.
#include <jni.h>
#include <android/log.h>

#include <memory>
#include <optional>
#include <string>

#include "engine.h"

namespace {

const char* TAG = "CommaCore";

std::string bytesOf(JNIEnv* env, jbyteArray array) {
  if (!array) return {};
  jsize n = env->GetArrayLength(array);
  std::string out(size_t(n), '\0');
  env->GetByteArrayRegion(array, 0, n, reinterpret_cast<jbyte*>(out.data()));
  return out;
}

jbyteArray arrayOf(JNIEnv* env, const void* data, size_t size) {
  jbyteArray array = env->NewByteArray(jsize(size));
  if (size > 0) env->SetByteArrayRegion(array, 0, jsize(size), reinterpret_cast<const jbyte*>(data));
  return array;
}

/// The Kotlin EngineHost, called on the core's thread with that thread's JNIEnv.
class JniHost : public comma::EngineHost {
 public:
  JniHost(JNIEnv* env, jobject host) : host_(env->NewGlobalRef(host)) {
    jclass cls = env->GetObjectClass(host);
    call_ = env->GetMethodID(cls, "call", "(JLjava/lang/String;[B[B)V");
    callSync_ = env->GetMethodID(cls, "callSync", "(Ljava/lang/String;[B)[B");
    emit_ = env->GetMethodID(cls, "emit", "([B)V");
    fatal_ = env->GetMethodID(cls, "fatal", "([B)V");
    env->DeleteLocalRef(cls);
  }

  void attach(JNIEnv* env) { env_ = env; }
  void release(JNIEnv* env) { env->DeleteGlobalRef(host_); }

  void call(uint64_t id, const std::string& op, const std::string& json, const std::string* bytes) override {
    jstring name = env_->NewStringUTF(op.c_str());
    jbyteArray jsonBytes = arrayOf(env_, json.data(), json.size());
    jbyteArray body = bytes ? arrayOf(env_, bytes->data(), bytes->size()) : nullptr;
    env_->CallVoidMethod(host_, call_, jlong(id), name, jsonBytes, body);
    env_->DeleteLocalRef(name);
    env_->DeleteLocalRef(jsonBytes);
    if (body) env_->DeleteLocalRef(body);
    clearException();
  }

  std::optional<std::string> callSync(const std::string& op, const std::string& json) override {
    jstring name = env_->NewStringUTF(op.c_str());
    jbyteArray jsonBytes = arrayOf(env_, json.data(), json.size());
    auto answer = static_cast<jbyteArray>(env_->CallObjectMethod(host_, callSync_, name, jsonBytes));
    env_->DeleteLocalRef(name);
    env_->DeleteLocalRef(jsonBytes);
    if (env_->ExceptionCheck() || !answer) {
      clearException();
      return std::nullopt;
    }
    std::string out = bytesOf(env_, answer);
    env_->DeleteLocalRef(answer);
    return out;
  }

  void emit(const std::string& json) override {
    // Modified UTF-8 is not UTF-8 (an emoji would be wrong): the bytes go as they are, made a String in Kotlin.
    jbyteArray bytes = arrayOf(env_, json.data(), json.size());
    env_->CallVoidMethod(host_, emit_, bytes);
    env_->DeleteLocalRef(bytes);
    clearException();
  }

  void fatal(const std::string& reason) override {
    jbyteArray bytes = arrayOf(env_, reason.data(), reason.size());
    env_->CallVoidMethod(host_, fatal_, bytes);
    env_->DeleteLocalRef(bytes);
    clearException();
  }

  void log(int level, const std::string& message) override {
    int priority = level >= 3 ? ANDROID_LOG_ERROR : level == 2 ? ANDROID_LOG_WARN : level == 1 ? ANDROID_LOG_INFO : ANDROID_LOG_DEBUG;
    __android_log_print(priority, TAG, "%s", message.c_str());
  }

 private:
  /// An exception the app threw into a call is said in the log and dropped: left pending, it would abort the app at
  /// the next JNI call.
  void clearException() {
    if (!env_->ExceptionCheck()) return;
    env_->ExceptionDescribe();
    env_->ExceptionClear();
  }

  JNIEnv* env_ = nullptr;
  jobject host_;
  jmethodID call_ = nullptr;
  jmethodID callSync_ = nullptr;
  jmethodID emit_ = nullptr;
  jmethodID fatal_ = nullptr;
};

struct Handle {
  Handle(JNIEnv* env, jobject host, std::string script, std::string url, std::string config)
      : host(env, host), engine(this->host, std::move(script), std::move(url), std::move(config)) {}
  JniHost host;
  comma::Engine engine;
};

Handle* handle(jlong value) { return reinterpret_cast<Handle*>(value); }

std::optional<std::string> optionalBytes(JNIEnv* env, jbyteArray array) {
  if (!array) return std::nullopt;
  return bytesOf(env, array);
}

}  // namespace

extern "C" JNIEXPORT jlong JNICALL Java_surf_comma_android_core_HermesNative_create(JNIEnv* env, jobject, jbyteArray script, jbyteArray url, jbyteArray config, jobject host) {
  return reinterpret_cast<jlong>(new Handle(env, host, bytesOf(env, script), bytesOf(env, url), bytesOf(env, config)));
}

extern "C" JNIEXPORT void JNICALL Java_surf_comma_android_core_HermesNative_run(JNIEnv* env, jobject, jlong value) {
  handle(value)->host.attach(env);
  handle(value)->engine.run();
  handle(value)->host.attach(nullptr);
}

extern "C" JNIEXPORT void JNICALL Java_surf_comma_android_core_HermesNative_receive(JNIEnv* env, jobject, jlong value, jbyteArray json) {
  handle(value)->engine.receive(bytesOf(env, json));
}

extern "C" JNIEXPORT void JNICALL Java_surf_comma_android_core_HermesNative_rejected(JNIEnv* env, jobject, jlong value, jbyteArray lease, jint status) {
  handle(value)->engine.rejected(bytesOf(env, lease), int(status));
}

extern "C" JNIEXPORT void JNICALL Java_surf_comma_android_core_HermesNative_complete(JNIEnv* env, jobject, jlong value, jlong id, jbyteArray json, jbyteArray error, jbyteArray bytes) {
  handle(value)->engine.complete(uint64_t(id), optionalBytes(env, json), optionalBytes(env, error), optionalBytes(env, bytes));
}

extern "C" JNIEXPORT void JNICALL Java_surf_comma_android_core_HermesNative_stop(JNIEnv*, jobject, jlong value) {
  handle(value)->engine.stop();
}

extern "C" JNIEXPORT void JNICALL Java_surf_comma_android_core_HermesNative_destroy(JNIEnv* env, jobject, jlong value) {
  handle(value)->host.release(env);
  delete handle(value);
}
