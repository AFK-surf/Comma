#include "engine.h"

#include <time.h>
#if defined(__APPLE__)
#include <stdlib.h>
#else
#include <sys/random.h>
#endif

#include <chrono>
#include <condition_variable>
#include <cstdlib>
#include <cstring>
#include <deque>
#include <functional>
#include <map>
#include <mutex>
#include <unordered_map>
#include <unordered_set>

#include <hermes/hermes.h>
#include <jsi/jsi.h>

namespace jsi = facebook::jsi;

#if defined(COMMA_MESH)
// The phones' iroh (clients/packages/mesh/native, linked in where the app's build defines COMMA_MESH): the core's
// `mesh.*` operations go to it, not to the app, and its answers come back as the app's do.
extern "C" {
typedef void (*comma_mesh_complete)(void*, uint64_t, const uint8_t*, size_t, const uint8_t*, size_t, const uint8_t*, size_t,
                                    uint8_t);
void* comma_mesh_start(comma_mesh_complete complete, void* ctx);
void comma_mesh_call(const void* mesh, uint64_t id, const char* op, const uint8_t* json, size_t json_len,
                     const uint8_t* bytes, size_t bytes_len, uint8_t has_bytes);
void comma_mesh_abort(const void* mesh, uint64_t id);
void comma_mesh_stop(void* mesh);
}
#endif

namespace comma {

namespace {

double clockMs(clockid_t clock) {
  timespec t{};
  clock_gettime(clock, &t);
  return double(t.tv_sec) * 1000.0 + double(t.tv_nsec) / 1e6;
}

/// Timers run on a clock that goes on while the phone sleeps: a 10 s wait begun before a sleep is over after it.
/// Darwin's CLOCK_MONOTONIC counts the sleep; Linux's leaves it out, its CLOCK_BOOTTIME counts it.
double bootMs() {
#if defined(__APPLE__)
  return clockMs(CLOCK_MONOTONIC);
#else
  return clockMs(CLOCK_BOOTTIME);
#endif
}

/// Bytes the runtime keeps as its script.
class Bytes : public jsi::Buffer {
 public:
  explicit Bytes(std::string data) : data_(std::move(data)) {}
  size_t size() const override { return data_.size(); }
  const uint8_t* data() const override { return reinterpret_cast<const uint8_t*>(data_.data()); }

 private:
  std::string data_;
};

void randomBytes(char* out, size_t n) {
#if defined(__APPLE__)
  arc4random_buf(out, n);
#else
  for (size_t at = 0; at < n;) {
    ssize_t got = getrandom(out + at, n - at, 0);
    if (got > 0) at += size_t(got);
  }
#endif
}

}  // namespace

struct Engine::State {
  using Task = std::function<void(jsi::Runtime&)>;

  State(EngineHost& host, std::string script, std::string url, std::string config)
      : host(host), script(std::move(script)), url(std::move(url)), config(std::move(config)) {}

  EngineHost& host;
  std::string script, url, config;
  std::mutex mutex;
  std::condition_variable wake;
  std::deque<Task> tasks;
  std::unordered_map<uint64_t, double> timers;
  std::multimap<double, uint64_t> dues;
  bool stopping = false;
  bool dead = false;

#if defined(COMMA_MESH)
  /// What the mesh's threads answer through: it outlives this core (an answer coming as the core goes finds none).
  struct MeshLink {
    std::mutex mutex;
    State* state;
  };
  MeshLink* meshLink = nullptr;
  void* mesh = nullptr;
  /// The operations the mesh has under way: an `abort` of one of these goes to it.
  std::unordered_set<uint64_t> meshCalls;

