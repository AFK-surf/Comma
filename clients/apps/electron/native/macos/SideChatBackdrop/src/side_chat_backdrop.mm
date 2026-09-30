#include <node_api.h>

#import <AppKit/AppKit.h>
#import <CoreGraphics/CoreGraphics.h>
#import <QuartzCore/QuartzCore.h>
#import <dispatch/dispatch.h>
#import <objc/runtime.h>

#include <algorithm>
#include <cmath>
#include <cstring>

namespace {

constexpr NSInteger kMaximumMaskPixelDimension = 640;

struct BackdropSettings {
  CGFloat blurRadius = 24.0;
  CGFloat leftFeather = 39.0;
  CGFloat rightFeather = 120.0;
  CGFloat topFeather = 53.0;
  CGFloat bottomFeather = 26.0;
  CGFloat solidOutsetLeft = -14.0;
  CGFloat solidOutsetRight = -60.0;
  CGFloat solidOutsetTop = -23.0;
  CGFloat solidOutsetBottom = 0.0;
  double maskGamma = 1.25;
  double maximumMaskAlpha = 1.0;
  double tintOpacity = 0.06;
  BOOL windowServerAware = YES;
  BOOL allowsGroupBlending = YES;
  BOOL allowsInPlaceFiltering = NO;
  BOOL disablesOccludedBackdropBlurs = NO;
  BOOL showBackdrop = YES;
};

NSColor *BackdropTint(const BackdropSettings &settings) {
  return [NSColor.blackColor colorWithAlphaComponent:settings.tintOpacity];
}

bool RequiresLayerRebuild(const BackdropSettings &left,
                          const BackdropSettings &right) {
  return left.blurRadius != right.blurRadius ||
         left.windowServerAware != right.windowServerAware ||
         left.allowsGroupBlending != right.allowsGroupBlending ||
         left.allowsInPlaceFiltering != right.allowsInPlaceFiltering ||
         left.disablesOccludedBackdropBlurs !=
             right.disablesOccludedBackdropBlurs;
}

bool MaskShapeChanged(const BackdropSettings &left,
                      const BackdropSettings &right) {
  return left.leftFeather != right.leftFeather ||
         left.rightFeather != right.rightFeather ||
         left.topFeather != right.topFeather ||
         left.bottomFeather != right.bottomFeather ||
         left.solidOutsetLeft != right.solidOutsetLeft ||
         left.solidOutsetRight != right.solidOutsetRight ||
         left.solidOutsetTop != right.solidOutsetTop ||
         left.solidOutsetBottom != right.solidOutsetBottom ||
         left.maskGamma != right.maskGamma;
}

struct BackdropGeometry {
  CGFloat windowWidth = 559.0;
  CGFloat windowHeight = 412.0;
  CGFloat contentX = 5.0;
  CGFloat contentY = -9.0;
  CGFloat contentWidth = 400.0;
  CGFloat contentHeight = 286.0;
  CGFloat visualWidth = 400.0;
  CGFloat visualHeight = 286.0;
};

// AppKit asks the text input client for this optional protocol method when
// its window is above NSFloatingWindowLevel. Chromium omits it, so the IME
// otherwise places its candidate panel at the default level below Side Chat.
NSInteger TextInputWindowLevel(id client, SEL) {
  return [(NSView *)client window].level;
}

void RegisterTextInputWindowLevels(NSView *root) {
  NSMutableArray<NSView *> *pending = [NSMutableArray arrayWithObject:root];
  while (pending.count > 0) {
    NSView *view = pending.lastObject;
    [pending removeLastObject];
    [pending addObjectsFromArray:view.subviews];
    if ([view conformsToProtocol:@protocol(NSTextInputClient)] &&
        ![view respondsToSelector:@selector(windowLevel)]) {
      // Add only the missing protocol method. Existing native implementations
      // remain authoritative. New renderer views reuse their class's method,
      // and each call reads that view's own current window level.
      class_addMethod(view.class, @selector(windowLevel),
                      (IMP)TextInputWindowLevel, "q@:");
    }
  }
}

void RunOnMainSync(dispatch_block_t block) {
  if ([NSThread isMainThread]) {
    block();
    return;
  }

  dispatch_sync(dispatch_get_main_queue(), block);
}

CGFloat Smoothstep(CGFloat edge0, CGFloat edge1, CGFloat value) {
  if (edge1 <= edge0) {
    return value < edge0 ? 0 : 1;
  }

  const CGFloat x = std::clamp((value - edge0) / (edge1 - edge0),
                               static_cast<CGFloat>(0),
                               static_cast<CGFloat>(1));
  return x * x * (3 - 2 * x);
}

bool SetDynamicValue(id object, NSString *key, id value) {
  if (object == nil) {
    return false;
  }

  NSString *first = [[key substringToIndex:1] uppercaseString];
  NSString *setterName = [NSString stringWithFormat:@"set%@%@:", first,
                                                       [key substringFromIndex:1]];
  if (![object respondsToSelector:NSSelectorFromString(setterName)]) {
    NSLog(@"[CommaSideChatBackdrop] %@ is missing %@",
          NSStringFromClass([object class]), setterName);
    return false;
  }

  @try {
    [object setValue:value forKey:key];
    return true;
  } @catch (__unused NSException *exception) {
    NSLog(@"[CommaSideChatBackdrop] %@ rejected %@",
          NSStringFromClass([object class]), key);
    return false;
  }
}

bool SetKeyValue(id object, NSString *key, id value) {
  if (object == nil) {
    return false;
  }
  @try {
    [object setValue:value forKey:key];
    return true;
  } @catch (__unused NSException *exception) {
    NSLog(@"[CommaSideChatBackdrop] %@ rejected %@",
          NSStringFromClass([object class]), key);
    return false;
  }
}

bool ConfigureWindowServerBackdropSupport(NSWindow *window,
                                          BOOL rebuildLayerHosting) {
  if (window == nil) {
    return false;
  }

  // These private NSWindow switches are the same ones used by the previous
  // native Side Chat panel. They must be applied to ElectronNSWindow itself;
  // neither the content NSView nor its CALayer implements the selectors.
  // This selector is present on the old AppKit panel but not on every
  // ElectronNSWindow build. Match the old host's best-effort behavior: apply
  // it when available, while treating WindowServer layer hosting as the
  // required visual-floor capability.
  if ([window respondsToSelector:
          NSSelectorFromString(@"setShouldAutoFlattenLayerTree:")]) {
    SetDynamicValue(window, @"shouldAutoFlattenLayerTree", @NO);
  }
  bool configured = true;
  if (rebuildLayerHosting) {
    configured =
        SetDynamicValue(window, @"canHostLayersInWindowServer", @NO) &&
        configured;
  }
  configured =
      SetDynamicValue(window, @"canHostLayersInWindowServer", @YES) &&
      configured;
  return configured;
}

CGImageRef CreateFeatherMask(NSInteger pixelWidth,
                             NSInteger pixelHeight,
                             CGFloat scale,
                             NSRect contentFrame,
                             const BackdropSettings &settings)
    CF_RETURNS_RETAINED {
  const NSInteger bytesPerPixel = 4;
  const NSInteger bytesPerRow = pixelWidth * bytesPerPixel;
  NSMutableData *data =
      [NSMutableData dataWithLength:bytesPerRow * pixelHeight];
  auto *pixels = static_cast<uint8_t *>(data.mutableBytes);

  const CGFloat width = pixelWidth / scale;
  const CGFloat height = pixelHeight / scale;
  // Fit each fade's outer edge inside the window, then retain its full width.
  // Content offsets may put the left or bottom solid edge outside the window.
  const CGFloat fadeMinX = std::max(static_cast<CGFloat>(0),
      NSMinX(contentFrame) - settings.solidOutsetLeft - settings.leftFeather);
  const CGFloat solidMinX = fadeMinX + settings.leftFeather;
  const CGFloat fadeMaxX = std::min(width,
      NSMaxX(contentFrame) + settings.solidOutsetRight + settings.rightFeather);
  const CGFloat solidMaxX = fadeMaxX - settings.rightFeather;
  const CGFloat fadeMinY = std::max(static_cast<CGFloat>(0),
      NSMinY(contentFrame) - settings.solidOutsetBottom - settings.bottomFeather);
  const CGFloat solidMinY = fadeMinY + settings.bottomFeather;
  const CGFloat fadeMaxY = std::min(height,
      NSMaxY(contentFrame) + settings.solidOutsetTop + settings.topFeather);
  const CGFloat solidMaxY = fadeMaxY - settings.topFeather;
  const double gamma = std::max(settings.maskGamma, 0.05);

  for (NSInteger y = 0; y < pixelHeight; ++y) {
    for (NSInteger x = 0; x < pixelWidth; ++x) {
      const CGFloat pointX = (static_cast<CGFloat>(x) + 0.5) / scale;
      const CGFloat pointY =
          (static_cast<CGFloat>(pixelHeight) - static_cast<CGFloat>(y) - 0.5) /
          scale;
      const CGFloat leftAlpha =
          Smoothstep(fadeMinX, solidMinX, pointX);
      const CGFloat rightAlpha =
          1 - Smoothstep(solidMaxX, fadeMaxX, pointX);
      const CGFloat bottomAlpha =
          Smoothstep(fadeMinY, solidMinY, pointY);
      const CGFloat topAlpha =
          1 - Smoothstep(solidMaxY, fadeMaxY, pointY);
      const CGFloat xAlpha = std::min(leftAlpha, rightAlpha);
      const CGFloat yAlpha = std::min(bottomAlpha, topAlpha);
      const double product = std::clamp(
          static_cast<double>(xAlpha * yAlpha), 0.0, 1.0);
      const double rawAlpha = std::pow(product, gamma);
      const uint8_t alpha = static_cast<uint8_t>(
          std::clamp(rawAlpha, 0.0, 1.0) * 255.0);
      const NSInteger offset = y * bytesPerRow + x * bytesPerPixel;
      pixels[offset] = alpha;
      pixels[offset + 1] = alpha;
      pixels[offset + 2] = alpha;
      pixels[offset + 3] = alpha;
    }
  }

  CGDataProviderRef provider =
      CGDataProviderCreateWithCFData((__bridge CFDataRef)data);
  if (provider == nullptr) {
    return nullptr;
  }

  CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
  if (colorSpace == nullptr) {
    CGDataProviderRelease(provider);
    return nullptr;
  }

  const CGBitmapInfo bitmapInfo = static_cast<CGBitmapInfo>(
      static_cast<uint32_t>(kCGBitmapByteOrderDefault) |
      static_cast<uint32_t>(kCGImageAlphaPremultipliedLast));
  CGImageRef image = CGImageCreate(
      pixelWidth, pixelHeight, 8, 32, bytesPerRow, colorSpace,
      bitmapInfo, provider, nullptr, true, kCGRenderingIntentDefault);
  CGColorSpaceRelease(colorSpace);
  CGDataProviderRelease(provider);
  return image;
}

id CreateGaussianBlurFilter(const BackdropSettings &settings) {
  Class filterClass = NSClassFromString(@"CAFilter");
  SEL factorySelector = NSSelectorFromString(@"filterWithType:");
  if (filterClass == Nil || ![filterClass respondsToSelector:factorySelector]) {
    return nil;
  }

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
  id filter = [filterClass performSelector:factorySelector
                                withObject:@"gaussianBlur"];
#pragma clang diagnostic pop
  if (filter == nil) {
    return nil;
  }

  // CAFilter exposes inputRadius through KVC without advertising an Objective-C
  // setter on current macOS, exactly as in the previous Swift implementation.
  if (!SetKeyValue(filter, @"inputRadius", @(settings.blurRadius)) ||
      !SetKeyValue(filter, @"inputNormalizeEdges", @YES)) {
    return nil;
  }
  return filter;
}

CALayer *CreateBackdropLayer(const BackdropSettings &settings) {
  Class backdropClass = NSClassFromString(@"CABackdropLayer");
  if (backdropClass == Nil ||
      ![backdropClass isSubclassOfClass:[CALayer class]]) {
    return nil;
  }

  CALayer *backdrop = [[backdropClass alloc] init];
  backdrop.name = @"CommaSideChatBackdropLayer";
  backdrop.opaque = NO;
  backdrop.backgroundColor = NSColor.clearColor.CGColor;
  backdrop.masksToBounds = NO;
  const BOOL configured =
      SetDynamicValue(backdrop, @"allowsSubstituteColor", @YES) &&
      SetDynamicValue(backdrop, @"groupName", NSUUID.UUID.UUIDString) &&
      SetDynamicValue(backdrop, @"bleedAmount", @8.0) &&
      SetDynamicValue(backdrop, @"windowServerAware",
                      @(settings.windowServerAware)) &&
      SetDynamicValue(backdrop, @"allowsInPlaceFiltering",
                      @(settings.allowsInPlaceFiltering)) &&
      SetDynamicValue(backdrop, @"allowsGroupBlending",
                      @(settings.allowsGroupBlending)) &&
      SetDynamicValue(backdrop, @"disablesOccludedBackdropBlurs",
                      @(settings.disablesOccludedBackdropBlurs));
  if (!configured) {
    return nil;
  }

  return backdrop;
}

}  // namespace

