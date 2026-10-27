//! Quick Chat's text, drawn with Direct2D and DirectWrite over the effect as the overlay page set it: Inter (Comma's
//! own face, the nearest to SF Pro) at weight 500, Chinese in Microsoft YaHei UI, white with a soft dark halo. Inter
//! comes from `InterVariable.woff2` beside the executable; without it the text is Segoe UI Variable.
//!
//! Everything is drawn in a frame between `begin` and `end`, in px; a group of drawing becomes an image (`group`) that
//! is drawn with a halo, an opacity, a blur or a mask.

use windows::core::{Interface, Result, HSTRING, PCWSTR};
use windows::Win32::Graphics::Direct2D::Common::{
    D2D1_ALPHA_MODE_IGNORE, D2D1_ALPHA_MODE_PREMULTIPLIED, D2D1_COLOR_F, D2D1_COMPOSITE_MODE_SOURCE_OVER, D2D1_FIGURE_BEGIN_HOLLOW,
    D2D1_FIGURE_END_OPEN, D2D1_GRADIENT_STOP, D2D1_PIXEL_FORMAT, D2D_RECT_F, D2D_SIZE_U,
};
use windows::Win32::Graphics::Direct2D::*;
use windows::Win32::Graphics::DirectWrite::*;
use windows::Win32::Graphics::Dxgi::Common::DXGI_FORMAT_B8G8R8A8_UNORM;
use windows::Win32::Graphics::Dxgi::{IDXGIDevice, IDXGISurface, IDXGISwapChain1};
use windows_numerics::{Matrix3x2, Vector2};

/// Inter's ascent and descent, in ems (hhea), which set where a line's baseline sits in its height, as CSS does.
const ASCENT: f32 = 0.96875;
const DESCENT: f32 = 0.2412;
const INTER: &str = "Inter Variable";
const SYSTEM_FACE: &str = "Segoe UI Variable Text";
const CHINESE_FACE: &str = "Microsoft YaHei UI";

pub fn color(r: f32, g: f32, b: f32, a: f32) -> D2D1_COLOR_F {
    D2D1_COLOR_F { r, g, b, a }
}

pub fn rect(left: f32, top: f32, right: f32, bottom: f32) -> D2D_RECT_F {
    D2D_RECT_F { left, top, right, bottom }
}

/// An image drawn into a bitmap (`Ink::bake`), and where its top left goes.
pub struct Baked {
    image: ID2D1Image,
    at: Vector2,
}

pub struct Ink {
    pub factory: IDWriteFactory5,
    pub d2d: ID2D1Factory1,
    pub context: ID2D1DeviceContext,
    target: Option<ID2D1Bitmap1>,
    pub white: ID2D1SolidColorBrush,
    pub clear: ID2D1SolidColorBrush,
    /// Inter, when it loaded, and the family the text is set in.
    collection: Option<IDWriteFontCollection>,
    family: String,
    fallback: Option<IDWriteFontFallback>,
    /// Effects made in earlier frames, by kind, and how many of each this frame has taken: each draw takes its own,
    /// and they are used again once the frame is drawn.
    effects: std::cell::RefCell<Vec<(windows::core::GUID, Vec<ID2D1Effect>, usize)>>,
}