  static void meshAnswered(void* ctx, uint64_t id, const uint8_t* json, size_t jsonLen, const uint8_t* error,
                           size_t errorLen, const uint8_t* bytes, size_t bytesLen, uint8_t hasBytes) {
    auto* link = static_cast<MeshLink*>(ctx);
    std::lock_guard<std::mutex> lock(link->mutex);
    if (!link->state) return;
    State& s = *link->state;
    {
      std::lock_guard<std::mutex> calls(s.mutex);
      s.meshCalls.erase(id);
    }
    std::optional<std::string> j, e, b;
    if (errorLen > 0) e = std::string(reinterpret_cast<const char*>(error), errorLen);
    else j = std::string(reinterpret_cast<const char*>(json), jsonLen);
    if (hasBytes) b = std::string(reinterpret_cast<const char*>(bytes), bytesLen);
    s.answer(id, std::move(j), std::move(e), std::move(b));
  }

  void meshCall(uint64_t id, const std::string& op, const std::string& json, const std::string* bytes) {
    if (!mesh) {
      meshLink = new MeshLink{{}, this};
      mesh = comma_mesh_start(&State::meshAnswered, meshLink);
    }
    if (!mesh) {
      answer(id, std::nullopt, std::string("the mesh did not start"), std::nullopt);
      return;
    }
    {
      std::lock_guard<std::mutex> lock(mutex);
      meshCalls.insert(id);
    }
    comma_mesh_call(mesh, id, op.c_str(), reinterpret_cast<const uint8_t*>(json.data()), json.size(),
                    bytes ? reinterpret_cast<const uint8_t*>(bytes->data()) : nullptr, bytes ? bytes->size() : 0,
                    bytes ? 1 : 0);
  }

  /// `abort {"id": n}`: whether n was the mesh's (and it was told).
  bool meshAbort(const std::string& json) {
    size_t at = json.find("\"id\":");
    if (at == std::string::npos || !mesh) return false;
    uint64_t id = std::strtoull(json.c_str() + at + 5, nullptr, 10);
    {
      std::lock_guard<std::mutex> lock(mutex);
      if (meshCalls.erase(id) == 0) return false;
    }
    comma_mesh_abort(mesh, id);
    return true;
  }

  void stopMesh() {
    if (!mesh) return;
    {
      std::lock_guard<std::mutex> lock(meshLink->mutex);
      meshLink->state = nullptr;
    }
    comma_mesh_stop(mesh);
    mesh = nullptr;
  }
#endif

  static jsi::Object core(jsi::Runtime& rt) { return rt.global().getPropertyAsObject(rt, "commaCore"); }

  static jsi::Object arrayBuffer(jsi::Runtime& rt, const void* data, size_t size) {
    jsi::Object buffer = rt.global().getPropertyAsFunction(rt, "ArrayBuffer").callAsConstructor(rt, double(size)).asObject(rt);
    if (size > 0) std::memcpy(buffer.getArrayBuffer(rt).data(rt), data, size);
    return buffer;
  }

  void post(Task task) {
    {
      std::lock_guard<std::mutex> lock(mutex);
      tasks.push_back(std::move(task));
    }
    wake.notify_one();
  }

  /// The answer to operation `id`, given to the script on its thread.
  void answer(uint64_t id, std::optional<std::string> json, std::optional<std::string> error,
              std::optional<std::string> bytes) {
    post([id, json = std::move(json), error = std::move(error), bytes = std::move(bytes)](jsi::Runtime& rt) {
      jsi::Value j = json && !error ? jsi::Value(jsi::String::createFromUtf8(rt, *json)) : jsi::Value::null();
      jsi::Value e = error ? jsi::Value(jsi::String::createFromUtf8(rt, *error)) : jsi::Value::null();
      jsi::Value b = bytes ? jsi::Value(arrayBuffer(rt, bytes->data(), bytes->size())) : jsi::Value::undefined();
      core(rt).getPropertyAsFunction(rt, "complete").callWithThis(rt, core(rt), jsi::Value(double(id)), j, e, b);
    });
  }

  void fatal(const std::string& reason) {
    if (dead) return;
    dead = true;
    host.log(3, "the core failed: " + reason);
    host.fatal(reason);
  }