// Chromium's macOS window bridge explicitly keeps NSVisualEffectView instances
// beneath the compositor surfaces when it reorders native child views after a
// navigation, renderer restart, or resize. Using that supported background-view
// classification prevents our custom layer host from being lifted above the
// Electron renderer later in the window lifecycle.
@interface CommaSideChatBackdropView : NSVisualEffectView

@property(nonatomic) BackdropGeometry geometry;
@property(nonatomic) BackdropSettings settings;
@property(nonatomic) CGFloat revealOffsetX;
@property(nonatomic, readonly) BOOL backdropAvailable;

- (instancetype)initWithFrame:(NSRect)frameRect
              contentRootView:(NSView *)contentRootView;
- (void)rebuildBackdrop;
- (void)restoreContentSurfaces;
- (CGFloat)maximumRevealAlignmentError;
- (BOOL)isOrderedBelowContentSurfaces;
- (BOOL)containsInteractiveScreenPoint:(NSPoint)screenPoint;

@end

@implementation CommaSideChatBackdropView {
  CALayer *_backdropLayer;
  NSView *_backdropLayerHost;
  CALayer *_tintLayer;
  CALayer *_featherMaskLayer;
  __weak NSView *_contentRootView;
  NSMapTable<NSView *, NSValue *> *_contentSurfaceBaseFrames;
  NSRect _interactiveContentFrame;
  NSString *_lastMaskKey;
  BOOL _appKitMaterialSuppressionAvailable;
  BOOL _maskAvailable;
  CGFloat _lastAppliedRevealOffsetX;
}

