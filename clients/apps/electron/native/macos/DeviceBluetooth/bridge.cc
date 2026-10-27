#include <node_api.h>
#include <string>
#include <unordered_map>

extern "C" void comma_ble_request(int32_t, const char *, const char *, void (*)(int32_t, const char *, const char *));
namespace {
struct Answer { int32_t id; std::string json; std::string error; };
napi_threadsafe_function replies = nullptr;
std::unordered_map<int32_t, napi_deferred> waiting;
int32_t next = 0;
void Reply(int32_t id, const char *json, const char *error) {
  auto *answer = new Answer{id, json ? json : "null", error ? error : ""};
  if (napi_call_threadsafe_function(replies, answer, napi_tsfn_nonblocking) != napi_ok) delete answer;
}
void Deliver(napi_env env, napi_value, void *, void *data) {
  auto *answer = static_cast<Answer *>(data);
  if (env) {
    auto found = waiting.find(answer->id);
    if (found != waiting.end()) {
      napi_value value;
      const std::string &text = answer->error.empty() ? answer->json : answer->error;
      napi_create_string_utf8(env, text.c_str(), text.size(), &value);
      if (answer->error.empty()) napi_resolve_deferred(env, found->second, value);
      else { napi_value error; napi_create_error(env, nullptr, value, &error); napi_reject_deferred(env, found->second, error); }
      waiting.erase(found);
    }
  }
  delete answer;
}
std::string Text(napi_env env, napi_value value) {
  size_t length = 0; napi_get_value_string_utf8(env, value, nullptr, 0, &length);
  std::string text(length + 1, '\0'); napi_get_value_string_utf8(env, value, text.data(), text.size(), &length); text.resize(length); return text;
}
napi_value Call(napi_env env, napi_callback_info info) {
  size_t count = 2; napi_value args[2]; napi_get_cb_info(env, info, &count, args, nullptr, nullptr);
  napi_valuetype a, b;
  if (count != 2 || napi_typeof(env, args[0], &a) != napi_ok || napi_typeof(env, args[1], &b) != napi_ok || a != napi_string || b != napi_string || waiting.size() >= 64) {
    napi_throw_error(env, nullptr, "Invalid or busy Bluetooth request"); return nullptr;
  }
  napi_value promise; napi_deferred deferred; napi_create_promise(env, &deferred, &promise);
  const int32_t id = ++next; waiting.emplace(id, deferred);
  auto op = Text(env, args[0]); auto json = Text(env, args[1]); comma_ble_request(id, op.c_str(), json.c_str(), Reply);
  return promise;
}
napi_value Init(napi_env env, napi_value exports) {
  napi_value name; napi_create_string_utf8(env, "Comma device Bluetooth", NAPI_AUTO_LENGTH, &name);
  napi_create_threadsafe_function(env, nullptr, nullptr, name, 128, 1, nullptr, nullptr, nullptr, Deliver, &replies);
  napi_unref_threadsafe_function(env, replies);
  napi_value call; napi_create_function(env, "call", NAPI_AUTO_LENGTH, Call, nullptr, &call); napi_set_named_property(env, exports, "call", call);
  return exports;
}
}
NAPI_MODULE(NODE_GYP_MODULE_NAME, Init)
