#import "CommaEngine.h"

#import <os/log.h>

#include <memory>
#include <optional>
#include <string>

#include "engine.h"

namespace {

os_log_t coreLog() {
  static os_log_t log = os_log_create("surf.comma.ios", "core");
  return log;
}

std::string bytesOf(NSData *data) {
  return data ? std::string(static_cast<const char *>(data.bytes), data.length) : std::string();
}

NSData *dataOf(const std::string &bytes) { return [NSData dataWithBytes:bytes.data() length:bytes.size()]; }

/// The Swift host, called on the core's thread. Its methods are not to throw.
class SwiftHost : public comma::EngineHost {
 public:
  explicit SwiftHost(id<CommaEngineHost> host) : host_(host) {}

  void call(uint64_t id, const std::string &op, const std::string &json, const std::string *bytes) override {
    @autoreleasepool {
      [host_ engineCall:id op:[NSString stringWithUTF8String:op.c_str()] json:dataOf(json) bytes:bytes ? dataOf(*bytes) : nil];
    }
  }

  std::optional<std::string> callSync(const std::string &op, const std::string &json) override {
    @autoreleasepool {
      NSData *answer = [host_ engineCallSync:[NSString stringWithUTF8String:op.c_str()] json:dataOf(json)];
      if (!answer) return std::nullopt;
      return bytesOf(answer);
    }
  }

  void emit(const std::string &json) override {
    @autoreleasepool {
      [host_ engineEmit:dataOf(json)];
    }
  }

  void fatal(const std::string &reason) override {
    @autoreleasepool {
      [host_ engineFatal:[[NSString alloc] initWithBytes:reason.data() length:reason.size() encoding:NSUTF8StringEncoding] ?: @"the core failed"];
    }
  }

  void log(int level, const std::string &message) override {
    os_log_type_t type = level >= 3 ? OS_LOG_TYPE_ERROR : level == 2 ? OS_LOG_TYPE_DEFAULT : level == 1 ? OS_LOG_TYPE_INFO : OS_LOG_TYPE_DEBUG;
    os_log_with_type(coreLog(), type, "%{public}s", message.c_str());
  }

 private:
  id<CommaEngineHost> host_;
};

/// Hermes's parser and interpreter want more native stack than a thread gets by default.
constexpr NSUInteger kStackBytes = 8 * 1024 * 1024;

}  // namespace

@implementation CommaEngine {
  std::unique_ptr<SwiftHost> _host;
  std::unique_ptr<comma::Engine> _engine;
  NSThread *_thread;
  dispatch_semaphore_t _ended;
  /// The loop's end has been waited for.
  BOOL _joined;
}

- (instancetype)initWithScript:(NSData *)script config:(NSString *)config host:(id<CommaEngineHost>)host {
  if ((self = [super init])) {
    _host = std::make_unique<SwiftHost>(host);
    _engine = std::make_unique<comma::Engine>(*_host, bytesOf(script), "core.hbc", std::string(config.UTF8String));
    _ended = dispatch_semaphore_create(0);
    comma::Engine *engine = _engine.get();
    dispatch_semaphore_t ended = _ended;
    _thread = [[NSThread alloc] initWithBlock:^{
      engine->run();
      dispatch_semaphore_signal(ended);
    }];
    _thread.name = @"comma-core";
    _thread.stackSize = kStackBytes;
    _thread.qualityOfService = NSQualityOfServiceUserInitiated;
    [_thread start];
  }
  return self;
}

- (void)receive:(NSString *)json {
  _engine->receive(std::string(json.UTF8String));
}

- (void)rejected:(NSString *)lease status:(NSInteger)status {
  _engine->rejected(std::string(lease.UTF8String), int(status));
}

- (void)complete:(uint64_t)identifier json:(NSData *)json error:(NSString *)error bytes:(NSData *)bytes {
  _engine->complete(identifier, json ? std::optional<std::string>(bytesOf(json)) : std::nullopt,
                    error ? std::optional<std::string>(std::string(error.UTF8String)) : std::nullopt,
                    bytes ? std::optional<std::string>(bytesOf(bytes)) : std::nullopt);
}

- (void)close {
  _engine->stop();
  [self join];
}

/// Waits for the loop to return, unless called on the core's own thread (a host call that ends it): the loop returns
/// once that call does.
- (void)join {
  if (_joined || [NSThread currentThread] == _thread) return;
  dispatch_semaphore_wait(_ended, DISPATCH_TIME_FOREVER);
  _joined = YES;
}

- (void)dealloc {
  _engine->stop();
  if ([NSThread currentThread] == _thread && !_joined) {
    // Let go on the core's own thread: its loop has not returned yet, so the engine is left to the process rather
    // than freed under it.
    (void)_engine.release();
    (void)_host.release();
    return;
  }
  [self join];
}

@end