- (instancetype)initWithFrame:(NSRect)frameRect
              contentRootView:(NSView *)contentRootView {
  self = [super initWithFrame:frameRect];
  if (self == nil) {
    return nil;
  }

  _contentRootView = contentRootView;
  _contentSurfaceBaseFrames = [NSMapTable weakToStrongObjectsMapTable];
  for (NSView *surface in contentRootView.subviews) {
    [_contentSurfaceBaseFrames setObject:[NSValue valueWithRect:surface.frame]
                                  forKey:surface];
  }
  _lastAppliedRevealOffsetX = 0;
  self.blendingMode = NSVisualEffectBlendingModeWithinWindow;
  self.state = NSVisualEffectStateInactive;
  // maskImage affects AppKit's material, but not subviews. Keep the custom
  // backdrop in a child view so AppKit can manage its own material layers.
  NSBitmapImageRep *materialMask = [[NSBitmapImageRep alloc]
      initWithBitmapDataPlanes:nil pixelsWide:1 pixelsHigh:1
      bitsPerSample:8 samplesPerPixel:4 hasAlpha:YES isPlanar:NO
      colorSpaceName:NSDeviceRGBColorSpace bytesPerRow:4 bitsPerPixel:32];
  if (materialMask != nil) {
    std::memset(materialMask.bitmapData, 0, 4);
    NSImage *transparentMask = [[NSImage alloc] initWithSize:NSMakeSize(1, 1)];
    [transparentMask addRepresentation:materialMask];
    self.maskImage = transparentMask;
  }
  _appKitMaterialSuppressionAvailable = self.maskImage != nil;
  self.wantsLayer = YES;
  _backdropLayerHost = [[NSView alloc] initWithFrame:self.bounds];
  _backdropLayerHost.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
  _backdropLayerHost.layer = [CALayer layer];
  _backdropLayerHost.wantsLayer = YES;
  _backdropLayerHost.layer.backgroundColor = NSColor.clearColor.CGColor;
  _backdropLayerHost.layer.opaque = NO;
  _backdropLayerHost.layer.masksToBounds = YES;
  [self addSubview:_backdropLayerHost];
  _geometry = BackdropGeometry{};
  _settings = BackdropSettings{};
  _revealOffsetX = 0;
  _featherMaskLayer = [CALayer layer];
  _backdropLayerHost.layer.mask = _featherMaskLayer;
  _tintLayer = [CALayer layer];
  _tintLayer.name = @"CommaSideChatBackdropTintLayer";
  _tintLayer.opaque = NO;
  [_backdropLayerHost.layer addSublayer:_tintLayer];
  [self rebuildBackdrop];
  return self;
}

- (instancetype)initWithFrame:(NSRect)frameRect {
  return [self initWithFrame:frameRect contentRootView:nil];
}

- (BOOL)isFlipped {
  return NO;
}

- (BOOL)isOpaque {
  return NO;
}

- (NSView *)hitTest:(NSPoint)point {
  return nil;
}

- (BOOL)backdropAvailable {
  return _backdropLayer != nil && _appKitMaterialSuppressionAvailable &&
         _maskAvailable;
}

- (void)setGeometry:(BackdropGeometry)geometry {
  _geometry = geometry;
  _lastMaskKey = nil;
  [self setNeedsLayout:YES];
  [self layoutSubtreeIfNeeded];
}

- (void)setSettings:(BackdropSettings)settings {
  const BOOL needsLayerRebuild = RequiresLayerRebuild(_settings, settings);
  if (MaskShapeChanged(_settings, settings)) {
    _lastMaskKey = nil;
  }
  _settings = settings;
  [CATransaction begin];
  [CATransaction setDisableActions:YES];
  _backdropLayerHost.layer.hidden = !_settings.showBackdrop;
  _backdropLayerHost.layer.opacity = _settings.maximumMaskAlpha;
  _tintLayer.backgroundColor = BackdropTint(_settings).CGColor;
  [CATransaction commit];
  if (needsLayerRebuild) {
    [self rebuildBackdrop];
    return;
  }
  [self setNeedsLayout:YES];
  [self layoutSubtreeIfNeeded];
}

- (void)setRevealOffsetX:(CGFloat)revealOffsetX {
  if (std::abs(_revealOffsetX - revealOffsetX) <= 0.001) {
    return;
  }
  _revealOffsetX = revealOffsetX;
  [self setNeedsLayout:YES];
  [self layoutSubtreeIfNeeded];
}

- (void)rebuildBackdrop {
  _backdropLayer.mask = nil;
  [_backdropLayer removeFromSuperlayer];
  _backdropLayer = CreateBackdropLayer(_settings);
  if (_backdropLayer != nil) {
    [_backdropLayerHost.layer insertSublayer:_backdropLayer atIndex:0];
  }
  _backdropLayerHost.layer.hidden = !_settings.showBackdrop;
  _backdropLayerHost.layer.opacity = _settings.maximumMaskAlpha;
  _tintLayer.backgroundColor = BackdropTint(_settings).CGColor;
  _maskAvailable = NO;
  _lastMaskKey = nil;
  [self setNeedsLayout:YES];
  [self layoutSubtreeIfNeeded];
}

- (void)restoreContentSurfaces {
  for (NSView *surface in _contentRootView.subviews) {
    if (surface == self) {
      continue;
    }
    NSValue *baseValue = [_contentSurfaceBaseFrames objectForKey:surface];
    if (baseValue != nil) {
      surface.frame = baseValue.rectValue;
    }
  }
  [_contentSurfaceBaseFrames removeAllObjects];
  _lastAppliedRevealOffsetX = 0;
}