impl Ink {
    pub fn new(dxgi_device: &IDXGIDevice) -> Result<Self> {
        unsafe {
            let d2d: ID2D1Factory1 = D2D1CreateFactory(D2D1_FACTORY_TYPE_SINGLE_THREADED, None)?;
            let device = d2d.CreateDevice(dxgi_device)?;
            let context = device.CreateDeviceContext(D2D1_DEVICE_CONTEXT_OPTIONS_NONE)?;
            context.SetUnitMode(D2D1_UNIT_MODE_PIXELS);
            // Gray smoothing, as the page's own layer had it: no ClearType's colored edges over the moving screen.
            context.SetTextAntialiasMode(D2D1_TEXT_ANTIALIAS_MODE_GRAYSCALE);
            let factory: IDWriteFactory5 = DWriteCreateFactory(DWRITE_FACTORY_TYPE_SHARED)?;
            let white = context.CreateSolidColorBrush(&color(1.0, 1.0, 1.0, 1.0), None)?;
            let clear = context.CreateSolidColorBrush(&color(1.0, 1.0, 1.0, 0.0), None)?;
            let collection = load_inter(&factory)
                .and_then(|c| c.cast::<IDWriteFontCollection>())
                .map_err(|error| eprintln!("QuickChatHost has no Inter: {error}"))
                .ok();
            let family = if collection.as_ref().is_some_and(|c| has_family(c, INTER)) { INTER } else { SYSTEM_FACE };
            let fallback = chinese_fallback(&factory).ok();
            Ok(Self {
                factory,
                d2d,
                context,
                target: None,
                white,
                clear,
                collection,
                family: family.into(),
                fallback,
                effects: Default::default(),
            })
        }
    }

    /// The swap chain's back buffer as the target (again after it resized); `None` lets it go first.
    pub fn set_target(&mut self, swap_chain: Option<&IDXGISwapChain1>) -> Result<()> {
        unsafe {
            self.context.SetTarget(None::<&ID2D1Image>);
            self.target = None;
            let Some(swap_chain) = swap_chain else { return Ok(()) };
            let surface: IDXGISurface = swap_chain.GetBuffer(0)?;
            let bitmap = self.context.CreateBitmapFromDxgiSurface(
                &surface,
                Some(&D2D1_BITMAP_PROPERTIES1 {
                    pixelFormat: D2D1_PIXEL_FORMAT { format: DXGI_FORMAT_B8G8R8A8_UNORM, alphaMode: D2D1_ALPHA_MODE_IGNORE },
                    dpiX: 96.0,
                    dpiY: 96.0,
                    bitmapOptions: D2D1_BITMAP_OPTIONS_TARGET | D2D1_BITMAP_OPTIONS_CANNOT_DRAW,
                    ..Default::default()
                }),
            )?;
            self.context.SetTarget(&bitmap);
            self.target = Some(bitmap);
        }
        Ok(())
    }

    pub fn has_target(&self) -> bool {
        self.target.is_some()
    }

    pub fn begin(&self) {
        for (_, _, taken) in self.effects.borrow_mut().iter_mut() {
            *taken = 0;
        }
        unsafe {
            self.context.BeginDraw();
            self.context.SetTransform(&Matrix3x2::identity());
        }
    }

    pub fn end(&self) -> Result<()> {
        unsafe { self.context.EndDraw(None, None) }
    }

    /// What `draw` draws, as an image to draw later (with a halo, a blur, at an opacity).
    pub fn group(&self, draw: impl FnOnce(&ID2D1DeviceContext) -> Result<()>) -> Result<ID2D1Image> {
        unsafe {
            let list = self.context.CreateCommandList()?;
            let transform = self.transform();
            // Groups nest: the one drawing this one is the target again after it.
            let outer = self.context.GetTarget().ok();
            self.context.SetTarget(&list);
            self.context.SetTransform(&Matrix3x2::identity());
            let drawn = draw(&self.context);
            self.context.SetTransform(&transform);
            list.Close()?;
            self.context.SetTarget(outer.as_ref());
            drawn?;
            list.cast()
        }
    }

