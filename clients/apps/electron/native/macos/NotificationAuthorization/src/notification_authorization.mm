#include <node_api.h>

#import <Foundation/Foundation.h>
#import <UserNotifications/UserNotifications.h>

#include <cstdlib>
#include <cstring>

namespace {

// One in-flight query: the promise it settles and the thread-safe function
// that carries the UserNotifications completion back onto the JS thread.
struct StatusQuery {
  napi_deferred deferred = nullptr;
  napi_threadsafe_function settle = nullptr;
};

const char *StatusName(UNAuthorizationStatus status) {
  switch (status) {
    case UNAuthorizationStatusDenied:
      return "denied";
    case UNAuthorizationStatusAuthorized:
      return "authorized";
    case UNAuthorizationStatusProvisional:
      return "provisional";
    case UNAuthorizationStatusNotDetermined:
      return "notDetermined";
    default:
      // `UNAuthorizationStatusEphemeral` is iOS-only; the switch stays open
      // for it and any status a newer SDK adds.
      return "notDetermined";
  }
}

// Runs on the JS thread once the completion handler (or the no-bundle path)
// has handed over the status name. `env` is null only while the environment
// is tearing down, when there is no promise left to settle.
void SettleOnJsThread(napi_env env, napi_value, void *context, void *data) {
  auto *query = static_cast<StatusQuery *>(context);
  auto *status = static_cast<char *>(data);
  if (env != nullptr) {
    napi_value value = nullptr;
    napi_create_string_utf8(env, status, NAPI_AUTO_LENGTH, &value);
    napi_resolve_deferred(env, query->deferred, value);
  }
  free(status);
  delete query;
}

void Settle(napi_threadsafe_function settle, const char *status) {
  napi_call_threadsafe_function(settle, strdup(status), napi_tsfn_blocking);
  napi_release_threadsafe_function(settle, napi_tsfn_release);
}

// Creates the promise a query resolves and the thread-safe function that will
// resolve it from the UserNotifications completion queue.
napi_value BeginQuery(napi_env env, napi_threadsafe_function *settle) {
  auto *query = new StatusQuery();
  napi_value promise = nullptr;
  napi_create_promise(env, &query->deferred, &promise);

  napi_value resource_name = nullptr;
  napi_create_string_utf8(env, "comma_notification_authorization", NAPI_AUTO_LENGTH,
                          &resource_name);
  napi_create_threadsafe_function(env, nullptr, nullptr, resource_name, 0, 1, nullptr,
                                  nullptr, query, SettleOnJsThread, &query->settle);
  *settle = query->settle;
  return promise;
}

// Authorization is tracked per bundle. Outside one (a bare node process)
// there is nothing to ask for, and UserNotifications raises rather than
// answering; the raise is also caught so a surprise from the framework can
// never take the whole Main process down with it.
UNUserNotificationCenter *CurrentCenter() {
  if ([[NSBundle mainBundle] bundleIdentifier] == nil) return nil;
  @try {
    return [UNUserNotificationCenter currentNotificationCenter];
  } @catch (NSException *) {
    return nil;
  }
}

void SettleWithCurrentStatus(UNUserNotificationCenter *center,
                             napi_threadsafe_function settle) {
  [center getNotificationSettingsWithCompletionHandler:^(UNNotificationSettings *settings) {
    Settle(settle, StatusName(settings.authorizationStatus));
  }];
}

// Resolves with the UNAuthorizationStatus name of the current process, which
// is why this lives in-process: a helper executable would only ever be able
// to report its own status, not Comma's.
napi_value AuthorizationStatus(napi_env env, napi_callback_info) {
  napi_threadsafe_function settle = nullptr;
  napi_value promise = BeginQuery(env, &settle);
  UNUserNotificationCenter *center = CurrentCenter();
  if (center == nil) {
    Settle(settle, "unavailable");
    return promise;
  }
  SettleWithCurrentStatus(center, settle);
  return promise;
}

// Asks the OS for permission to post banners and resolves with the status the
// user's answer leaves behind. Only a `notDetermined` process gets the system
// prompt; once decided the framework answers from its record without asking
// again, so calling this before every first banner is free. Electron fires
// the same request from its notification presenter but never awaits it and
// posts regardless, which is exactly the banner that gets refused.
napi_value RequestAuthorization(napi_env env, napi_callback_info) {
  napi_threadsafe_function settle = nullptr;
  napi_value promise = BeginQuery(env, &settle);
  UNUserNotificationCenter *center = CurrentCenter();
  if (center == nil) {
    Settle(settle, "unavailable");
    return promise;
  }
  [center requestAuthorizationWithOptions:(UNAuthorizationOptionAlert | UNAuthorizationOptionSound |
                                           UNAuthorizationOptionBadge)
                        completionHandler:^(BOOL, NSError *) {
                          // `granted` collapses provisional and authorized and
                          // an error still leaves a definite status behind;
                          // the settings query is the one source of truth.
                          SettleWithCurrentStatus(center, settle);
                        }];
  return promise;
}

// Shows `count` on the app icon through UserNotifications, which owns the
// badge the "Badge application icon" switch in System Settings governs. The
// switch is read first: with it off the badge is cleared instead, so a count
// raised while it was off never appears when it is turned back on. Resolves
// with "shown", "cleared" or "unavailable".
napi_value SetBadgeCount(napi_env env, napi_callback_info info) {
  size_t argc = 1;
  napi_value argv[1] = {nullptr};
  napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr);
  int64_t requested = 0;
  if (argc < 1 || napi_get_value_int64(env, argv[0], &requested) != napi_ok) {
    napi_throw_type_error(env, nullptr, "setBadgeCount expects a count");
    return nullptr;
  }
  const NSInteger count = requested > 0 ? static_cast<NSInteger>(requested) : 0;

  napi_threadsafe_function settle = nullptr;
  napi_value promise = BeginQuery(env, &settle);
  UNUserNotificationCenter *center = CurrentCenter();
  if (center == nil) {
    Settle(settle, "unavailable");
    return promise;
  }
  [center getNotificationSettingsWithCompletionHandler:^(UNNotificationSettings *settings) {
    const NSInteger shown = settings.badgeSetting == UNNotificationSettingEnabled ? count : 0;
    [center setBadgeCount:shown
        withCompletionHandler:^(NSError *error) {
          Settle(settle, error != nil ? "unavailable" : shown > 0 ? "shown" : "cleared");
        }];
  }];
  return promise;
}

napi_value Init(napi_env env, napi_value exports) {
  napi_value status_function = nullptr;
  napi_create_function(env, "authorizationStatus", NAPI_AUTO_LENGTH, AuthorizationStatus,
                       nullptr, &status_function);
  napi_set_named_property(env, exports, "authorizationStatus", status_function);

  napi_value request_function = nullptr;
  napi_create_function(env, "requestAuthorization", NAPI_AUTO_LENGTH, RequestAuthorization,
                       nullptr, &request_function);
  napi_set_named_property(env, exports, "requestAuthorization", request_function);

  napi_value badge_function = nullptr;
  napi_create_function(env, "setBadgeCount", NAPI_AUTO_LENGTH, SetBadgeCount, nullptr,
                       &badge_function);
  napi_set_named_property(env, exports, "setBadgeCount", badge_function);
  return exports;
}

}  // namespace

NAPI_MODULE(NODE_GYP_MODULE_NAME, Init)