- (void)applyRevealOffsetToContentSurfaces {
  NSView *contentRootView = _contentRootView;
  if (contentRootView == nil) {
    return;
  }

  for (NSView *surface in contentRootView.subviews) {
    if (surface == self) {
      continue;
    }

    NSRect currentFrame = surface.frame;
    NSValue *baseValue = [_contentSurfaceBaseFrames objectForKey:surface];
    NSRect baseFrame = baseValue == nil ? currentFrame : baseValue.rectValue;
    if (baseValue != nil) {
      const NSRect expectedFrame =
          NSOffsetRect(baseFrame, _lastAppliedRevealOffsetX, 0);
      const BOOL originMatches =
          std::abs(currentFrame.origin.x - expectedFrame.origin.x) <= 0.5;
      const BOOL frameMatches =
          originMatches &&
          std::abs(currentFrame.origin.y - expectedFrame.origin.y) <= 0.5 &&
          std::abs(currentFrame.size.width - expectedFrame.size.width) <= 0.5 &&
          std::abs(currentFrame.size.height - expectedFrame.size.height) <= 0.5;
      if (!frameMatches) {
        if (originMatches) {
          // Electron resized an existing compositor surface without changing
          // our x translation. Preserve the unshifted x while accepting its
          // new y/size as the next authoritative base frame.
          baseFrame.origin.y = currentFrame.origin.y;
          baseFrame.size = currentFrame.size;
        } else {
          // A navigation/renderer restart can replace or relayout the native
          // compositor siblings at x=0. Treat that frame as the new base and
          // reapply the current reveal offset immediately.
          baseFrame = currentFrame;
        }
      }
    }

    [_contentSurfaceBaseFrames setObject:[NSValue valueWithRect:baseFrame]
                                  forKey:surface];
    surface.frame = NSOffsetRect(baseFrame, _revealOffsetX, 0);
  }
  _lastAppliedRevealOffsetX = _revealOffsetX;
}

- (CGFloat)maximumRevealAlignmentError {
  CGFloat maximumError =
      std::abs(_backdropLayer.frame.origin.x - _revealOffsetX);
  maximumError = std::max(maximumError,
      std::abs(_tintLayer.frame.origin.x - _revealOffsetX));
  maximumError = std::max(maximumError,
      std::abs(_featherMaskLayer.frame.origin.x - _revealOffsetX));
  for (NSView *surface in _contentRootView.subviews) {
    if (surface == self) {
      continue;
    }
    NSValue *baseValue = [_contentSurfaceBaseFrames objectForKey:surface];
    if (baseValue == nil) {
      continue;
    }
    const CGFloat appliedOffset =
        surface.frame.origin.x - baseValue.rectValue.origin.x;
    maximumError =
        std::max(maximumError, std::abs(appliedOffset - _revealOffsetX));
  }
  return maximumError;
}

- (BOOL)isOrderedBelowContentSurfaces {
  NSArray<NSView *> *subviews = _contentRootView.subviews;
  const NSUInteger backdropIndex = [subviews indexOfObjectIdenticalTo:self];
  if (backdropIndex == NSNotFound) {
    return NO;
  }
  for (NSView *surface in subviews) {
    if (surface == self) {
      continue;
    }
    const NSUInteger surfaceIndex = [subviews indexOfObjectIdenticalTo:surface];
    if (surfaceIndex == NSNotFound || surfaceIndex <= backdropIndex) {
      return NO;
    }
  }
  return YES;
}

- (BOOL)containsInteractiveScreenPoint:(NSPoint)screenPoint {
  NSWindow *window = self.window;
  if (window == nil) {
    return NO;
  }

  NSRect hitRect = NSInsetRect(_interactiveContentFrame, -2, -2);
  hitRect = NSIntersectionRect(hitRect, self.bounds);
  if (NSIsEmptyRect(hitRect)) {
    return NO;
  }

  const NSPoint windowPoint = [window convertPointFromScreen:screenPoint];
  const NSPoint viewPoint = [self convertPoint:windowPoint fromView:nil];
  return NSPointInRect(viewPoint, hitRect);
}

- (void)layout {
  [super layout];

  const NSRect bounds = self.bounds;
  const CGFloat scale =
      self.window.backingScaleFactor ?: NSScreen.mainScreen.backingScaleFactor;
  const CGFloat safeScale = scale > 0 ? scale : 2;
  const CGFloat availableWidth =
      std::max(static_cast<CGFloat>(0), bounds.size.width - _geometry.contentX);
  const CGFloat availableHeight =
      std::max(static_cast<CGFloat>(0), bounds.size.height - _geometry.contentY);
  const NSRect visualContentFrame = NSMakeRect(
      _geometry.contentX, _geometry.contentY,
      std::min(availableWidth, _geometry.visualWidth),
      std::min(availableHeight, _geometry.visualHeight));
  const NSRect backdropFrame = NSOffsetRect(bounds, _revealOffsetX, 0);
  _interactiveContentFrame =
      NSOffsetRect(visualContentFrame, _revealOffsetX, 0);
  if (_backdropLayer == nil) {
    return;
  }

  [CATransaction begin];
  [CATransaction setDisableActions:YES];
  _backdropLayerHost.frame = bounds;
  _backdropLayer.frame = backdropFrame;
  _backdropLayer.contentsScale = safeScale;
  _tintLayer.frame = backdropFrame;
  _tintLayer.contentsScale = safeScale;
  _featherMaskLayer.frame = backdropFrame;
  SetDynamicValue(_backdropLayer, @"scale", @(safeScale));
  [self updateFeatherMaskForSize:backdropFrame.size
                   contentFrame:visualContentFrame
                   backingScale:safeScale];
  [self applyRevealOffsetToContentSurfaces];
  [CATransaction commit];
}

- (void)updateFeatherMaskForSize:(NSSize)size
                    contentFrame:(NSRect)contentFrame
                    backingScale:(CGFloat)backingScale {
  const CGFloat maxPointDimension = std::max(size.width, size.height);
  CGFloat renderScale = backingScale;
  if (maxPointDimension > 0) {
    const CGFloat cappedScale =
        static_cast<CGFloat>(kMaximumMaskPixelDimension) / maxPointDimension;
    renderScale = std::min(backingScale,
                           std::max(static_cast<CGFloat>(0.35), cappedScale));
  }
  const NSInteger pixelWidth =
      std::max<NSInteger>(1, std::ceil(size.width * renderScale));
  const NSInteger pixelHeight =
      std::max<NSInteger>(1, std::ceil(size.height * renderScale));
  NSString *maskKey = [NSString
      stringWithFormat:
          @"%ldx%ld@%.3f:%.3f,%.3f,%.3fx%.3f:%.1f,%.1f,%.1f,%.1f:%.1f,%.1f,%.1f,%.1f:%.2f",
          static_cast<long>(pixelWidth), static_cast<long>(pixelHeight),
          static_cast<double>(renderScale),
          static_cast<double>(contentFrame.origin.x),
          static_cast<double>(contentFrame.origin.y),
          static_cast<double>(contentFrame.size.width),
          static_cast<double>(contentFrame.size.height),
          static_cast<double>(_settings.leftFeather),
          static_cast<double>(_settings.rightFeather),
          static_cast<double>(_settings.topFeather),
          static_cast<double>(_settings.bottomFeather),
          static_cast<double>(_settings.solidOutsetLeft),
          static_cast<double>(_settings.solidOutsetRight),
          static_cast<double>(_settings.solidOutsetTop),
          static_cast<double>(_settings.solidOutsetBottom),
          _settings.maskGamma];

  _featherMaskLayer.contentsScale = renderScale;
  _featherMaskLayer.contentsGravity = kCAGravityResize;
  if ([_lastMaskKey isEqualToString:maskKey]) {
    return;
  }

  CGImageRef image = CreateFeatherMask(pixelWidth, pixelHeight, renderScale,
                                       contentFrame, _settings);
  id filter = CreateGaussianBlurFilter(_settings);
  _maskAvailable = image != nullptr && filter != nil;
  // Zero blur radius does not guarantee transparent backdrop output. The
  // common mask fades all sampled output and tint, including substitute color.
  _featherMaskLayer.contents = image == nullptr ? nil : (__bridge id)image;
  _backdropLayer.filters = filter == nil ? nil : @[ filter ];
  _lastMaskKey = _maskAvailable ? maskKey : nil;
  if (image != nullptr) {
    CGImageRelease(image);
  }
}

