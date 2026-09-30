#include <node_api.h>
#import <AppKit/AppKit.h>
#import <QuartzCore/QuartzCore.h>
#include <algorithm>
#include <array>
#include <cmath>
#include <cstring>
#include <vector>

NSDictionary *MaskPixels(CGImageRef image, CGFloat pointWidth) {
  if (image == nullptr || CFGetTypeID(image) != CGImageGetTypeID() ||
      CGImageGetBitsPerComponent(image) != 8 || CGImageGetBitsPerPixel(image) != 32) {
    return nil;
  }
  CFDataRef data = CGDataProviderCopyData(CGImageGetDataProvider(image));
  if (data == nullptr) return nil;
  const unsigned char *pixels = CFDataGetBytePtr(data);
  const size_t width = CGImageGetWidth(image);
  const size_t height = CGImageGetHeight(image);
  const size_t rowBytes = CGImageGetBytesPerRow(image);
  const CGFloat scale = width / pointWidth;
  auto alphaAt = [&](size_t x, size_t y) {
    return pixels[y * rowBytes + x * 4 + 3];
  };
  unsigned char left = 0, right = 0, top = 0, bottom = 0;
  size_t leftGradientPixels = 0, bottomGradientPixels = 0;
  for (size_t y = 0; y < height; ++y) {
    left = std::max(left, alphaAt(0, y));
    right = std::max(right, alphaAt(width - 1, y));
    // The mask image stores its top edge in the first row.
    const unsigned char alpha = alphaAt(width / 2, height - 1 - y);
    if (y < height / 2 && alpha > 0 && alpha < 255) ++bottomGradientPixels;
  }
  for (size_t x = 0; x < width; ++x) {
    top = std::max(top, alphaAt(x, 0));
    bottom = std::max(bottom, alphaAt(x, height - 1));
    const unsigned char alpha = alphaAt(x, height / 2);
    if (x < width / 2 && alpha > 0 && alpha < 255) ++leftGradientPixels;
  }
  const unsigned char center = alphaAt(width / 2, height / 2);
  CFRelease(data);
  return @{
    @"centerAlpha": @(center),
    @"edgeMaxAlpha": @{@"left": @(left), @"right": @(right),
                      @"top": @(top), @"bottom": @(bottom)},
    @"leftGradientPoints": @(leftGradientPixels / scale),
    @"bottomGradientPoints": @(bottomGradientPixels / scale)
  };
}

NSDictionary *OpaqueBackdropCoverage(NSVisualEffectView *view, CALayer *backdrop) {
  // Model a fully opaque sample (including WindowServer substitute color).
  // The real composition must fade even when the filter output is not clear.
  const size_t width = std::ceil(view.bounds.size.width * 2);
  const size_t height = std::ceil(view.bounds.size.height * 2);
  std::vector<unsigned char> pixels(width * height * 4);
  CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
  CGContextRef context = CGBitmapContextCreate(
      pixels.data(), width, height, 8, width * 4, colorSpace,
      static_cast<CGBitmapInfo>(kCGImageAlphaPremultipliedLast) |
          kCGBitmapByteOrder32Big);
  CGColorSpaceRelease(colorSpace);
  if (context == nullptr || backdrop == nil) {
    if (context != nullptr) CGContextRelease(context);
    return nil;
  }
  CGColorRef originalColor = CGColorRetain(backdrop.backgroundColor);
  NSArray *originalFilters = backdrop.filters;
  [CATransaction begin];
  [CATransaction setDisableActions:YES];
  backdrop.backgroundColor = NSColor.whiteColor.CGColor;
  backdrop.filters = nil;
  CGContextScaleCTM(context, width / view.bounds.size.width,
                    height / view.bounds.size.height);
  CGContextTranslateCTM(context, -view.bounds.origin.x, -view.bounds.origin.y);
  [view.layer renderInContext:context];
  backdrop.backgroundColor = originalColor;
  backdrop.filters = originalFilters;
  [CATransaction commit];
  CGColorRelease(originalColor);
  CGImageRef image = CGBitmapContextCreateImage(context);
  NSDictionary *coverage = MaskPixels(image, view.bounds.size.width);
  if (image != nullptr) CGImageRelease(image);
  CGContextRelease(context);
  return coverage;
}

