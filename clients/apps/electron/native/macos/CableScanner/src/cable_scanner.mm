#include <node_api.h>

#import <CoreBluetooth/CoreBluetooth.h>
#import <Foundation/Foundation.h>

#include <cstring>
#include <utility>

namespace {

// caBLE v2 adverts carry 20 bytes of service data under one of these UUIDs:
// FFF9 is assigned to FIDO, FDE2 to Google (iOS 16 sends it).
constexpr NSUInteger kAdvertLength = 20;

// One event from the CoreBluetooth queue for the JS thread.
struct ScanEvent {
  bool is_advert = false;
  const char *state = nullptr;
  uint8_t advert[kAdvertLength] = {};
};

}  // namespace

@interface CommaCableScanDelegate : NSObject <CBCentralManagerDelegate>
// Both are read and written only on the scan queue.
@property(nonatomic) BOOL scanning;
@property(nonatomic) napi_threadsafe_function emit;
@end

namespace {

dispatch_queue_t ScanQueue() {
  static dispatch_queue_t queue =
      dispatch_queue_create("surf.comma.cable-scanner", DISPATCH_QUEUE_SERIAL);
  return queue;
}

CommaCableScanDelegate *Delegate() {
  static CommaCableScanDelegate *delegate = [[CommaCableScanDelegate alloc] init];
  return delegate;
}

// Created on the first scan: creating it is what shows the macOS prompt.
CBCentralManager *g_central = nil;

const char *StateName(CBManagerState state) {
  switch (state) {
    case CBManagerStatePoweredOn:
      return "on";
    case CBManagerStatePoweredOff:
      return "off";
    case CBManagerStateUnauthorized:
      return "denied";
    case CBManagerStateUnsupported:
      return "unsupported";
    default:
      // Unknown and resetting settle into one of the above.
      return "pending";
  }
}

void Emit(napi_threadsafe_function emit, ScanEvent *event) {
  if (emit == nullptr ||
      napi_call_threadsafe_function(emit, event, napi_tsfn_nonblocking) != napi_ok) {
    delete event;
  }
}

void EmitState(napi_threadsafe_function emit, CBManagerState state) {
  auto *event = new ScanEvent();
  event->state = StateName(state);
  Emit(emit, event);
}

void StartScanIfPoweredOn(CBCentralManager *central) {
  if (central.state != CBManagerStatePoweredOn) return;
  // Chromium scans the same way: no service filter, because the UUID may be
  // present only as a service-data key, and duplicates, because a phone keeps
  // advertising while it waits.
  [central scanForPeripheralsWithServices:nil
                                  options:@{CBCentralManagerScanOptionAllowDuplicatesKey : @YES}];
}

}  // namespace

@implementation CommaCableScanDelegate

- (void)centralManagerDidUpdateState:(CBCentralManager *)central {
  if (!self.scanning) return;
  EmitState(self.emit, central.state);
  StartScanIfPoweredOn(central);
}

- (void)centralManager:(CBCentralManager *)central
    didDiscoverPeripheral:(CBPeripheral *)peripheral
        advertisementData:(NSDictionary<NSString *, id> *)advertisementData
                     RSSI:(NSNumber *)RSSI {
  if (!self.scanning) return;
  static NSArray<CBUUID *> *uuids =
      @[ [CBUUID UUIDWithString:@"FFF9"], [CBUUID UUIDWithString:@"FDE2"] ];
  id serviceData = advertisementData[CBAdvertisementDataServiceDataKey];
  if (![serviceData isKindOfClass:[NSDictionary class]]) return;
  for (CBUUID *uuid in uuids) {
    id value = serviceData[uuid];
    if (![value isKindOfClass:[NSData class]] || [value length] != kAdvertLength) continue;
    auto *event = new ScanEvent();
    event->is_advert = true;
    std::memcpy(event->advert, [value bytes], kAdvertLength);
    Emit(self.emit, event);
    return;
  }
}

@end