@end

namespace {

__strong CommaSideChatBackdropView *gBackdropView = nil;
__weak NSWindow *gNativeWindow = nil;
__strong id gLocalMouseEventMonitor = nil;
__strong id gGlobalMouseEventMonitor = nil;
__strong id gActiveSpaceObserver = nil;
__strong id gScreenParametersObserver = nil;
BackdropGeometry gGeometry;
BackdropSettings gSettings;
CGFloat gRevealOffsetX = 0;
uint64_t gBackdropRefreshGeneration = 0;
uint64_t gBackdropRebuildRevision = 0;
BOOL gBackdropHealthy = NO;

void SetBackdropHealthOnMain(BOOL healthy) {
  gBackdropHealthy = healthy;
}

void FailClosedBackdropOnMain(NSWindow *window, NSString *reason) {
  SetBackdropHealthOnMain(NO);
  if (reason.length > 0) {
    NSLog(@"[CommaSideChatBackdrop] fail closed: %@", reason);
  }
  if (window == nil) {
    return;
  }
  window.ignoresMouseEvents = YES;
  [window orderOut:nil];
}

BOOL CurrentBackdropHealthOnMain() {
  return gBackdropHealthy && gBackdropView != nil &&
         gBackdropView.backdropAvailable;
}

BOOL RebuildBackdropOnMain() {
  if (gBackdropView == nil) {
    return NO;
  }

  [gBackdropView rebuildBackdrop];
  ++gBackdropRebuildRevision;
  return gBackdropView.backdropAvailable;
}

BOOL RefreshBackdropForCurrentSpaceOnMain(BOOL requireVisibleWindow,
                                          BOOL allowRecovery,
                                          BOOL restoreVisibleWindow) {
  NSWindow *window = gNativeWindow;
  if (window == nil || gBackdropView == nil ||
      (requireVisibleWindow && !window.visible)) {
    return CurrentBackdropHealthOnMain();
  }

  if (!ConfigureWindowServerBackdropSupport(window, YES)) {
    FailClosedBackdropOnMain(window,
                             @"WindowServer layer hosting is unavailable");
    return NO;
  }
  const BOOL available = RebuildBackdropOnMain();
  if (!available) {
    FailClosedBackdropOnMain(window,
                             @"masked backdrop rebuild is unavailable");
    return NO;
  }
  if (allowRecovery) {
    SetBackdropHealthOnMain(YES);
  }
  if (!CurrentBackdropHealthOnMain()) {
    // A scheduled second-stage refresh must never recover a window after an
    // earlier stage failed. Only an explicit Main-triggered rebuild can clear
    // the sticky failure, and that rebuild does not show the window itself.
    FailClosedBackdropOnMain(window,
                             @"backdrop health remains unavailable");
    return NO;
  }
  if (restoreVisibleWindow) {
    [window orderFrontRegardless];
    [window displayIfNeeded];
  }
  return YES;
}

void ScheduleWindowServerBackdropRefreshOnMain() {
  const uint64_t generation = ++gBackdropRefreshGeneration;
  // Match the native panel's recovery timing. A WindowServer transition can
  // report before its layer-hosting tree is stable, especially while the
  // reveal animation is still moving.
  const NSTimeInterval initialDelay =
      std::abs(gRevealOffsetX) > 0.001 ? 0.28 : 0.04;
  dispatch_after(
      dispatch_time(DISPATCH_TIME_NOW, static_cast<int64_t>(
                                          initialDelay * NSEC_PER_SEC)),
      dispatch_get_main_queue(), ^{
        if (generation != gBackdropRefreshGeneration ||
            gBackdropView == nil) {
          return;
        }
        RefreshBackdropForCurrentSpaceOnMain(YES, NO, YES);
        dispatch_after(
            dispatch_time(DISPATCH_TIME_NOW,
                          static_cast<int64_t>(0.36 * NSEC_PER_SEC)),
            dispatch_get_main_queue(), ^{
              if (generation != gBackdropRefreshGeneration ||
                  gBackdropView == nil) {
                return;
              }
              RefreshBackdropForCurrentSpaceOnMain(YES, NO, YES);
            });
      });
}

void UpdateMousePassThroughOnMain() {
  NSWindow *window = gNativeWindow;
  if (window == nil) {
    return;
  }

  const BOOL shouldIgnoreMouseEvents =
      !CurrentBackdropHealthOnMain() ||
      ![gBackdropView containsInteractiveScreenPoint:NSEvent.mouseLocation];
  if (window.ignoresMouseEvents != shouldIgnoreMouseEvents) {
    window.ignoresMouseEvents = shouldIgnoreMouseEvents;
  }
}

void InstallPointerPassThroughMonitorsOnMain() {
  if (gLocalMouseEventMonitor != nil || gGlobalMouseEventMonitor != nil) {
    return;
  }

  const NSEventMask mask = NSEventMaskMouseMoved |
                           NSEventMaskLeftMouseDragged |
                           NSEventMaskRightMouseDragged |
                           NSEventMaskOtherMouseDragged;
  gLocalMouseEventMonitor =
      [NSEvent addLocalMonitorForEventsMatchingMask:mask
                                           handler:^NSEvent *(NSEvent *event) {
    UpdateMousePassThroughOnMain();
    return event;
  }];
  gGlobalMouseEventMonitor =
      [NSEvent addGlobalMonitorForEventsMatchingMask:mask
                                             handler:^(__unused NSEvent *event) {
    RunOnMainSync(^{
      UpdateMousePassThroughOnMain();
    });
  }];
}

void RemovePointerPassThroughMonitorsOnMain() {
  if (gLocalMouseEventMonitor != nil) {
    [NSEvent removeMonitor:gLocalMouseEventMonitor];
    gLocalMouseEventMonitor = nil;
  }
  if (gGlobalMouseEventMonitor != nil) {
    [NSEvent removeMonitor:gGlobalMouseEventMonitor];
    gGlobalMouseEventMonitor = nil;
  }
}

void InstallWindowServerObserversOnMain() {
  if (gActiveSpaceObserver != nil || gScreenParametersObserver != nil) {
    return;
  }

  NSNotificationCenter *workspaceCenter =
      NSWorkspace.sharedWorkspace.notificationCenter;
  gActiveSpaceObserver = [workspaceCenter
      addObserverForName:NSWorkspaceActiveSpaceDidChangeNotification
                  object:nil
                   queue:NSOperationQueue.mainQueue
              usingBlock:^(__unused NSNotification *notification) {
    ScheduleWindowServerBackdropRefreshOnMain();
  }];
  gScreenParametersObserver = [NSNotificationCenter.defaultCenter
      addObserverForName:NSApplicationDidChangeScreenParametersNotification
                  object:nil
                   queue:NSOperationQueue.mainQueue
              usingBlock:^(__unused NSNotification *notification) {
    ScheduleWindowServerBackdropRefreshOnMain();
  }];
}

void RemoveWindowServerObserversOnMain() {
  ++gBackdropRefreshGeneration;
  if (gActiveSpaceObserver != nil) {
    [NSWorkspace.sharedWorkspace.notificationCenter
        removeObserver:gActiveSpaceObserver];
    gActiveSpaceObserver = nil;
  }
  if (gScreenParametersObserver != nil) {
    [NSNotificationCenter.defaultCenter
        removeObserver:gScreenParametersObserver];
    gScreenParametersObserver = nil;
  }
}

void DetachOnMain() {
  RemoveWindowServerObserversOnMain();
  RemovePointerPassThroughMonitorsOnMain();
  NSWindow *window = gNativeWindow;
  SetBackdropHealthOnMain(NO);
  if (window != nil && window.ignoresMouseEvents) {
    window.ignoresMouseEvents = NO;
  }
  [gBackdropView restoreContentSurfaces];
  [gBackdropView removeFromSuperview];
  gBackdropView = nil;
  gNativeWindow = nil;
}

bool ReadNamedDouble(napi_env env,
                     napi_value object,
                     const char *name,
                     double *result) {
  napi_value value;
  if (napi_get_named_property(env, object, name, &value) != napi_ok ||
      napi_get_value_double(env, value, result) != napi_ok ||
      !std::isfinite(*result)) {
    napi_throw_type_error(env, nullptr, name);
    return false;
  }
  return true;
}

bool ReadNamedBool(napi_env env,
                   napi_value object,
                   const char *name,
                   bool *result) {
  napi_value value;
  if (napi_get_named_property(env, object, name, &value) != napi_ok ||
      napi_get_value_bool(env, value, result) != napi_ok) {
    napi_throw_type_error(env, nullptr, name);
    return false;
  }
  return true;
}

bool IsWithin(double value, double minimum, double maximum) {
  return value >= minimum && value <= maximum;
}

napi_value Undefined(napi_env env) {
  napi_value result;
  napi_get_undefined(env, &result);
  return result;
}

napi_value DisableWindowAnimations(napi_env env, napi_callback_info info) {
  size_t argc = 1;
  napi_value argv[1];
  napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr);
  if (argc != 1) {
    napi_throw_type_error(env, nullptr, "disableWindowAnimations(handle) requires one Buffer");
    return nullptr;
  }

