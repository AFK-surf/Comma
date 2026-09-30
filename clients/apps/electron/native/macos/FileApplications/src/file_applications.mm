#include <node_api.h>

#import <AppKit/AppKit.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

#include <string>
#include <vector>

namespace {

// Matches the renderer leaf's menu bound. Launch Services performs the
// association lookup; Comma never searches the user's Applications directories.
constexpr NSUInteger kMaximumApplications = 32;

struct Application {
  std::string path;
  std::string name;
  std::string icon;
  bool is_default = false;
};

struct Query {
  napi_deferred deferred = nullptr;
  napi_async_work work = nullptr;
  std::string input;
  bool file_path = false;
  bool failed = false;
  std::vector<Application> applications;
};

std::string Utf8(NSString *value) {
  const char *text = value.UTF8String;
  return text == nullptr ? "" : text;
}

bool String(napi_env env, const std::string &value, napi_value *result) {
  return napi_create_string_utf8(env, value.data(), value.size(), result) == napi_ok;
}

bool ReadString(napi_env env, napi_value value, std::string *result) {
  size_t size = 0;
  if (napi_get_value_string_utf8(env, value, nullptr, 0, &size) != napi_ok ||
      size == 0 || size > 32768) return false;
  result->resize(size + 1);
  if (napi_get_value_string_utf8(env, value, result->data(), size + 1, &size) != napi_ok) {
    result->clear();
    return false;
  }
  result->resize(size);
  return result->find('\0') == std::string::npos;
}

void ResolveNull(napi_env env, napi_deferred deferred) {
  napi_value result = nullptr;
  if (napi_get_null(env, &result) == napi_ok) {
    (void)napi_resolve_deferred(env, deferred, result);
  }
}

void ResolveBoolean(napi_env env, napi_deferred deferred, bool value) {
  napi_value result = nullptr;
  if (napi_get_boolean(env, value, &result) == napi_ok) {
    (void)napi_resolve_deferred(env, deferred, result);
  }
}

std::string ApplicationIcon(NSWorkspace *workspace, NSString *path) {
  NSImage *image = [workspace iconForFile:path];
  NSBitmapImageRep *bitmap = [[NSBitmapImageRep alloc]
      initWithBitmapDataPlanes:nullptr pixelsWide:32 pixelsHigh:32
      bitsPerSample:8 samplesPerPixel:4 hasAlpha:YES isPlanar:NO
      colorSpaceName:NSDeviceRGBColorSpace bytesPerRow:0 bitsPerPixel:0];
  if (image == nil || bitmap == nil) return "";
  NSGraphicsContext *context = [NSGraphicsContext graphicsContextWithBitmapImageRep:bitmap];
  if (context == nil) return "";
  [NSGraphicsContext saveGraphicsState];
  [NSGraphicsContext setCurrentContext:context];
  [image drawInRect:NSMakeRect(0, 0, 32, 32) fromRect:NSZeroRect
         operation:NSCompositingOperationCopy fraction:1.0];
  [NSGraphicsContext restoreGraphicsState];
  NSData *png = [bitmap representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
  if (png == nil || png.length > 12000) return "";
  return "data:image/png;base64," + Utf8([png base64EncodedStringWithOptions:0]);
}

void QueryApplicationsOnMain(Query *query) {
  @autoreleasepool {
    @try {
      NSWorkspace *workspace = NSWorkspace.sharedWorkspace;
      NSString *input = [[NSString alloc] initWithBytes:query->input.data()
          length:query->input.size() encoding:NSUTF8StringEncoding];
      if (input == nil) {
        query->failed = true;
        return;
      }
      NSArray<NSURL *> *urls = @[];
      NSURL *default_url = nil;
      if (query->file_path) {
        NSURL *file = [NSURL fileURLWithPath:input];
        urls = [workspace URLsForApplicationsToOpenURL:file];
        default_url = [workspace URLForApplicationToOpenURL:file];
      } else {
        UTType *type = [UTType typeWithFilenameExtension:input.pathExtension];
        if (type != nil) {
          urls = [workspace URLsForApplicationsToOpenContentType:type];
          default_url = [workspace URLForApplicationToOpenContentType:type];
        }
      }
      for (NSURL *url in urls) {
        if (query->applications.size() >= kMaximumApplications) break;
        NSString *name = nil;
        [url getResourceValue:&name forKey:NSURLLocalizedNameKey error:nil];
        if (name.length == 0) name = url.lastPathComponent.stringByDeletingPathExtension;
        if ([name.pathExtension.lowercaseString isEqualToString:@"app"]) {
          name = name.stringByDeletingPathExtension;
        }
        if (name.length == 0 || !url.isFileURL) continue;
        query->applications.push_back({
          Utf8(url.path), Utf8([name substringToIndex:MIN(name.length, 256)]),
          query->file_path ? "" : ApplicationIcon(workspace, url.path),
          [url isEqual:default_url] == YES
        });
      }
    } @catch (NSException *) {
      query->failed = true;
    }
  }
}

void ExecuteQuery(napi_env, void *) {
  // Keep the asynchronous Promise contract. AppKit work runs in the completion
  // callback because dispatch_sync to the main queue can deadlock standalone Node.
}

bool ApplicationValue(napi_env env, const Application &application, napi_value *item) {
  if (napi_create_object(env, item) != napi_ok) return false;
  napi_value value = nullptr;
  if (!String(env, application.path, &value) ||
      napi_set_named_property(env, *item, "applicationPath", value) != napi_ok ||
      !String(env, application.name, &value) ||
      napi_set_named_property(env, *item, "name", value) != napi_ok) return false;
  if (!application.icon.empty() &&
      (!String(env, application.icon, &value) ||
       napi_set_named_property(env, *item, "iconDataUrl", value) != napi_ok)) return false;
  if (napi_get_boolean(env, application.is_default, &value) != napi_ok ||
      napi_set_named_property(env, *item, "isDefault", value) != napi_ok) return false;
  return true;
}

void CompleteQuery(napi_env env, napi_status status, void *data) {
  auto *query = static_cast<Query *>(data);
  if (status == napi_ok && [NSThread isMainThread]) {
    QueryApplicationsOnMain(query);
  } else {
    query->failed = true;
  }
  bool built = status == napi_ok && !query->failed;
  napi_value result = nullptr;
  if (built) built = napi_create_array_with_length(env, query->applications.size(), &result) == napi_ok;
  for (uint32_t index = 0; built && index < query->applications.size(); ++index) {
    napi_value item = nullptr;
    built = ApplicationValue(env, query->applications[index], &item) &&
            napi_set_element(env, result, index, item) == napi_ok;
  }
  if (built) {
    (void)napi_resolve_deferred(env, query->deferred, result);
  } else {
    ResolveNull(env, query->deferred);
  }
  if (query->work != nullptr) (void)napi_delete_async_work(env, query->work);
  delete query;
}

napi_value ListApplications(napi_env env, napi_callback_info info) {
  napi_value argument = nullptr;
  size_t argc = 1;
  void *mode = nullptr;
  if (napi_get_cb_info(env, info, &argc, &argument, nullptr, &mode) != napi_ok) return nullptr;
  auto *query = new Query();
  query->file_path = mode != nullptr;
  napi_value promise = nullptr;
  if (napi_create_promise(env, &query->deferred, &promise) != napi_ok) {
    delete query;
    return nullptr;
  }
  if (argc != 1 || !ReadString(env, argument, &query->input)) {
    ResolveNull(env, query->deferred);
    delete query;
    return promise;
  }
  napi_value resource_name = nullptr;
  if (!String(env, "comma_file_applications", &resource_name) ||
      napi_create_async_work(env, nullptr, resource_name, ExecuteQuery, CompleteQuery,
                             query, &query->work) != napi_ok) {
    ResolveNull(env, query->deferred);
    delete query;
    return promise;
  }
  if (napi_queue_async_work(env, query->work) != napi_ok) {
    (void)napi_delete_async_work(env, query->work);
    query->work = nullptr;
    ResolveNull(env, query->deferred);
    delete query;
  }
  return promise;
}

struct OpenRequest {
  napi_deferred deferred = nullptr;
  napi_threadsafe_function settle = nullptr;
};

void FinalizeOpen(napi_env, void *data, void *) {
  delete static_cast<OpenRequest *>(data);
}

void SettleOpen(napi_env env, napi_value, void *context, void *data) {
  auto *request = static_cast<OpenRequest *>(context);
  if (env != nullptr) ResolveBoolean(env, request->deferred, data != nullptr);
}

void SendOpenResult(napi_threadsafe_function settle, bool opened) {
  const napi_status called = napi_call_threadsafe_function(
      settle, opened ? reinterpret_cast<void *>(1) : nullptr, napi_tsfn_nonblocking);
  (void)napi_release_threadsafe_function(
      settle, called == napi_ok ? napi_tsfn_release : napi_tsfn_abort);
}

napi_value OpenFile(napi_env env, napi_callback_info info) {
  napi_value arguments[2] = {nullptr, nullptr};
  size_t argc = 2;
  if (napi_get_cb_info(env, info, &argc, arguments, nullptr, nullptr) != napi_ok) return nullptr;
  std::string path, application_path;
  auto *request = new OpenRequest();
  napi_value promise = nullptr;
  if (napi_create_promise(env, &request->deferred, &promise) != napi_ok) {
    delete request;
    return nullptr;
  }
  if (argc != 2 || !ReadString(env, arguments[0], &path) ||
      !ReadString(env, arguments[1], &application_path)) {
    ResolveBoolean(env, request->deferred, false);
    delete request;
    return promise;
  }
  napi_value resource_name = nullptr;
  if (!String(env, "comma_open_file_application", &resource_name) ||
      napi_create_threadsafe_function(
          env, nullptr, nullptr, resource_name, 0, 1, request, FinalizeOpen,
          request, SettleOpen, &request->settle) != napi_ok) {
    ResolveBoolean(env, request->deferred, false);
    delete request;
    return promise;
  }
  napi_threadsafe_function settle = request->settle;
  NSString *file = [[NSString alloc] initWithBytes:path.data() length:path.size()
      encoding:NSUTF8StringEncoding];
  NSString *application = [[NSString alloc] initWithBytes:application_path.data()
      length:application_path.size() encoding:NSUTF8StringEncoding];
  if (file == nil || application == nil) {
    SendOpenResult(settle, false);
    return promise;
  }
  dispatch_async(dispatch_get_main_queue(), ^{
    @try {
      [NSWorkspace.sharedWorkspace openURLs:@[[NSURL fileURLWithPath:file]]
          withApplicationAtURL:[NSURL fileURLWithPath:application]
          configuration:NSWorkspaceOpenConfiguration.configuration
          completionHandler:^(NSRunningApplication *app, NSError *error) {
            SendOpenResult(settle, app != nil && error == nil);
          }];
    } @catch (NSException *) {
      SendOpenResult(settle, false);
    }
  });
  return promise;
}

napi_value CopyFile(napi_env env, napi_callback_info info) {
  napi_value argument = nullptr;
  size_t argc = 1;
  if (napi_get_cb_info(env, info, &argc, &argument, nullptr, nullptr) != napi_ok) return nullptr;
  std::string path;
  auto *request = new OpenRequest();
  napi_value promise = nullptr;
  if (napi_create_promise(env, &request->deferred, &promise) != napi_ok) {
    delete request;
    return nullptr;
  }
  if (argc != 1 || !ReadString(env, argument, &path)) {
    ResolveBoolean(env, request->deferred, false);
    delete request;
    return promise;
  }
  napi_value resource_name = nullptr;
  if (!String(env, "comma_copy_file", &resource_name) ||
      napi_create_threadsafe_function(env, nullptr, nullptr, resource_name, 0, 1,
          request, FinalizeOpen, request, SettleOpen, &request->settle) != napi_ok) {
    ResolveBoolean(env, request->deferred, false);
    delete request;
    return promise;
  }
  napi_threadsafe_function settle = request->settle;
  NSString *file = [[NSString alloc] initWithBytes:path.data() length:path.size()
      encoding:NSUTF8StringEncoding];
  dispatch_async(dispatch_get_main_queue(), ^{
    @try {
      NSPasteboard *pasteboard = [NSPasteboard generalPasteboard];
      [pasteboard clearContents];
      SendOpenResult(settle, [pasteboard writeObjects:@[[NSURL fileURLWithPath:file]]]);
    } @catch (NSException *) { SendOpenResult(settle, false); }
  });
  return promise;
}

napi_value Init(napi_env env, napi_value exports) {
  napi_property_descriptor properties[] = {
    {"listApplicationsForFileName", nullptr, ListApplications, nullptr, nullptr, nullptr, napi_default, nullptr},
    {"listApplicationsForFile", nullptr, ListApplications, nullptr, nullptr, nullptr, napi_default, reinterpret_cast<void *>(1)},
    {"openFileWithApplication", nullptr, OpenFile, nullptr, nullptr, nullptr, napi_default, nullptr},
    {"copyFileToClipboard", nullptr, CopyFile, nullptr, nullptr, nullptr, napi_default, nullptr}
  };
  if (napi_define_properties(env, exports, 4, properties) != napi_ok) return nullptr;
  return exports;
}

}  // namespace

NAPI_MODULE(NODE_GYP_MODULE_NAME, Init)