  void install(jsi::Runtime& rt) {
    jsi::Object native(rt);
    auto fn = [&](const char* name, unsigned args, jsi::HostFunctionType f) {
      native.setProperty(rt, name, jsi::Function::createFromHostFunction(rt, jsi::PropNameID::forAscii(rt, name), args, std::move(f)));
    };
    fn("call", 4, [this](jsi::Runtime& rt, const jsi::Value&, const jsi::Value* a, size_t n) -> jsi::Value {
      uint64_t id = uint64_t(a[0].asNumber());
      std::string op = a[1].asString(rt).utf8(rt);
      std::string json = a[2].asString(rt).utf8(rt);
      std::optional<std::string> bytes;
      if (n > 3 && a[3].isObject() && a[3].asObject(rt).isArrayBuffer(rt)) {
        jsi::ArrayBuffer b = a[3].asObject(rt).getArrayBuffer(rt);
        bytes.emplace(reinterpret_cast<const char*>(b.data(rt)), b.size(rt));
      }
#if defined(COMMA_MESH)
      if (op.rfind("mesh.", 0) == 0) {
        meshCall(id, op, json, bytes ? &*bytes : nullptr);
        return jsi::Value::undefined();
      }
      if (op == "abort" && meshAbort(json)) return jsi::Value::undefined();
#endif
      host.call(id, op, json, bytes ? &*bytes : nullptr);
      return jsi::Value::undefined();
    });
    fn("callSync", 2, [this](jsi::Runtime& rt, const jsi::Value&, const jsi::Value* a, size_t) -> jsi::Value {
      std::optional<std::string> answer = host.callSync(a[0].asString(rt).utf8(rt), a[1].asString(rt).utf8(rt));
      if (!answer) return jsi::String::createFromAscii(rt, "{\"error\":\"the app did not answer\"}");
      return jsi::String::createFromUtf8(rt, *answer);
    });
    fn("emit", 1, [this](jsi::Runtime& rt, const jsi::Value&, const jsi::Value* a, size_t) -> jsi::Value {
      host.emit(a[0].asString(rt).utf8(rt));
      return jsi::Value::undefined();
    });
    fn("fatal", 1, [this](jsi::Runtime& rt, const jsi::Value&, const jsi::Value* a, size_t) -> jsi::Value {
      fatal(a[0].isString() ? a[0].asString(rt).utf8(rt) : "the core failed");
      return jsi::Value::undefined();
    });
    fn("monotonic", 0, [](jsi::Runtime&, const jsi::Value&, const jsi::Value*, size_t) -> jsi::Value { return jsi::Value(clockMs(CLOCK_MONOTONIC)); });
    fn("random", 1, [](jsi::Runtime& rt, const jsi::Value&, const jsi::Value* a, size_t) -> jsi::Value {
      size_t n = size_t(a[0].asNumber());
      std::string bytes(n, '\0');
      randomBytes(bytes.data(), n);
      return arrayBuffer(rt, bytes.data(), n);
    });
    fn("setTimer", 2, [this](jsi::Runtime&, const jsi::Value&, const jsi::Value* a, size_t) -> jsi::Value {
      uint64_t id = uint64_t(a[0].asNumber());
      double due = bootMs() + a[1].asNumber();
      std::lock_guard<std::mutex> lock(mutex);
      timers[id] = due;
      dues.emplace(due, id);
      return jsi::Value::undefined();
    });
    fn("clearTimer", 1, [this](jsi::Runtime&, const jsi::Value&, const jsi::Value* a, size_t) -> jsi::Value {
      std::lock_guard<std::mutex> lock(mutex);
      timers.erase(uint64_t(a[0].asNumber()));
      return jsi::Value::undefined();
    });
    fn("log", 2, [this](jsi::Runtime& rt, const jsi::Value&, const jsi::Value* a, size_t) -> jsi::Value {
      host.log(int(a[0].asNumber()), a[1].asString(rt).utf8(rt));
      return jsi::Value::undefined();
    });
#if defined(COMMA_MESH)
    native.setProperty(rt, "mesh", true);
#endif
    rt.global().setProperty(rt, "commaNative", native);
  }
};

Engine::Engine(EngineHost& host, std::string script, std::string url, std::string config)
    : state_(std::make_unique<State>(host, std::move(script), std::move(url), std::move(config))) {}

Engine::~Engine() {
#if defined(COMMA_MESH)
  state_->stopMesh();
#endif
}

void Engine::receive(std::string json) {
  state_->post([json = std::move(json)](jsi::Runtime& rt) {
    State::core(rt).getPropertyAsFunction(rt, "receive").callWithThis(rt, State::core(rt), jsi::String::createFromUtf8(rt, json));
  });
}

void Engine::rejected(std::string lease, int status) {
  state_->post([lease = std::move(lease), status](jsi::Runtime& rt) {
    State::core(rt).getPropertyAsFunction(rt, "rejected").callWithThis(rt, State::core(rt), jsi::String::createFromUtf8(rt, lease), jsi::Value(status));
  });
}

void Engine::complete(uint64_t id, std::optional<std::string> json, std::optional<std::string> error,
                      std::optional<std::string> bytes) {
  state_->answer(id, std::move(json), std::move(error), std::move(bytes));
}

void Engine::stop() {
  {
    std::lock_guard<std::mutex> lock(state_->mutex);
    state_->stopping = true;
  }
  state_->wake.notify_all();
}

void Engine::run() {
  State& s = *state_;
  auto config = ::hermes::vm::RuntimeConfig::Builder().withMicrotaskQueue(true).withEnableBlockScoping(true).withIntl(true).build();
  std::unique_ptr<facebook::hermes::HermesRuntime> rt = facebook::hermes::makeHermesRuntime(config);
  try {
    s.install(*rt);
    rt->evaluateJavaScript(std::make_shared<Bytes>(std::move(s.script)), s.url);
    State::core(*rt).getPropertyAsFunction(*rt, "start").callWithThis(*rt, State::core(*rt), jsi::String::createFromUtf8(*rt, s.config));
    rt->drainMicrotasks();
  } catch (const std::exception& e) {
    s.fatal(std::string("the core did not start: ") + e.what());
  }
  for (;;) {
    State::Task task;
    uint64_t timer = 0;
    {
      std::unique_lock<std::mutex> lock(s.mutex);
      for (;;) {
        if (s.stopping) break;
        if (!s.tasks.empty()) {
          task = std::move(s.tasks.front());
          s.tasks.pop_front();
          break;
        }
        // The next timer still set (one cleared, or set again later, is passed over).
        while (!s.dues.empty()) {
          auto first = s.dues.begin();
          auto it = s.timers.find(first->second);
          if (it == s.timers.end() || it->second != first->first) {
            s.dues.erase(first);
            continue;
          }
          break;
        }
        if (!s.dues.empty()) {
          double left = s.dues.begin()->first - bootMs();
          if (left <= 0) {
            timer = s.dues.begin()->second;
            s.timers.erase(timer);
            s.dues.erase(s.dues.begin());
            break;
          }
          // Waits on the steady clock; a sleep in between is caught up on as soon as it wakes.
          s.wake.wait_for(lock, std::chrono::microseconds(int64_t(left * 1000)));
        } else {
          s.wake.wait(lock);
        }
      }
      if (s.stopping) break;
    }
    if (s.dead) continue;
    try {
      if (task) task(*rt);
      else rt->global().getPropertyAsFunction(*rt, "commaTimer").call(*rt, jsi::Value(double(timer)));
      rt->drainMicrotasks();
    } catch (const std::exception& e) {
      s.fatal(e.what());
    }
  }
  rt.reset();
}

}  // namespace comma