  bool isBuffer = false;
  if (napi_is_buffer(env, argv[0], &isBuffer) != napi_ok || !isBuffer) {
    napi_throw_type_error(env, nullptr, "disableWindowAnimations(handle) expects a Buffer");
    return nullptr;
  }

  void *bufferData = nullptr;
  size_t bufferLength = 0;
  napi_get_buffer_info(env, argv[0], &bufferData, &bufferLength);
  if (bufferLength < sizeof(void *)) {
    napi_throw_range_error(env, nullptr,
                           "native window handle Buffer is too small");
    return nullptr;
  }

  void *pointer = nullptr;
  std::memcpy(&pointer, bufferData, sizeof(pointer));
  if (pointer == nullptr) {
    napi_throw_range_error(env, nullptr, "native window handle is null");
    return nullptr;
  }

  RunOnMainSync(^{
    NSView *contentView = (__bridge NSView *)pointer;
    contentView.window.animationBehavior = NSWindowAnimationBehaviorNone;
  });
  return Undefined(env);
}

napi_value Attach(napi_env env, napi_callback_info info) {
  size_t argc = 1;
  napi_value argv[1];
  napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr);
  if (argc != 1) {
    napi_throw_type_error(env, nullptr, "attach(handle) requires one Buffer");
    return nullptr;
  }

  bool isBuffer = false;
  if (napi_is_buffer(env, argv[0], &isBuffer) != napi_ok || !isBuffer) {
    napi_throw_type_error(env, nullptr, "attach(handle) expects a Buffer");
    return nullptr;
  }

  void *bufferData = nullptr;
  size_t bufferLength = 0;
  napi_get_buffer_info(env, argv[0], &bufferData, &bufferLength);
  if (bufferLength < sizeof(void *)) {
    napi_throw_range_error(env, nullptr,
                           "native window handle Buffer is too small");
    return nullptr;
  }

  void *pointer = nullptr;
  std::memcpy(&pointer, bufferData, sizeof(pointer));
  if (pointer == nullptr) {
    napi_throw_range_error(env, nullptr, "native window handle is null");
    return nullptr;
  }

  __block BOOL available = NO;
  RunOnMainSync(^{
    NSView *contentView = (__bridge NSView *)pointer;
    if (![contentView isKindOfClass:NSView.class]) {
      return;
    }

    NSWindow *window = contentView.window;
    if (window == nil) {
      return;
    }

    DetachOnMain();
    gNativeWindow = window;
    RegisterTextInputWindowLevels(contentView);
    if (!ConfigureWindowServerBackdropSupport(window, YES)) {
      FailClosedBackdropOnMain(window,
                               @"initial WindowServer layer hosting failed");
      return;
    }
    NSRect frame = contentView.bounds;
    CommaSideChatBackdropView *view =
        [[CommaSideChatBackdropView alloc] initWithFrame:frame
                                      contentRootView:contentView];
    view.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    view.settings = gSettings;
    view.geometry = gGeometry;
    view.revealOffsetX = gRevealOffsetX;

    NSView *firstSubview = contentView.subviews.firstObject;
    [contentView addSubview:view
                 positioned:NSWindowBelow
                 relativeTo:firstSubview];
    gBackdropView = view;
    ++gBackdropRebuildRevision;
    [view layoutSubtreeIfNeeded];
    available = view.backdropAvailable;
    SetBackdropHealthOnMain(available);
    if (available) {
      InstallWindowServerObserversOnMain();
      InstallPointerPassThroughMonitorsOnMain();
      UpdateMousePassThroughOnMain();
    } else {
      FailClosedBackdropOnMain(window,
                               @"initial masked backdrop is unavailable");
    }
  });

  napi_value result;
  napi_get_boolean(env, available, &result);
  return result;
}

