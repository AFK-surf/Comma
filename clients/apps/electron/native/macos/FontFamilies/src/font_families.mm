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

// Returns the width in points of one string set in the font AppKit draws menu
// item titles with. CoreText's menu-item UI font is that same face and size,
// and it falls back per glyph (CJK, emoji) the way the menu does. One short
// line layout takes microseconds, so the call is synchronous.
napi_value MenuTextWidth(napi_env env, napi_callback_info info) {
  size_t argc = 1;
  napi_value argv[1] = {nullptr};
  napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr);
  size_t length = 0;
  if (argc < 1 ||
      napi_get_value_string_utf16(env, argv[0], nullptr, 0, &length) != napi_ok) {
    napi_throw_type_error(env, nullptr, "menuTextWidth expects a string.");
    return nullptr;
  }
  std::vector<char16_t> characters(length + 1);
  napi_get_value_string_utf16(env, argv[0], characters.data(), characters.size(),
                              &length);

  // Read the font on every call: the menu font follows system text settings.
  CTFontRef font = CTFontCreateUIFontForLanguage(kCTFontUIFontMenuItem, 0, nullptr);
  napi_value result = nullptr;
  if (font == nullptr) {
    // The caller falls back to an approximate width.
    napi_get_null(env, &result);
    return result;
  }
  double width = 0;
  @autoreleasepool {
    NSString *text =
        [[NSString alloc] initWithCharacters:reinterpret_cast<const unichar *>(
                                                 characters.data())
                                      length:length];
    NSAttributedString *attributed = [[NSAttributedString alloc]
        initWithString:text
            attributes:@{(__bridge NSString *)kCTFontAttributeName : (__bridge id)font}];
    CTLineRef line =
        CTLineCreateWithAttributedString((__bridge CFAttributedStringRef)attributed);
    width = CTLineGetTypographicBounds(line, nullptr, nullptr, nullptr);
    CFRelease(line);
    CFRelease(font);
  }

  napi_create_double(env, width, &result);
  return result;
}

napi_value Init(napi_env env, napi_value exports) {
  napi_value family_names = nullptr;
  napi_create_function(env, "familyNames", NAPI_AUTO_LENGTH, FamilyNames, nullptr,
                       &family_names);
  napi_set_named_property(env, exports, "familyNames", family_names);
  napi_value menu_text_width = nullptr;
  napi_create_function(env, "menuTextWidth", NAPI_AUTO_LENGTH, MenuTextWidth, nullptr,
                       &menu_text_width);
  napi_set_named_property(env, exports, "menuTextWidth", menu_text_width);
  return exports;
}

}  // namespace

NAPI_MODULE(NODE_GYP_MODULE_NAME, Init)
