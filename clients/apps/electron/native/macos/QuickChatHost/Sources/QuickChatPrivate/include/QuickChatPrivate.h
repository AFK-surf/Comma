#import <QuartzCore/QuartzCore.h>

NS_ASSUME_NONNULL_BEGIN

/// A CAMeshTransform (a private Core Animation class) over a `columns` ×
/// `rows` grid of a layer: grid point (c, r) shows the layer's content from
/// `sources[r * (columns + 1) + c]`. Points are in the layer's unit
/// coordinates, y up. Meshes with the same grid interpolate, so they animate.
id QCMeshTransform(NSInteger columns, NSInteger rows, const CGPoint *sources);

NS_ASSUME_NONNULL_END