napi_value UpdateSettings(napi_env env, napi_callback_info info) {
  size_t argc = 1;
  napi_value argv[1];
  napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr);
  napi_valuetype type;
  if (argc != 1 || napi_typeof(env, argv[0], &type) != napi_ok ||
      type != napi_object) {
    napi_throw_type_error(env, nullptr,
                          "updateSettings(settings) expects an object");
    return nullptr;
  }

  double blurRadius;
  double leftFeather;
  double rightFeather;
  double topFeather;
  double bottomFeather;
  double solidOutsetLeft;
  double solidOutsetRight;
  double solidOutsetTop;
  double solidOutsetBottom;
  double maskGamma;
  double maximumMaskAlpha;
  double tintOpacity;
  bool windowServerAware;
  bool allowsGroupBlending;
  bool allowsInPlaceFiltering;
  bool disablesOccludedBackdropBlurs;
  bool showBackdrop;
  if (!ReadNamedDouble(env, argv[0], "blurRadius", &blurRadius) ||
      !ReadNamedDouble(env, argv[0], "leftFeather", &leftFeather) ||
      !ReadNamedDouble(env, argv[0], "rightFeather", &rightFeather) ||
      !ReadNamedDouble(env, argv[0], "topFeather", &topFeather) ||
      !ReadNamedDouble(env, argv[0], "bottomFeather", &bottomFeather) ||
      !ReadNamedDouble(env, argv[0], "solidOutsetLeft", &solidOutsetLeft) ||
      !ReadNamedDouble(env, argv[0], "solidOutsetRight", &solidOutsetRight) ||
      !ReadNamedDouble(env, argv[0], "solidOutsetTop", &solidOutsetTop) ||
      !ReadNamedDouble(env, argv[0], "solidOutsetBottom",
                       &solidOutsetBottom) ||
      !ReadNamedDouble(env, argv[0], "maskGamma", &maskGamma) ||
      !ReadNamedDouble(env, argv[0], "maxMaskAlpha", &maximumMaskAlpha) ||
      !ReadNamedDouble(env, argv[0], "tintOpacity", &tintOpacity) ||
      !ReadNamedBool(env, argv[0], "windowServerAware",
                     &windowServerAware) ||
      !ReadNamedBool(env, argv[0], "allowsGroupBlending",
                     &allowsGroupBlending) ||
      !ReadNamedBool(env, argv[0], "allowsInPlaceFiltering",
                     &allowsInPlaceFiltering) ||
      !ReadNamedBool(env, argv[0], "disablesOccludedBackdropBlurs",
                     &disablesOccludedBackdropBlurs) ||
      !ReadNamedBool(env, argv[0], "showBackdrop", &showBackdrop)) {
    return nullptr;
  }

  const bool feathersWithinRange =
      IsWithin(leftFeather, 0, 220) && IsWithin(rightFeather, 0, 220) &&
      IsWithin(topFeather, 0, 220) && IsWithin(bottomFeather, 0, 220);
  const bool outsetsWithinRange =
      IsWithin(solidOutsetLeft, -120, 160) &&
      IsWithin(solidOutsetRight, -120, 160) &&
      IsWithin(solidOutsetTop, -120, 160) &&
      IsWithin(solidOutsetBottom, -120, 160);
  if (!IsWithin(blurRadius, 0, 90) || !feathersWithinRange ||
      !outsetsWithinRange || !IsWithin(maskGamma, 0.2, 3) ||
      !IsWithin(maximumMaskAlpha, 0, 1) || !IsWithin(tintOpacity, 0, 1)) {
    napi_throw_range_error(env, nullptr,
                           "backdrop settings are outside supported ranges");
    return nullptr;
  }

  gSettings = BackdropSettings{
      static_cast<CGFloat>(blurRadius),
      static_cast<CGFloat>(leftFeather),
      static_cast<CGFloat>(rightFeather),
      static_cast<CGFloat>(topFeather),
      static_cast<CGFloat>(bottomFeather),
      static_cast<CGFloat>(solidOutsetLeft),
      static_cast<CGFloat>(solidOutsetRight),
      static_cast<CGFloat>(solidOutsetTop),
      static_cast<CGFloat>(solidOutsetBottom),
      maskGamma,
      maximumMaskAlpha,
      tintOpacity,
      windowServerAware ? YES : NO,
      allowsGroupBlending ? YES : NO,
      allowsInPlaceFiltering ? YES : NO,
      disablesOccludedBackdropBlurs ? YES : NO,
      showBackdrop ? YES : NO,
  };

  __block BOOL available = YES;
  RunOnMainSync(^{
    if (gBackdropView == nil) {
      return;
    }
    gBackdropView.settings = gSettings;
    available = CurrentBackdropHealthOnMain();
    if (!available) {
      FailClosedBackdropOnMain(gNativeWindow,
                               @"backdrop settings invalidated the effect");
      return;
    }
    UpdateMousePassThroughOnMain();
  });

  napi_value result;
  napi_get_boolean(env, available, &result);
  return result;
}

napi_value UpdateGeometry(napi_env env, napi_callback_info info) {
  size_t argc = 1;
  napi_value argv[1];
  napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr);
  napi_valuetype type;
  if (argc != 1 || napi_typeof(env, argv[0], &type) != napi_ok ||
      type != napi_object) {
    napi_throw_type_error(env, nullptr,
                          "updateGeometry(geometry) expects an object");
    return nullptr;
  }

  double windowWidth;
  double windowHeight;
  double contentX;
  double contentY;
  double contentWidth;
  double contentHeight;
  double visualWidth;
  double visualHeight;
  if (!ReadNamedDouble(env, argv[0], "windowWidth", &windowWidth) ||
      !ReadNamedDouble(env, argv[0], "windowHeight", &windowHeight) ||
      !ReadNamedDouble(env, argv[0], "contentX", &contentX) ||
      !ReadNamedDouble(env, argv[0], "contentY", &contentY) ||
      !ReadNamedDouble(env, argv[0], "contentWidth", &contentWidth) ||
      !ReadNamedDouble(env, argv[0], "contentHeight", &contentHeight) ||
      !ReadNamedDouble(env, argv[0], "visualWidth", &visualWidth) ||
      !ReadNamedDouble(env, argv[0], "visualHeight", &visualHeight)) {
    return nullptr;
  }

  if (windowWidth <= 0 || windowHeight <= 0 || contentWidth <= 0 ||
      contentHeight <= 0 || visualWidth <= 0 || visualHeight <= 0) {
    napi_throw_range_error(env, nullptr,
                           "geometry sizes must be greater than zero");
    return nullptr;
  }

  gGeometry = BackdropGeometry{
      static_cast<CGFloat>(windowWidth),
      static_cast<CGFloat>(windowHeight),
      static_cast<CGFloat>(contentX),
      static_cast<CGFloat>(contentY),
      static_cast<CGFloat>(contentWidth),
      static_cast<CGFloat>(contentHeight),
      static_cast<CGFloat>(visualWidth),
      static_cast<CGFloat>(visualHeight),
  };
  __block BOOL available = YES;
  RunOnMainSync(^{
    if (gBackdropView == nil) {
      return;
    }
    NSRect frame = gBackdropView.frame;
    frame.size = NSMakeSize(gGeometry.windowWidth, gGeometry.windowHeight);
    gBackdropView.frame = frame;
    gBackdropView.geometry = gGeometry;
    available = CurrentBackdropHealthOnMain();
    if (!available) {
      FailClosedBackdropOnMain(gNativeWindow,
                               @"backdrop geometry update failed");
      return;
    }
    UpdateMousePassThroughOnMain();
  });
  napi_value result;
  napi_get_boolean(env, available, &result);
  return result;
}

