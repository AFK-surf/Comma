// The client core's engine (packages/core/native/engine.cpp, shared with the Android app) for Swift: one core in
// Hermes on a thread of its own. CoreClient.swift starts one and is its host.
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// What a running core asks of the app, called on the core's own thread. `call` returns at once and is answered later
/// through `-[CommaEngine complete:json:error:bytes:]`; `callSync` answers before it returns.
@protocol CommaEngineHost <NSObject>
- (void)engineCall:(uint64_t)identifier op:(NSString *)op json:(NSData *)json bytes:(nullable NSData *)bytes;
/// `{"value": …}` or `{"error": …}`; nil when the app could not answer.
- (nullable NSData *)engineCallSync:(NSString *)op json:(NSData *)json;
/// What the core says to the app's UI, as UTF-8 JSON.
- (void)engineEmit:(NSData *)json;
/// The core cannot go on; nothing else comes from it.
- (void)engineFatal:(NSString *)reason;
@end

@interface CommaEngine : NSObject
/// Starts a core running `script` (Hermes bytecode) with `config` (the JSON the script's `start` takes).
- (instancetype)initWithScript:(NSData *)script config:(NSString *)config host:(id<CommaEngineHost>)host;
- (instancetype)init NS_UNAVAILABLE;
/// What the app's UI says, as JSON.
- (void)receive:(NSString *)json;
/// The server refused a request the app made for `lease` (JSON) with `status` (401 or 409).
- (void)rejected:(NSString *)lease status:(NSInteger)status;
/// The answer to call `identifier`: `error` when it failed.
- (void)complete:(uint64_t)identifier json:(nullable NSData *)json error:(nullable NSString *)error bytes:(nullable NSData *)bytes;
/// Stops the core and waits for its thread to end (unless called on that thread: then it ends once the call returns).
- (void)close;
@end

NS_ASSUME_NONNULL_END