    /// `image` drawn once into a bitmap of its own, to draw again in later frames without drawing it anew (text and
    /// its halo cost far more to draw than a bitmap). None when it draws nothing.
    pub fn bake(&self, image: &ID2D1Image) -> Result<Option<Baked>> {
        unsafe {
            let bounds = self.context.GetImageLocalBounds(image)?;
            let (left, top) = (bounds.left.floor(), bounds.top.floor());
            let (width, height) = ((bounds.right - left).ceil(), (bounds.bottom - top).ceil());
            if !(width >= 1.0 && height >= 1.0) || width > 16384.0 || height > 16384.0 {
                return Ok(None);
            }
            let bitmap = self.context.CreateBitmap(
                D2D_SIZE_U { width: width as u32, height: height as u32 },
                None,
                0,
                &D2D1_BITMAP_PROPERTIES1 {
                    pixelFormat: D2D1_PIXEL_FORMAT {
                        format: DXGI_FORMAT_B8G8R8A8_UNORM,
                        alphaMode: D2D1_ALPHA_MODE_PREMULTIPLIED,
                    },
                    dpiX: 96.0,
                    dpiY: 96.0,
                    bitmapOptions: D2D1_BITMAP_OPTIONS_TARGET,
                    ..Default::default()
                },
            )?;
            let outer = self.context.GetTarget().ok();
            let transform = self.transform();
            self.context.SetTarget(&bitmap);
            self.context.SetTransform(&Matrix3x2::identity());
            self.context.Clear(Some(&color(0.0, 0.0, 0.0, 0.0)));
            self.context.DrawImage(
                image,
                Some(&Vector2::new(-left, -top)),
                None,
                D2D1_INTERPOLATION_MODE_LINEAR,
                D2D1_COMPOSITE_MODE_SOURCE_OVER,
            );
            self.context.SetTransform(&transform);
            self.context.SetTarget(outer.as_ref());
            Ok(Some(Baked { image: bitmap.cast()?, at: Vector2::new(left, top) }))
        }
    }

    /// A baked image, where it was, at `opacity`, through `mask` when given.
    pub fn draw_baked(&self, baked: &Baked, opacity: f32, mask: Option<&ID2D1Brush>) -> Result<()> {
        let transform = self.transform();
        unsafe {
            self.context.SetTransform(&(Matrix3x2::translation(baked.at.X, baked.at.Y) * transform));
        }
        // The mask is where it is on the overlay, so it moves back by as much.
        let drawn = match mask {
            Some(mask) => unsafe {
                let mut old = Matrix3x2::default();
                mask.GetTransform(&mut old);
                mask.SetTransform(&(old * Matrix3x2::translation(-baked.at.X, -baked.at.Y)));
                let drawn = self.draw_image(&baked.image, opacity, Some(mask));
                mask.SetTransform(&old);
                drawn
            },
            None => self.draw_image(&baked.image, opacity, None),
        };
        unsafe { self.context.SetTransform(&transform) };
        drawn
    }

    /// An effect of `kind` for this frame's next draw.
    fn effect(&self, kind: &windows::core::GUID) -> Result<ID2D1Effect> {
        let mut effects = self.effects.borrow_mut();
        let index = match effects.iter().position(|(k, _, _)| k == kind) {
            Some(index) => index,
            None => {
                effects.push((*kind, Vec::new(), 0));
                effects.len() - 1
            }
        };
        let (_, made, taken) = &mut effects[index];
        if *taken == made.len() {
            made.push(unsafe { self.context.CreateEffect(kind)? });
        }
        *taken += 1;
        Ok(made[*taken - 1].clone())
    }

    fn transform(&self) -> Matrix3x2 {
        let mut transform = Matrix3x2::default();
        unsafe { self.context.GetTransform(&mut transform) };
        transform
    }

    /// `image` with a close dark halo under it, as CSS's `text-shadow: 0 0 2σ rgb(0 0 0 / alpha)`.
    pub fn with_halo(&self, image: &ID2D1Image, sigma: f32, alpha: f32) -> Result<ID2D1Image> {
        unsafe {
            let shadow = self.effect(&CLSID_D2D1Shadow)?;
            shadow.SetInput(0, image, true);
            shadow.SetValue(
                D2D1_SHADOW_PROP_BLUR_STANDARD_DEVIATION.0 as u32,
                D2D1_PROPERTY_TYPE_FLOAT,
                &sigma.to_le_bytes(),
            )?;
            let black: Vec<u8> = [0.0f32, 0.0, 0.0, alpha].iter().flat_map(|v| v.to_le_bytes()).collect();
            shadow.SetValue(D2D1_SHADOW_PROP_COLOR.0 as u32, D2D1_PROPERTY_TYPE_VECTOR4, &black)?;
            let composite = self.effect(&CLSID_D2D1Composite)?;
            composite.SetInputCount(2)?;
            composite.SetInput(0, &shadow.cast::<ID2D1Image>()?, true);
            composite.SetInput(1, image, true);
            composite.cast()
        }
    }