napi_value SetRevealOffset(napi_env env, napi_callback_info info) {
  size_t argc = 1;
  napi_value argv[1];
  napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr);
  double offset;
  if (argc != 1 || napi_get_value_double(env, argv[0], &offset) != napi_ok ||
      !std::isfinite(offset)) {
    napi_throw_type_error(env, nullptr,
                          "setRevealOffset(offsetX) expects a finite number");
    return nullptr;
  }

  gRevealOffsetX = static_cast<CGFloat>(offset);
  __block BOOL available = YES;
  RunOnMainSync(^{
    if (gBackdropView == nil) {
      return;
    }
    gBackdropView.revealOffsetX = gRevealOffsetX;
    available = CurrentBackdropHealthOnMain();
    if (!available) {
      FailClosedBackdropOnMain(gNativeWindow,
                               @"backdrop reveal update failed");
      return;
    }
    UpdateMousePassThroughOnMain();
  });
  napi_value result;
  napi_get_boolean(env, available, &result);
  return result;
}

napi_value IsIgnoringMouseEvents(napi_env env, napi_callback_info info) {
  size_t argc = 0;
  napi_get_cb_info(env, info, &argc, nullptr, nullptr, nullptr);
  __block BOOL ignoresMouseEvents = NO;
  RunOnMainSync(^{
    ignoresMouseEvents = gNativeWindow.ignoresMouseEvents;
  });

  napi_value result;
  napi_get_boolean(env, ignoresMouseEvents, &result);
  return result;
}

napi_value Rebuild(napi_env env, napi_callback_info info) {
  size_t argc = 0;
  napi_get_cb_info(env, info, &argc, nullptr, nullptr, nullptr);
  __block BOOL available = NO;
  RunOnMainSync(^{
    const uint64_t generation = ++gBackdropRefreshGeneration;
    available = RefreshBackdropForCurrentSpaceOnMain(NO, YES, NO);
    if (available) {
      InstallWindowServerObserversOnMain();
      InstallPointerPassThroughMonitorsOnMain();
      UpdateMousePassThroughOnMain();
    }
    dispatch_after(
        dispatch_time(DISPATCH_TIME_NOW,
                      static_cast<int64_t>(0.36 * NSEC_PER_SEC)),
        dispatch_get_main_queue(), ^{
          if (generation != gBackdropRefreshGeneration ||
              gBackdropView == nil) {
            return;
          }
          RefreshBackdropForCurrentSpaceOnMain(NO, NO, NO);
        });
  });

  napi_value result;
  napi_get_boolean(env, available, &result);
  return result;
}

napi_value IsAvailable(napi_env env, napi_callback_info info) {
  size_t argc = 0;
  napi_get_cb_info(env, info, &argc, nullptr, nullptr, nullptr);
  __block BOOL available = NO;
  RunOnMainSync(^{
    available = CurrentBackdropHealthOnMain();
  });

  napi_value result;
  napi_get_boolean(env, available, &result);
  return result;
}

napi_value RebuildRevision(napi_env env, napi_callback_info info) {
  size_t argc = 0;
  napi_get_cb_info(env, info, &argc, nullptr, nullptr, nullptr);
  __block uint64_t revision = 0;
  RunOnMainSync(^{
    revision = gBackdropRebuildRevision;
  });

  napi_value result;
  napi_create_double(env, static_cast<double>(revision), &result);
  return result;
}

napi_value MaximumRevealAlignmentError(napi_env env, napi_callback_info info) {
  size_t argc = 0;
  napi_get_cb_info(env, info, &argc, nullptr, nullptr, nullptr);
  __block CGFloat error = INFINITY;
  RunOnMainSync(^{
    if (gBackdropView != nil) {
      error = gBackdropView.maximumRevealAlignmentError;
    }
  });

  napi_value result;
  napi_create_double(env, static_cast<double>(error), &result);
  return result;
}

napi_value IsOrderedBelowContentSurfaces(napi_env env,
                                         napi_callback_info info) {
  size_t argc = 0;
  napi_get_cb_info(env, info, &argc, nullptr, nullptr, nullptr);
  __block BOOL ordered = NO;
  RunOnMainSync(^{
    ordered = gBackdropView.isOrderedBelowContentSurfaces;
  });

  napi_value result;
  napi_get_boolean(env, ordered, &result);
  return result;
}

napi_value Detach(napi_env env, napi_callback_info info) {
  size_t argc = 0;
  napi_get_cb_info(env, info, &argc, nullptr, nullptr, nullptr);
  RunOnMainSync(^{
    DetachOnMain();
  });
  return Undefined(env);
}

void Cleanup(void *) {
  RunOnMainSync(^{
    DetachOnMain();
  });
}

napi_value Init(napi_env env, napi_value exports) {
  napi_property_descriptor properties[] = {
      {"disableWindowAnimations", nullptr, DisableWindowAnimations, nullptr,
       nullptr, nullptr, napi_default, nullptr},
      {"attach", nullptr, Attach, nullptr, nullptr, nullptr, napi_default,
       nullptr},
      {"updateSettings", nullptr, UpdateSettings, nullptr, nullptr, nullptr,
       napi_default, nullptr},
      {"updateGeometry", nullptr, UpdateGeometry, nullptr, nullptr, nullptr,
       napi_default, nullptr},
      {"setRevealOffset", nullptr, SetRevealOffset, nullptr, nullptr, nullptr,
       napi_default, nullptr},
      {"isIgnoringMouseEvents", nullptr, IsIgnoringMouseEvents, nullptr,
       nullptr, nullptr, napi_default, nullptr},
      {"isAvailable", nullptr, IsAvailable, nullptr, nullptr, nullptr,
       napi_default, nullptr},
      {"rebuild", nullptr, Rebuild, nullptr, nullptr, nullptr, napi_default,
       nullptr},
      {"rebuildRevision", nullptr, RebuildRevision, nullptr, nullptr, nullptr,
       napi_default, nullptr},
      {"maximumRevealAlignmentError", nullptr, MaximumRevealAlignmentError,
       nullptr, nullptr, nullptr, napi_default, nullptr},
      {"isOrderedBelowContentSurfaces", nullptr,
       IsOrderedBelowContentSurfaces, nullptr, nullptr, nullptr, napi_default,
       nullptr},
      {"detach", nullptr, Detach, nullptr, nullptr, nullptr, napi_default,
       nullptr},
  };
  napi_define_properties(env, exports,
                         sizeof(properties) / sizeof(properties[0]), properties);
  napi_add_env_cleanup_hook(env, Cleanup, nullptr);
  return exports;
}

}  // namespace

NAPI_MODULE(NODE_GYP_MODULE_NAME, Init)
