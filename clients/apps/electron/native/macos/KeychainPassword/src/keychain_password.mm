#include <node_api.h>

#import <Foundation/Foundation.h>
#import <Security/Security.h>

#include <string>

namespace {

// One read: the promise it settles and the thread-safe function that carries
// the keychain answer back onto the JS thread.
struct PasswordQuery {
  napi_deferred deferred = nullptr;
  napi_threadsafe_function settle = nullptr;
};

struct PasswordAnswer {
  std::string status;
  std::string password;
};

void SettleOnJsThread(napi_env env, napi_value, void *context, void *data) {
  auto *query = static_cast<PasswordQuery *>(context);
  auto *answer = static_cast<PasswordAnswer *>(data);
  if (env != nullptr) {
    napi_value result = nullptr;
    napi_create_object(env, &result);
    napi_value status = nullptr;
    napi_create_string_utf8(env, answer->status.data(), answer->status.size(), &status);
    napi_set_named_property(env, result, "status", status);
    if (answer->status == "found") {
      napi_value password = nullptr;
      napi_create_string_utf8(env, answer->password.data(), answer->password.size(),
                              &password);
      napi_set_named_property(env, result, "password", password);
    }
    napi_resolve_deferred(env, query->deferred, result);
  }
  answer->password.assign(answer->password.size(), '\0');
  delete answer;
  delete query;
}

std::string StatusName(OSStatus status) {
  switch (status) {
    case errSecSuccess:
      return "found";
    case errSecItemNotFound:
      return "missing";
    case errSecUserCanceled:
    case errSecAuthFailed:
    case errSecInteractionNotAllowed:
      return "denied";
    default:
      return "failed";
  }
}

bool ReadString(napi_env env, napi_value value, std::string *out) {
  size_t length = 0;
  if (napi_get_value_string_utf8(env, value, nullptr, 0, &length) != napi_ok) return false;
  if (length == 0 || length > 256) return false;
  out->resize(length + 1);
  napi_get_value_string_utf8(env, value, out->data(), out->size(), &length);
  out->resize(length);
  return true;
}

// Resolves with the password of one generic keychain item, as
// `{ status: "found", password }` or `{ status: "missing" | "denied" | "failed" }`.
// An item that another app owns makes macOS ask the user first. The lookup
// waits for that answer on a GCD queue, so neither the JS thread nor a libuv
// worker of Main waits for the user.
napi_value ReadGenericPassword(napi_env env, napi_callback_info info) {
  size_t argc = 2;
  napi_value argv[2] = {nullptr, nullptr};
  napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr);
  std::string service;
  std::string account;
  if (argc < 2 || !ReadString(env, argv[0], &service) ||
      !ReadString(env, argv[1], &account)) {
    napi_throw_type_error(env, nullptr,
                          "readGenericPassword expects a service and an account");
    return nullptr;
  }

  auto *query = new PasswordQuery();
  napi_value promise = nullptr;
  napi_create_promise(env, &query->deferred, &promise);
  napi_value resource_name = nullptr;
  napi_create_string_utf8(env, "comma_keychain_password", NAPI_AUTO_LENGTH, &resource_name);
  napi_create_threadsafe_function(env, nullptr, nullptr, resource_name, 0, 1, nullptr,
                                  nullptr, query, SettleOnJsThread, &query->settle);
  napi_threadsafe_function settle = query->settle;

  NSString *serviceName = [NSString stringWithUTF8String:service.c_str()];
  NSString *accountName = [NSString stringWithUTF8String:account.c_str()];
  dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
    auto *answer = new PasswordAnswer();
    @autoreleasepool {
      NSDictionary *lookup = @{
        (__bridge id)kSecClass : (__bridge id)kSecClassGenericPassword,
        (__bridge id)kSecAttrService : serviceName,
        (__bridge id)kSecAttrAccount : accountName,
        (__bridge id)kSecMatchLimit : (__bridge id)kSecMatchLimitOne,
        (__bridge id)kSecReturnData : @YES,
      };
      CFTypeRef result = nullptr;
      OSStatus status = SecItemCopyMatching((__bridge CFDictionaryRef)lookup, &result);
      answer->status = StatusName(status);
      if (status == errSecSuccess) {
        NSData *data = CFBridgingRelease(result);
        if (data.length == 0) {
          answer->status = "failed";
        } else {
          answer->password.assign(static_cast<const char *>(data.bytes), data.length);
        }
      }
    }
    napi_call_threadsafe_function(settle, answer, napi_tsfn_blocking);
    napi_release_threadsafe_function(settle, napi_tsfn_release);
  });
  return promise;
}

napi_value Init(napi_env env, napi_value exports) {
  napi_value read = nullptr;
  napi_create_function(env, "readGenericPassword", NAPI_AUTO_LENGTH, ReadGenericPassword,
                       nullptr, &read);
  napi_set_named_property(env, exports, "readGenericPassword", read);
  return exports;
}

}  // namespace

NAPI_MODULE(NODE_GYP_MODULE_NAME, Init)