    /// `image` blurred as CSS's `filter: blur(radius)`.
    pub fn blurred(&self, image: &ID2D1Image, radius: f32) -> Result<ID2D1Image> {
        if radius <= 0.01 {
            return Ok(image.clone());
        }
        unsafe {
            let blur = self.effect(&CLSID_D2D1GaussianBlur)?;
            blur.SetInput(0, image, true);
            blur.SetValue(
                D2D1_GAUSSIANBLUR_PROP_STANDARD_DEVIATION.0 as u32,
                D2D1_PROPERTY_TYPE_FLOAT,
                &radius.to_le_bytes(),
            )?;
            blur.cast()
        }
    }

    /// Draws `image` at `opacity`, through `mask` (an opacity brush) when given.
    pub fn draw_image(&self, image: &ID2D1Image, opacity: f32, mask: Option<&ID2D1Brush>) -> Result<()> {
        if opacity <= 0.001 {
            return Ok(());
        }
        unsafe {
            let layered = opacity < 0.999 || mask.is_some();
            if layered {
                let parameters = D2D1_LAYER_PARAMETERS1 {
                    contentBounds: rect(-1e7, -1e7, 1e7, 1e7),
                    geometricMask: std::mem::ManuallyDrop::new(None),
                    maskAntialiasMode: D2D1_ANTIALIAS_MODE_PER_PRIMITIVE,
                    maskTransform: Matrix3x2::identity(),
                    opacity,
                    opacityBrush: std::mem::ManuallyDrop::new(mask.cloned()),
                    layerOptions: D2D1_LAYER_OPTIONS1_NONE,
                };
                self.context.PushLayer(&parameters, None::<&ID2D1Layer>);
                let _ = std::mem::ManuallyDrop::into_inner(parameters.opacityBrush);
            }
            self.context.DrawImage(image, None, None, D2D1_INTERPOLATION_MODE_LINEAR, D2D1_COMPOSITE_MODE_SOURCE_OVER);
            if layered {
                self.context.PopLayer();
            }
        }
        Ok(())
    }

    /// A text format of `size` px: Comma's face at weight 500, wrapping, its lines `line` px apart with the baseline
    /// where CSS puts it; centered, or from the left.
    pub fn format(&self, size: f32, line: f32, centered: bool) -> Result<IDWriteTextFormat> {
        unsafe {
            let format = self.factory.CreateTextFormat(
                &HSTRING::from(&self.family),
                self.collection.as_ref(),
                DWRITE_FONT_WEIGHT_MEDIUM,
                DWRITE_FONT_STYLE_NORMAL,
                DWRITE_FONT_STRETCH_NORMAL,
                size,
                &HSTRING::from("zh-CN"),
            )?;
            format.SetTextAlignment(if centered { DWRITE_TEXT_ALIGNMENT_CENTER } else { DWRITE_TEXT_ALIGNMENT_LEADING })?;
            format.SetWordWrapping(DWRITE_WORD_WRAPPING_WRAP)?;
            let baseline = (line - (ASCENT + DESCENT) * size) / 2.0 + ASCENT * size;
            format.SetLineSpacing(DWRITE_LINE_SPACING_METHOD_UNIFORM, line, baseline)?;
            if let (Some(fallback), Ok(format1)) = (&self.fallback, format.cast::<IDWriteTextFormat1>()) {
                let _ = format1.SetFontFallback(fallback);
            }
            Ok(format)
        }
    }

    /// `text` laid out in `format`, `width` px wide.
    pub fn layout(&self, text: &[u16], format: &IDWriteTextFormat, width: f32) -> Result<IDWriteTextLayout> {
        unsafe { self.factory.CreateTextLayout(text, format, width, f32::MAX) }
    }

