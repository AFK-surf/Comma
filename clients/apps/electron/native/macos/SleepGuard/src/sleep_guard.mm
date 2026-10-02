#include <node_api.h>

#import <Foundation/Foundation.h>
#import <ServiceManagement/ServiceManagement.h>
#include <xpc/xpc.h>

#include <cstdlib>
#include <cstring>
#include <string>

namespace {

// One request in flight: the promise it settles and the thread-safe function
// that carries the daemon's reply back onto the JS thread.
struct Request {
  napi_deferred deferred = nullptr;
  napi_threadsafe_function settle = nullptr;
};

struct Reply {
  bool ok = false;
  char *error = nullptr;
};

// The one connection to the guard daemon. Holding it open is what holds the
// Mac awake: when Main exits or crashes the kernel drops it and the daemon
// restores sleep. Touched only on `queue`.
dispatch_queue_t queue = nullptr;
xpc_connection_t connection = nullptr;
std::string connected_service;
bool desired_disabled = false;

std::string StringArgument(napi_env env, napi_value value) {
  size_t length = 0;
  napi_get_value_string_utf8(env, value, nullptr, 0, &length);
  std::string result(length, '\0');
  napi_get_value_string_utf8(env, value, result.data(), length + 1, &length);
  return result;
}

napi_value MakeString(napi_env env, const char *value) {
  napi_value result = nullptr;
  napi_create_string_utf8(env, value, NAPI_AUTO_LENGTH, &result);
  return result;
}

const char *StatusName(SMAppServiceStatus status) {
  switch (status) {
    case SMAppServiceStatusEnabled:
      return "enabled";
    case SMAppServiceStatusRequiresApproval:
      return "requiresApproval";
    case SMAppServiceStatusNotFound:
      return "notFound";
    case SMAppServiceStatusNotRegistered:
    default:
      return "notRegistered";
  }
}

SMAppService *Daemon(napi_env env, napi_callback_info info) {
  size_t argc = 1;
  napi_value argv[1] = {nullptr};
  napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr);
  if (argc < 1) return nil;
  NSString *plist = [NSString stringWithUTF8String:StringArgument(env, argv[0]).c_str()];
  return [SMAppService daemonServiceWithPlistName:plist];
}

// status(plistName): the daemon's registration as System Settings sees it.
napi_value Status(napi_env env, napi_callback_info info) {
  SMAppService *daemon = Daemon(env, info);
  return MakeString(env, daemon ? StatusName(daemon.status) : "notFound");
}

// register(plistName): registers the daemon; the first time this leaves it
// waiting for the user's approval in Login Items. Returns { status, error? }:
// the new status, and macOS's reason when it refused. A registration that
// waits for approval also reports an error, so callers judge by the status.
napi_value Register(napi_env env, napi_callback_info info) {
  napi_value result = nullptr;
  napi_create_object(env, &result);
  SMAppService *daemon = Daemon(env, info);
  NSError *error = nil;
  if (daemon) [daemon registerAndReturnError:&error];
  napi_set_named_property(env, result, "status",
                          MakeString(env, daemon ? StatusName(daemon.status) : "notFound"));
  if (error) {
    napi_set_named_property(env, result, "error",
                            MakeString(env, error.localizedDescription.UTF8String));
  }
  return result;
}

// openLoginItemsSettings(): where the user approves the daemon.
napi_value OpenLoginItemsSettings(napi_env env, napi_callback_info) {
  [SMAppService openSystemSettingsLoginItems];
  return nullptr;
}

void SettleOnJsThread(napi_env env, napi_value, void *context, void *data) {
  auto *request = static_cast<Request *>(context);
  auto *reply = static_cast<Reply *>(data);
  if (env != nullptr) {
    napi_value result = nullptr;
    napi_create_object(env, &result);
    napi_value ok = nullptr;
    napi_get_boolean(env, reply->ok, &ok);
    napi_set_named_property(env, result, "ok", ok);
    if (reply->error) {
      napi_set_named_property(env, result, "error", MakeString(env, reply->error));
    }
    napi_resolve_deferred(env, request->deferred, result);
  }
  free(reply->error);
  delete reply;
  delete request;
}

