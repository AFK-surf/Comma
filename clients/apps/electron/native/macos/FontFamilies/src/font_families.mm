#include <node_api.h>

#import <CoreText/CoreText.h>
#import <Foundation/Foundation.h>

#include <string>
#include <vector>

namespace {

// One listing: the promise it settles and the names read off the JS thread.
struct FamilyNamesQuery {
  napi_async_work work = nullptr;
  napi_deferred deferred = nullptr;
  std::vector<std::string> names;
};

// CoreText is thread-safe, so the OS query runs on a libuv worker and Main's
// JS thread never waits for it. The names are the family names CSS matches;
// they stay unlocalized under every system language.
void ReadFamilyNames(napi_env, void *data) {
  auto *query = static_cast<FamilyNamesQuery *>(data);
  @autoreleasepool {
    NSArray<NSString *> *names =
        CFBridgingRelease(CTFontManagerCopyAvailableFontFamilyNames());
    query->names.reserve(names.count);
    for (NSString *name in names) {
      query->names.emplace_back(name.UTF8String);
    }
  }
}

void ResolveFamilyNames(napi_env env, napi_status, void *data) {
  auto *query = static_cast<FamilyNamesQuery *>(data);
  napi_value names = nullptr;
  napi_create_array_with_length(env, query->names.size(), &names);
  for (size_t index = 0; index < query->names.size(); ++index) {
    const std::string &name = query->names[index];
    napi_value value = nullptr;
    napi_create_string_utf8(env, name.data(), name.size(), &value);
    napi_set_element(env, names, static_cast<uint32_t>(index), value);
  }
  napi_resolve_deferred(env, query->deferred, names);
  napi_delete_async_work(env, query->work);
  delete query;
}

// Resolves with the visible font family names installed on this Mac, in the
// order CoreText sorts them for display.
napi_value FamilyNames(napi_env env, napi_callback_info) {
  auto *query = new FamilyNamesQuery();
  napi_value promise = nullptr;
  napi_create_promise(env, &query->deferred, &promise);

  napi_value resource_name = nullptr;
  napi_create_string_utf8(env, "comma_font_families", NAPI_AUTO_LENGTH, &resource_name);
  napi_create_async_work(env, nullptr, resource_name, ReadFamilyNames, ResolveFamilyNames,
                         query, &query->work);
  napi_queue_async_work(env, query->work);
  return promise;
}

napi_value Init(napi_env env, napi_value exports) {
  napi_value family_names = nullptr;
  napi_create_function(env, "familyNames", NAPI_AUTO_LENGTH, FamilyNames, nullptr,
                       &family_names);
  napi_set_named_property(env, exports, "familyNames", family_names);
  return exports;
}

}  // namespace

NAPI_MODULE(NODE_GYP_MODULE_NAME, Init)