    pub fn gradient(&self, stops: &[(f32, D2D1_COLOR_F)], from: Vector2, to: Vector2) -> Result<ID2D1LinearGradientBrush> {
        let stops: Vec<D2D1_GRADIENT_STOP> =
            stops.iter().map(|&(position, color)| D2D1_GRADIENT_STOP { position, color }).collect();
        unsafe {
            let collection = self.context.CreateGradientStopCollection(
                &stops,
                D2D1_COLOR_SPACE_SRGB,
                D2D1_COLOR_SPACE_SRGB,
                D2D1_BUFFER_PRECISION_8BPC_UNORM_SRGB,
                D2D1_EXTEND_MODE_CLAMP,
                D2D1_COLOR_INTERPOLATION_MODE_STRAIGHT,
            )?;
            self.context.CreateLinearGradientBrush(
                &D2D1_LINEAR_GRADIENT_BRUSH_PROPERTIES { startPoint: from, endPoint: to },
                None,
                &collection,
            )
        }
    }

    pub fn brush(&self, color: D2D1_COLOR_F) -> Result<ID2D1SolidColorBrush> {
        unsafe { self.context.CreateSolidColorBrush(&color, None) }
    }

    /// An open path through `points`.
    pub fn polyline(&self, points: &[Vector2]) -> Result<ID2D1PathGeometry1> {
        unsafe {
            let path = self.d2d.CreatePathGeometry()?;
            let sink = path.Open()?;
            if let Some((first, rest)) = points.split_first() {
                sink.BeginFigure(*first, D2D1_FIGURE_BEGIN_HOLLOW);
                sink.AddLines(rest);
                sink.EndFigure(D2D1_FIGURE_END_OPEN);
            }
            sink.Close()?;
            Ok(path)
        }
    }

    pub fn round_stroke(&self) -> Result<ID2D1StrokeStyle> {
        unsafe {
            self.d2d
                .CreateStrokeStyle(
                    &D2D1_STROKE_STYLE_PROPERTIES1 {
                        startCap: D2D1_CAP_STYLE_ROUND,
                        endCap: D2D1_CAP_STYLE_ROUND,
                        lineJoin: D2D1_LINE_JOIN_ROUND,
                        ..Default::default()
                    },
                    None,
                )?
                .cast()
        }
    }
}

/// The layout's height: its lines, at least one.
pub fn layout_height(layout: &IDWriteTextLayout) -> f32 {
    let mut metrics = DWRITE_TEXT_METRICS::default();
    unsafe {
        let _ = layout.GetMetrics(&mut metrics);
    }
    metrics.height
}

/// Where each line of a layout starts in its text, and its length (with its trailing break and spaces).
pub fn layout_lines(layout: &IDWriteTextLayout) -> Vec<(u32, u32)> {
    unsafe {
        let mut count = 0u32;
        let _ = layout.GetLineMetrics(None, &mut count);
        let mut metrics = vec![DWRITE_LINE_METRICS::default(); count as usize];
        if layout.GetLineMetrics(Some(&mut metrics), &mut count).is_err() {
            return Vec::new();
        }
        let mut start = 0;
        metrics
            .iter()
            .map(|line| {
                let range = (start, line.length);
                start += line.length;
                range
            })
            .collect()
    }
}

/// The offset in the text of the point (`x`, `y`) of the layout, before or after the character there, and whether
/// the point is on the text.
pub fn hit(layout: &IDWriteTextLayout, x: f32, y: f32) -> (u32, bool) {
    let (mut trailing, mut inside) = (Default::default(), Default::default());
    let mut metrics = DWRITE_HIT_TEST_METRICS::default();
    unsafe {
        let _ = layout.HitTestPoint(x, y, &mut trailing, &mut inside, &mut metrics);
    }
    let trailing: windows::core::BOOL = trailing;
    let inside: windows::core::BOOL = inside;
    (metrics.textPosition + if trailing.as_bool() { metrics.length } else { 0 }, inside.as_bool())
}