NSDictionary *BackdropPixels(NSVisualEffectView *view) {
  // This checks tint composition and filter inputs. renderInContext does not
  // reproduce WindowServer sampling, so it cannot verify desktop blur pixels.
  [view updateLayer];
  [view layoutSubtreeIfNeeded];
  [view.window displayIfNeeded];

  constexpr size_t kSampleSize = 64;
  std::array<unsigned char, kSampleSize * kSampleSize * 4> pixels{};
  CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
  CGContextRef context = CGBitmapContextCreate(
      pixels.data(), kSampleSize, kSampleSize, 8, kSampleSize * 4,
      colorSpace, static_cast<CGBitmapInfo>(kCGImageAlphaPremultipliedLast) |
                      kCGBitmapByteOrder32Big);
  CGColorSpaceRelease(colorSpace);
  if (context == nullptr || NSIsEmptyRect(view.bounds)) {
    if (context != nullptr) CGContextRelease(context);
    return nil;
  }
  CGContextScaleCTM(context, kSampleSize / view.bounds.size.width,
                    kSampleSize / view.bounds.size.height);
  CGContextTranslateCTM(context, -view.bounds.origin.x, -view.bounds.origin.y);
  [view.layer renderInContext:context];
  CGContextRelease(context);

  unsigned char maximumAlpha = 0;
  unsigned char rightEdgeMaximumAlpha = 0;
  for (size_t y = 0; y < kSampleSize; ++y) {
    for (size_t x = 0; x < kSampleSize; ++x) {
      const unsigned char alpha = pixels[(y * kSampleSize + x) * 4 + 3];
      maximumAlpha = std::max(maximumAlpha, alpha);
      if (x == kSampleSize - 1) {
        rightEdgeMaximumAlpha = std::max(rightEdgeMaximumAlpha, alpha);
      }
    }
  }
  NSNumber *blurRadius = nil;
  NSNumber *tintOpacity = nil;
  NSDictionary *maskPixels = nil;
  CALayer *backdrop = nil;
  NSMutableArray<CALayer *> *pending = [NSMutableArray arrayWithObject:view.layer];
  Class backdropClass = NSClassFromString(@"CABackdropLayer");
  while (pending.count > 0) {
    CALayer *layer = pending.lastObject;
    [pending removeLastObject];
    [pending addObjectsFromArray:layer.sublayers ?: @[]];
    if ([layer isKindOfClass:backdropClass]) {
      backdrop = layer;
      blurRadius = [layer.filters.firstObject valueForKey:@"inputRadius"];
      CGImageRef coverageMask = (__bridge CGImageRef)layer.superlayer.mask.contents;
      maskPixels = MaskPixels(coverageMask, layer.bounds.size.width);
    }
    if ([layer.name isEqualToString:@"CommaSideChatBackdropTintLayer"]) {
      tintOpacity = @(CGColorGetAlpha(layer.backgroundColor));
    }
  }
  return @{
    @"blurRadius": blurRadius ?: @(-1),
    @"tintOpacity": tintOpacity ?: @(-1),
    @"mask": maskPixels ?: @{},
    @"opaqueCoverage": OpaqueBackdropCoverage(view, backdrop) ?: @{},
    @"maxAlpha": @(maximumAlpha),
    @"rightEdgeMaxAlpha": @(rightEdgeMaximumAlpha)
  };
}

// Inspect native composition and Chromium input clients without production
// diagnostic endpoints or changes to the input protocol.
napi_value Inspect(napi_env env, napi_callback_info info) {
  size_t argc = 1;
  napi_value argv[1];
  napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr);
  void *data;
  size_t size;
  napi_get_buffer_info(env, argv[0], &data, &size);
  void *pointer;
  std::memcpy(&pointer, data, sizeof(pointer));
  NSView *root = (__bridge NSView *)pointer;
  NSMutableArray *rows = [NSMutableArray array];
  NSMutableArray *backdrops = [NSMutableArray array];
  NSMutableArray<NSView *> *pending = [NSMutableArray arrayWithObject:root];
  while (pending.count > 0) {
    NSView *view = pending.lastObject;
    [pending removeLastObject];
    [pending addObjectsFromArray:view.subviews];
    if ([view isKindOfClass:NSVisualEffectView.class]) {
      NSDictionary *pixels = BackdropPixels((NSVisualEffectView *)view);
      if (pixels == nil) {
        napi_throw_error(env, nullptr, "Could not render the native backdrop.");
        return nullptr;
      }
      [backdrops addObject:pixels];
    }
    if ([view conformsToProtocol:@protocol(NSTextInputClient)]) {
      BOOL responds = [view respondsToSelector:@selector(windowLevel)];
      [rows addObject:@{
        @"class": NSStringFromClass(view.class),
        @"window": @(view.window.level),
        @"responds": @(responds),
        @"reported": responds ? @([(id<NSTextInputClient>)view windowLevel]) : @(-999)
      }];
    }
  }
  NSData *json = [NSJSONSerialization dataWithJSONObject:@{
    @"textInputLevels": rows,
    @"backdropPixels": backdrops
  } options:0 error:nil];
  napi_value value;
  napi_create_string_utf8(env, (const char *)json.bytes, json.length, &value);
  return value;
}

napi_value Init(napi_env env, napi_value exports) {
  napi_value inspect;
  napi_create_function(env, "inspect", NAPI_AUTO_LENGTH, Inspect, nullptr, &inspect);
  napi_set_named_property(env, exports, "inspect", inspect);
  return exports;
}

NAPI_MODULE(NODE_GYP_MODULE_NAME, Init)
