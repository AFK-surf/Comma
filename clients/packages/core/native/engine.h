// The client core in Hermes, as the phone apps run it (packages/core/src/hosts/mobile.ts, compiled to bytecode by
// scripts/mobile-bundle.ts). The Android app reaches it through JNI (apps/android/core/src/main/cpp/jni.cpp), the iOS
// app through Objective-C++ (apps/apple/iOS/Core/CommaEngine.mm); both give it an `EngineHost` and run its loop on a
// thread of their own.
#pragma once

#include <cstddef>
#include <cstdint>
#include <memory>
#include <optional>
#include <string>

namespace comma {

/**
 * What a running core asks of the app, called on the core's own thread (the one in `Engine::run`). `call` returns at
 * once and is answered later through `Engine::complete`; `callSync` answers before it returns. Built with COMMA_MESH
 * (the phones' iroh linked in), the engine answers the core's `mesh.*` operations itself: the app never gets them.
 */
class EngineHost {
 public:
  virtual ~EngineHost() = default;
  /** Starts operation `id`. `bytes` is null when the call carries none. */
  virtual void call(uint64_t id, const std::string& op, const std::string& json, const std::string* bytes) = 0;
  /** The answer as JSON (`{"value": …}` or `{"error": …}`); none when the app could not answer at all. */
  virtual std::optional<std::string> callSync(const std::string& op, const std::string& json) = 0;
  /** What the core says to the app's UI, as UTF-8 JSON. */
  virtual void emit(const std::string& json) = 0;
  /**
   * One frame of a screen view the app opened with `sink` (core screen-views.ts, `commaNative.screenFrame`): `kind` 1
   * is an H.264 config and 2 an H.265 one (`data` its avcC or hvcC, `width` and `height` the picture's), 3 a video
   * frame and 4 a key frame (`data` its access unit, as the config says, `ts` its time). `data` is the script's memory,
   * valid only during the call: the app copies what it keeps. Called on the core's thread, once a frame; no JSON.
   */
  virtual void screenFrame(uint32_t sink, int kind, double ts, int width, int height, const uint8_t* data, size_t size) {}
  /** The core cannot go on; nothing else comes from it. */
  virtual void fatal(const std::string& reason) = 0;
  /** A line for the platform's log: 0 debug, 1 info, 2 warning, 3 error. */
  virtual void log(int level, const std::string& message) = 0;
};

/**
 * One core: the Hermes runtime and its loop. Tasks posted to it, timers due, microtasks drained after each. A
 * JavaScript error that escapes, or a bug the core reports, ends this core (`EngineHost::fatal`); the app starts
 * another. Everything but `run` may be called from any thread.
 */
class Engine {
 public:
  Engine(EngineHost& host, std::string script, std::string url, std::string config);
  ~Engine();
  Engine(const Engine&) = delete;
  Engine& operator=(const Engine&) = delete;

  /** What the app's UI says. */
  void receive(std::string json);
  /** The app saw the server refuse a request made for `lease` (JSON) with `status` (401 or 409). */
  void rejected(std::string lease, int status);
  /** The app's answer to operation `id`: `error` when it failed. */
  void complete(uint64_t id, std::optional<std::string> json, std::optional<std::string> error,
                std::optional<std::string> bytes);
  /** Ends the loop: `run` returns once the task under way has finished. */
  void stop();
  /** The loop, on the calling thread, until `stop`. */
  void run();

 private:
  struct State;
  std::unique_ptr<State> state_;
};

}  // namespace comma