/// Where the caret before `position` is in the layout: its x, the top of its line, and the line's height.
pub fn caret_at(layout: &IDWriteTextLayout, position: u32) -> (f32, f32, f32) {
    let (mut x, mut y) = (0.0, 0.0);
    let mut metrics = DWRITE_HIT_TEST_METRICS::default();
    unsafe {
        let _ = layout.HitTestTextPosition(position, false, &mut x, &mut y, &mut metrics);
    }
    (x, metrics.top, metrics.height)
}

/// The rectangles covering the text from `start`, `length` long.
pub fn range_rects(layout: &IDWriteTextLayout, start: u32, length: u32) -> Vec<D2D_RECT_F> {
    unsafe {
        let mut count = 0u32;
        let _ = layout.HitTestTextRange(start, length, 0.0, 0.0, None, &mut count);
        let mut metrics = vec![DWRITE_HIT_TEST_METRICS::default(); count as usize];
        if layout.HitTestTextRange(start, length, 0.0, 0.0, Some(&mut metrics), &mut count).is_err() {
            return Vec::new();
        }
        metrics.iter().map(|m| rect(m.left, m.top, m.left + m.width, m.top + m.height)).collect()
    }
}

fn has_family(collection: &IDWriteFontCollection, name: &str) -> bool {
    let (mut index, mut exists) = (0u32, windows::core::BOOL::default());
    unsafe { collection.FindFamilyName(&HSTRING::from(name), &mut index, &mut exists).is_ok() && exists.as_bool() }
}

/// Inter from its WOFF2 beside the executable, unpacked into memory.
fn load_inter(factory: &IDWriteFactory5) -> Result<IDWriteFontCollection1> {
    let fail = |message: String| windows::core::Error::new(windows::core::HRESULT(0x80004005u32 as i32), message);
    let path = std::env::current_exe()
        .ok()
        .and_then(|exe| exe.parent().map(|dir| dir.join("InterVariable.woff2")))
        .ok_or_else(|| fail("no executable path".into()))?;
    let packed = std::fs::read(&path).map_err(|e| fail(format!("{}: {e}", path.display())))?;
    unsafe {
        let stream = factory.UnpackFontFile(DWRITE_CONTAINER_TYPE_WOFF2, packed.as_ptr() as _, packed.len() as u32)?;
        let size = stream.GetFileSize()?;
        let (mut start, mut context) = (std::ptr::null_mut(), std::ptr::null_mut());
        stream.ReadFileFragment(&mut start, 0, size, &mut context)?;
        let bytes = std::slice::from_raw_parts(start as *const u8, size as usize).to_vec();
        stream.ReleaseFileFragment(context);
        let loader = factory.CreateInMemoryFontFileLoader()?;
        factory.RegisterFontFileLoader(&loader)?;
        // Without an owner, the loader keeps its own copy of the bytes.
        let file = loader.CreateInMemoryFontFileReference(factory, bytes.as_ptr() as _, bytes.len() as u32, None)?;
        let builder = factory.CreateFontSetBuilder()?;
        builder.AddFontFile(&file)?;
        let set = builder.CreateFontSet()?;
        factory.CreateFontCollectionFromFontSet(&set)
    }
}

/// The system's fallback, with Chinese in Microsoft YaHei UI first, as the page had it.
fn chinese_fallback(factory: &IDWriteFactory5) -> Result<IDWriteFontFallback> {
    unsafe {
        let builder = factory.CreateFontFallbackBuilder()?;
        let ranges = [
            DWRITE_UNICODE_RANGE { first: 0x2E80, last: 0x9FFF },
            DWRITE_UNICODE_RANGE { first: 0xF900, last: 0xFAFF },
            DWRITE_UNICODE_RANGE { first: 0xFE30, last: 0xFE4F },
            DWRITE_UNICODE_RANGE { first: 0xFF00, last: 0xFFEF },
            DWRITE_UNICODE_RANGE { first: 0x20000, last: 0x2FA1F },
        ];
        let name = HSTRING::from(CHINESE_FACE);
        builder.AddMapping(&ranges, &[name.as_ptr()], None, PCWSTR::null(), PCWSTR::null(), 1.0)?;
        builder.AddMappings(&factory.GetSystemFontFallback()?)?;
        builder.CreateFontFallback()
    }
}
