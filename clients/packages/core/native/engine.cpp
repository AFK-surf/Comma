#include "engine.h"

#include <time.h>
#if defined(__APPLE__)
#include <stdlib.h>
#else
#include <sys/random.h>
#endif

#include <chrono>
#include <condition_variable>
#include <cstring>
#include <deque>
#include <functional>
#include <map>
#include <mutex>
#include <unordered_map>

#include <hermes/hermes.h>
#include <jsi/jsi.h>

namespace jsi = facebook::jsi;

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
      if (n > 3 && a[3].isObject() && a[3].asObject(rt).isArrayBuffer(rt)) {
        jsi::ArrayBuffer b = a[3].asObject(rt).getArrayBuffer(rt);
        std::string bytes(reinterpret_cast<const char*>(b.data(rt)), b.size(rt));
        host.call(id, op, json, &bytes);
      } else {
        host.call(id, op, json, nullptr);
      }
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
    rt.global().setProperty(rt, "commaNative", native);
  }
};

Engine::Engine(EngineHost& host, std::string script, std::string url, std::string config)
    : state_(std::make_unique<State>(host, std::move(script), std::move(url), std::move(config))) {}

Engine::~Engine() = default;

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
  state_->post([id, json = std::move(json), error = std::move(error), bytes = std::move(bytes)](jsi::Runtime& rt) {
    jsi::Value j = json && !error ? jsi::Value(jsi::String::createFromUtf8(rt, *json)) : jsi::Value::null();
    jsi::Value e = error ? jsi::Value(jsi::String::createFromUtf8(rt, *error)) : jsi::Value::null();
    jsi::Value b = bytes ? jsi::Value(State::arrayBuffer(rt, bytes->data(), bytes->size())) : jsi::Value::undefined();
    State::core(rt).getPropertyAsFunction(rt, "complete").callWithThis(rt, State::core(rt), jsi::Value(double(id)), j, e, b);
  });
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