namespace {

void CallJs(napi_env env, napi_value callback, void *, void *data) {
  auto *event = static_cast<ScanEvent *>(data);
  if (env != nullptr && callback != nullptr) {
    napi_value object = nullptr;
    napi_create_object(env, &object);
    napi_value type = nullptr;
    napi_create_string_utf8(env, event->is_advert ? "advert" : "state", NAPI_AUTO_LENGTH,
                            &type);
    napi_set_named_property(env, object, "type", type);
    if (event->is_advert) {
      napi_value advert = nullptr;
      void *copy = nullptr;
      napi_create_buffer_copy(env, kAdvertLength, event->advert, &copy, &advert);
      napi_set_named_property(env, object, "data", advert);
    } else {
      napi_value state = nullptr;
      napi_create_string_utf8(env, event->state, NAPI_AUTO_LENGTH, &state);
      napi_set_named_property(env, object, "state", state);
    }
    napi_value undefined = nullptr;
    napi_get_undefined(env, &undefined);
    napi_call_function(env, undefined, callback, 1, &object, nullptr);
  }
  delete event;
}

void StopScan() {
  __block napi_threadsafe_function emit = nullptr;
  dispatch_sync(ScanQueue(), ^{
    CommaCableScanDelegate *delegate = Delegate();
    delegate.scanning = NO;
    if (g_central != nil && g_central.state == CBManagerStatePoweredOn) {
      [g_central stopScan];
    }
    emit = delegate.emit;
    delegate.emit = nullptr;
  });
  if (emit != nullptr) napi_release_threadsafe_function(emit, napi_tsfn_release);
}

// Reads the app's Bluetooth permission without asking for it.
napi_value Authorization(napi_env env, napi_callback_info) {
  const char *name = "not-determined";
  switch (CBManager.authorization) {
    case CBManagerAuthorizationAllowedAlways:
      name = "allowed";
      break;
    case CBManagerAuthorizationDenied:
      name = "denied";
      break;
    case CBManagerAuthorizationRestricted:
      name = "restricted";
      break;
    default:
      break;
  }
  napi_value result = nullptr;
  napi_create_string_utf8(env, name, NAPI_AUTO_LENGTH, &result);
  return result;
}

// Starts scanning and calls `callback` with each Bluetooth state and each
// caBLE advert. A second start replaces the first callback.
napi_value Start(napi_env env, napi_callback_info info) {
  size_t argc = 1;
  napi_value argv[1] = {nullptr};
  napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr);
  napi_valuetype type = napi_undefined;
  if (argc < 1 || napi_typeof(env, argv[0], &type) != napi_ok || type != napi_function) {
    napi_throw_type_error(env, nullptr, "start expects a callback");
    return nullptr;
  }
  StopScan();

  napi_value resource_name = nullptr;
  napi_create_string_utf8(env, "comma_cable_scanner", NAPI_AUTO_LENGTH, &resource_name);
  napi_threadsafe_function emit = nullptr;
  if (napi_create_threadsafe_function(env, argv[0], nullptr, resource_name, 0, 1, nullptr,
                                      nullptr, nullptr, CallJs, &emit) != napi_ok) {
    napi_throw_error(env, nullptr, "Could not create the scan callback");
    return nullptr;
  }
  // A running scan must not keep a process alive on its own.
  napi_unref_threadsafe_function(env, emit);

  const bool create = g_central == nil;
  dispatch_sync(ScanQueue(), ^{
    CommaCableScanDelegate *delegate = Delegate();
    delegate.emit = emit;
    delegate.scanning = YES;
    if (!create) {
      EmitState(emit, g_central.state);
      StartScanIfPoweredOn(g_central);
    }
  });
  if (create) {
    // The first state arrives in centralManagerDidUpdateState on the queue.
    g_central = [[CBCentralManager alloc]
        initWithDelegate:Delegate()
                   queue:ScanQueue()
                 options:@{CBCentralManagerOptionShowPowerAlertKey : @NO}];
  }
  return nullptr;
}

napi_value Stop(napi_env, napi_callback_info) {
  StopScan();
  return nullptr;
}

void Cleanup(void *) { StopScan(); }

napi_value Init(napi_env env, napi_value exports) {
  const std::pair<const char *, napi_callback> functions[] = {
      {"authorization", Authorization},
      {"start", Start},
      {"stop", Stop},
  };
  for (const auto &[name, callback] : functions) {
    napi_value function = nullptr;
    napi_create_function(env, name, NAPI_AUTO_LENGTH, callback, nullptr, &function);
    napi_set_named_property(env, exports, name, function);
  }
  napi_add_env_cleanup_hook(env, Cleanup, nullptr);
  return exports;
}

}  // namespace

NAPI_MODULE(NODE_GYP_MODULE_NAME, Init)