void Settle(napi_threadsafe_function settle, bool ok, const char *error) {
  auto *reply = new Reply{ok, error ? strdup(error) : nullptr};
  napi_call_threadsafe_function(settle, reply, napi_tsfn_blocking);
  napi_release_threadsafe_function(settle, napi_tsfn_release);
}

void Send(bool disable, void (^completion)(bool ok, const char *error));

xpc_connection_t Connect(const std::string &service) {
  if (connection && connected_service == service) return connection;
  if (connection) xpc_connection_cancel(connection);
  connected_service = service;
  connection = xpc_connection_create_mach_service(service.c_str(), queue,
                                                  XPC_CONNECTION_MACH_SERVICE_PRIVILEGED);
  xpc_connection_t current = connection;
  xpc_connection_set_event_handler(current, ^(xpc_object_t event) {
    if (event == XPC_ERROR_CONNECTION_INTERRUPTED) {
      // The daemon restarted and lost this connection's hold; take it again.
      if (desired_disabled && connection == current) Send(true, nil);
    } else if (event == XPC_ERROR_CONNECTION_INVALID) {
      if (connection == current) connection = nullptr;
    }
  });
  xpc_connection_resume(current);
  return current;
}

void Send(bool disable, void (^completion)(bool ok, const char *error)) {
  xpc_object_t message = xpc_dictionary_create(nullptr, nullptr, 0);
  xpc_dictionary_set_bool(message, "disable", disable);
  xpc_connection_send_message_with_reply(
      Connect(connected_service), message, queue, ^(xpc_object_t reply) {
        if (!completion) return;
        if (xpc_get_type(reply) != XPC_TYPE_DICTIONARY) {
          completion(false, "The sleep guard did not answer.");
          return;
        }
        completion(xpc_dictionary_get_bool(reply, "ok"),
                   xpc_dictionary_get_string(reply, "error"));
      });
}

// setSleepDisabled(serviceName, disabled): asks the daemon to hold or release
// the `SleepDisabled` flag for this process. Resolves { ok, error? }.
napi_value SetSleepDisabled(napi_env env, napi_callback_info info) {
  size_t argc = 2;
  napi_value argv[2] = {nullptr, nullptr};
  napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr);
  std::string service = argc > 0 ? StringArgument(env, argv[0]) : "";
  bool disable = false;
  if (argc > 1) napi_get_value_bool(env, argv[1], &disable);

  auto *request = new Request();
  napi_value promise = nullptr;
  napi_create_promise(env, &request->deferred, &promise);
  napi_value resource_name = MakeString(env, "comma_sleep_guard");
  napi_create_threadsafe_function(env, nullptr, nullptr, resource_name, 0, 1, nullptr,
                                  nullptr, request, SettleOnJsThread, &request->settle);
  napi_threadsafe_function settle = request->settle;

  dispatch_async(queue, ^{
    if (!disable && !connection) {
      desired_disabled = false;
      Settle(settle, true, nullptr);
      return;
    }
    desired_disabled = disable;
    Connect(service);
    Send(disable, ^(bool ok, const char *error) {
      if (!ok && disable) desired_disabled = false;
      Settle(settle, ok, error);
    });
  });
  return promise;
}

napi_value Init(napi_env env, napi_value exports) {
  queue = dispatch_queue_create("comma.sleep-guard", DISPATCH_QUEUE_SERIAL);
  napi_property_descriptor properties[] = {
      {"status", nullptr, Status, nullptr, nullptr, nullptr, napi_default, nullptr},
      {"register", nullptr, Register, nullptr, nullptr, nullptr, napi_default, nullptr},
      {"openLoginItemsSettings", nullptr, OpenLoginItemsSettings, nullptr, nullptr, nullptr,
       napi_default, nullptr},
      {"setSleepDisabled", nullptr, SetSleepDisabled, nullptr, nullptr, nullptr, napi_default,
       nullptr},
  };
  napi_define_properties(env, exports, sizeof(properties) / sizeof(properties[0]), properties);
  return exports;
}

}  // namespace

NAPI_MODULE(NODE_GYP_MODULE_NAME, Init)
