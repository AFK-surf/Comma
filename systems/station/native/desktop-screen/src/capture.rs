// The display's pictures: Windows.Graphics.Capture on a D3D11 device, each new one copied into a texture of the view's
// own (the capture's buffers go back to it at once; an HDR display's taken as FP16 and made SDR on the way, hdr.rs),
// and the video processor that scales that into the view's bounds
// as NV12 (for the encoder) or BGRA (for a JPEG).
use std::sync::mpsc::Sender;

use windows::Foundation::{TimeSpan, TypedEventHandler};
use windows::Graphics::Capture::{Direct3D11CaptureFramePool, GraphicsCaptureAccess, GraphicsCaptureAccessKind, GraphicsCaptureItem, GraphicsCaptureSession};
use windows::Graphics::DirectX::Direct3D11::IDirect3DDevice;
use windows::Graphics::DirectX::DirectXPixelFormat;
use windows::Graphics::SizeInt32;
use windows::Win32::Foundation::{HMODULE, RECT};
use windows::Win32::Graphics::Direct3D::{D3D_DRIVER_TYPE_HARDWARE, D3D_FEATURE_LEVEL, D3D_FEATURE_LEVEL_10_1, D3D_FEATURE_LEVEL_11_0, D3D_FEATURE_LEVEL_11_1};
use windows::Win32::Graphics::Direct3D11::*;
use windows::Win32::Graphics::Dxgi::Common::*;
use windows::Win32::Graphics::Dxgi::IDXGIDevice;
use windows::Win32::Graphics::Gdi::HMONITOR;
use windows::Win32::System::WinRT::Direct3D11::{CreateDirect3D11DeviceFromDXGIDevice, IDirect3DDxgiInterfaceAccess};
use windows::Win32::System::WinRT::Graphics::Capture::IGraphicsCaptureItemInterop;
use windows::core::{Interface, Result};

pub struct Gpu {
    pub device: ID3D11Device,
    pub context: ID3D11DeviceContext,
    video: ID3D11VideoDevice,
    vcontext: ID3D11VideoContext,
}

impl Gpu {
    pub fn new() -> Result<Gpu> {
        let levels: [D3D_FEATURE_LEVEL; 3] = [D3D_FEATURE_LEVEL_11_1, D3D_FEATURE_LEVEL_11_0, D3D_FEATURE_LEVEL_10_1];
        let (mut device, mut context) = (None, None);
        unsafe {
            D3D11CreateDevice(
                None,
                D3D_DRIVER_TYPE_HARDWARE,
                HMODULE::default(),
                D3D11_CREATE_DEVICE_BGRA_SUPPORT | D3D11_CREATE_DEVICE_VIDEO_SUPPORT,
                Some(&levels),
                D3D11_SDK_VERSION,
                Some(&mut device),
                None,
                Some(&mut context),
            )?;
        }
        let device: ID3D11Device = device.unwrap();
        let context: ID3D11DeviceContext = context.unwrap();
        // Media Foundation's encoder uses the device from its own threads.
        if let Ok(guarded) = device.cast::<ID3D11Multithread>() {
            unsafe {
                let _ = guarded.SetMultithreadProtected(true);
            }
        }
        let video = device.cast::<ID3D11VideoDevice>()?;
        let vcontext = context.cast::<ID3D11VideoContext>()?;
        Ok(Gpu { device, context, video, vcontext })
    }

    pub fn texture(&self, width: u32, height: u32, format: DXGI_FORMAT, bind: D3D11_BIND_FLAG) -> Result<ID3D11Texture2D> {
        let desc = D3D11_TEXTURE2D_DESC {
            Width: width,
            Height: height,
            MipLevels: 1,
            ArraySize: 1,
            Format: format,
            SampleDesc: DXGI_SAMPLE_DESC { Count: 1, Quality: 0 },
            Usage: D3D11_USAGE_DEFAULT,
            BindFlags: bind.0 as u32,
            CPUAccessFlags: 0,
            MiscFlags: 0,
        };
        let mut texture = None;
        unsafe { self.device.CreateTexture2D(&desc, None, Some(&mut texture))? };
        Ok(texture.unwrap())
    }

    /// A texture's pixels on the CPU: rows of `pitch` bytes (`height` rows of luma then half as many of chroma, for NV12).
    pub fn read(&self, texture: &ID3D11Texture2D, staging: &mut Option<ID3D11Texture2D>) -> Result<(Vec<u8>, usize)> {
        let mut desc = D3D11_TEXTURE2D_DESC::default();
        unsafe { texture.GetDesc(&mut desc) };
        let fits = staging.as_ref().is_some_and(|s| {
            let mut d = D3D11_TEXTURE2D_DESC::default();
            unsafe { s.GetDesc(&mut d) };
            d.Width == desc.Width && d.Height == desc.Height && d.Format == desc.Format
        });
        if !fits {
            let mut d = desc;
            d.Usage = D3D11_USAGE_STAGING;
            d.BindFlags = 0;
            d.CPUAccessFlags = D3D11_CPU_ACCESS_READ.0 as u32;
            d.MiscFlags = 0;
            let mut made = None;
            unsafe { self.device.CreateTexture2D(&d, None, Some(&mut made))? };
            *staging = made;
        }
        let staging = staging.as_ref().unwrap();
        let rows = if desc.Format == DXGI_FORMAT_NV12 { desc.Height as usize * 3 / 2 } else { desc.Height as usize };
        unsafe {
            self.context.CopyResource(staging, texture);
            let mut mapped = D3D11_MAPPED_SUBRESOURCE::default();
            self.context.Map(staging, 0, D3D11_MAP_READ, 0, Some(&mut mapped))?;
            let pitch = mapped.RowPitch as usize;
            let bytes = std::slice::from_raw_parts(mapped.pData as *const u8, pitch * rows).to_vec();
            self.context.Unmap(staging, 0);
            Ok((bytes, pitch))
        }
    }
}

/// The capture of one display: each new picture told on `arrived`, then taken with `take`.
pub struct Capture {
    pool: Direct3D11CaptureFramePool,
    session: GraphicsCaptureSession,
    device: IDirect3DDevice,
    size: SizeInt32,
    token: i64,
    item: GraphicsCaptureItem,
    closed: i64,
    /// The pictures' format: FP16 on an HDR display (made SDR by `sdr`), else BGRA.
    format: DirectXPixelFormat,
    sdr: Option<super::hdr::ToSdr>,
    /// The display it captures.
    pub monitor: HMONITOR,
}

impl Capture {
    /// `cursor`: the pointer drawn in the pictures (a JPEG's: an agent's view); a video's leave it out (cursor.rs says it).
    /// `fps`: the most pictures a second the view asked (its 帧率), the capture asked no more often (Windows 11 24H2 on;
    /// before, as often as the display draws, the view's own pace holding the rest back); none, as often as it draws.
    pub fn start(gpu: &Gpu, monitor: HMONITOR, arrived: Sender<super::view::Msg>, cursor: bool, fps: Option<u32>) -> Result<Capture> {
        let interop = windows::core::factory::<GraphicsCaptureItem, IGraphicsCaptureItemInterop>()?;
        let item: GraphicsCaptureItem = unsafe { interop.CreateForMonitor(monitor)? };
        let dxgi: IDXGIDevice = gpu.device.cast()?;
        let device: IDirect3DDevice = unsafe { CreateDirect3D11DeviceFromDXGIDevice(&dxgi)? }.cast()?;
        let size = item.Size()?;
        // HDR on: FP16, made SDR here (an HDR display read as BGRA comes out washed out). Without the shader, as BGRA.
        let sdr = super::hdr::sdr_white(monitor).and_then(|white| super::hdr::ToSdr::new(&gpu.device, white).ok());
        let format = if sdr.is_some() { DirectXPixelFormat::R16G16B16A16Float } else { DirectXPixelFormat::B8G8R8A8UIntNormalized };
        let pool = Direct3D11CaptureFramePool::CreateFreeThreaded(&device, format, 2, size)?;
        let told = arrived.clone();
        let token = pool.FrameArrived(&TypedEventHandler::new(move |_, _| {
            let _ = told.send(super::view::Msg::Frame);
            Ok(())
        }))?;
        // The display gone (unplugged, turned off, its driver started again): the view with it.
        let closed = item.Closed(&TypedEventHandler::new(move |_, _| {
            let _ = arrived.send(super::view::Msg::Closed);
            Ok(())
        }))?;
        // No yellow border round the display (Windows 11; asked first, as an app without a package is let at once).
        if let Ok(asked) = GraphicsCaptureAccess::RequestAccessAsync(GraphicsCaptureAccessKind::Borderless) {
            let _ = asked.join();
        }
        let session = pool.CreateCaptureSession(&item)?;
        let _ = session.SetIsCursorCaptureEnabled(cursor);
        let _ = session.SetIsBorderRequired(false);
        if let Some(fps) = fps.filter(|&f| f > 0) {
            let _ = session.SetMinUpdateInterval(TimeSpan { Duration: 10_000_000 / fps as i64 });
        }
        session.StartCapture()?;
        Ok(Capture { pool, session, device, size, token, item, closed, format, sdr, monitor })
    }

    /// The SDR white (nits) an HDR display's pictures are made SDR at; none when they are not.
    pub fn hdr_white(&self) -> Option<f32> {
        self.sdr.as_ref().map(|s| s.white)
    }

    /// The newest picture since the last (copied into `into`, made or remade at its size), its time (µs, the system's
    /// QPC clock); none when none came.
    pub fn take(&mut self, gpu: &Gpu, into: &mut Option<ID3D11Texture2D>) -> Result<Option<i64>> {
        let (mut newest, mut changed) = (None, false);
        while let Ok(frame) = self.pool.TryGetNextFrame() {
            // What changed in it (Windows 11 24H2 on; before, every picture is taken as changed): one where nothing did
            // (the compositor drew the display again as it was) is not a new picture.
            changed |= frame.DirtyRegions().and_then(|regions| regions.Size()).map_or(true, |n| n > 0);
            newest = Some(frame);
        }
        let Some(frame) = newest else { return Ok(None) };
        if !changed && into.is_some() {
            frame.Close()?;
            return Ok(None);
        }
        let size = frame.ContentSize()?;
        let at = frame.SystemRelativeTime()?.Duration / 10;
        let access: IDirect3DDxgiInterfaceAccess = frame.Surface()?.cast()?;
        let source: ID3D11Texture2D = unsafe { access.GetInterface()? };
        let mut desc = D3D11_TEXTURE2D_DESC::default();
        unsafe { source.GetDesc(&mut desc) };
        // The display changed size: the pool too, from the next picture (this one is the old size, cropped to the new).
        if size.Width != self.size.Width || size.Height != self.size.Height {
            self.size = size;
            self.pool.Recreate(&self.device, self.format, 2, size)?;
        }
        let (width, height) = (desc.Width.min(size.Width as u32), desc.Height.min(size.Height as u32));
        let fits = into.as_ref().is_some_and(|t| {
            let mut d = D3D11_TEXTURE2D_DESC::default();
            unsafe { t.GetDesc(&mut d) };
            d.Width == width && d.Height == height
        });
        if !fits {
            *into = Some(gpu.texture(width, height, DXGI_FORMAT_B8G8R8A8_UNORM, D3D11_BIND_RENDER_TARGET | D3D11_BIND_SHADER_RESOURCE)?);
        }
        let target = into.as_ref().unwrap();
        if let Some(sdr) = self.sdr.as_mut() {
            sdr.run(&gpu.device, &gpu.context, &source, target, width, height)?;
        } else {
            let region = D3D11_BOX { left: 0, top: 0, front: 0, right: width, bottom: height, back: 1 };
            unsafe { gpu.context.CopySubresourceRegion(target, 0, 0, 0, 0, &source, 0, Some(&region)) };
        }
        frame.Close()?;
        Ok(Some(at))
    }
}

impl Drop for Capture {
    fn drop(&mut self) {
        let _ = self.pool.RemoveFrameArrived(self.token);
        let _ = self.item.RemoveClosed(self.closed);
        let _ = self.session.Close();
        let _ = self.pool.Close();
    }
}

/// The video processor from a BGRA picture of one size to a texture of another, NV12 (BT.709, studio range: what the
/// encoder takes) or BGRA.
pub struct Scaler {
    pub from: (u32, u32),
    /// The part of the picture scaled (left, top, width, height in its pixels): all of it, or a part framed alone.
    crop: (u32, u32, u32, u32),
    pub to: (u32, u32),
    pub format: DXGI_FORMAT,
    enumerator: ID3D11VideoProcessorEnumerator,
    processor: ID3D11VideoProcessor,
    /// Its outputs, used in turn (the encoder may still read the one before).
    outputs: Vec<(ID3D11Texture2D, ID3D11VideoProcessorOutputView)>,
    turn: usize,
}

impl Scaler {
    pub fn new(gpu: &Gpu, from: (u32, u32), to: (u32, u32), format: DXGI_FORMAT) -> Result<Scaler> {
        let rate = DXGI_RATIONAL { Numerator: 60, Denominator: 1 };
        let content = D3D11_VIDEO_PROCESSOR_CONTENT_DESC {
            InputFrameFormat: D3D11_VIDEO_FRAME_FORMAT_PROGRESSIVE,
            InputFrameRate: rate,
            InputWidth: from.0,
            InputHeight: from.1,
            OutputFrameRate: rate,
            OutputWidth: to.0,
            OutputHeight: to.1,
            Usage: D3D11_VIDEO_USAGE_OPTIMAL_QUALITY,
        };
        let enumerator = unsafe { gpu.video.CreateVideoProcessorEnumerator(&content)? };
        let processor = unsafe { gpu.video.CreateVideoProcessor(&enumerator, 0)? };
        unsafe {
            let whole = |w: u32, h: u32| RECT { left: 0, top: 0, right: w as i32, bottom: h as i32 };
            gpu.vcontext.VideoProcessorSetStreamFrameFormat(&processor, 0, D3D11_VIDEO_FRAME_FORMAT_PROGRESSIVE);
            gpu.vcontext.VideoProcessorSetStreamAutoProcessingMode(&processor, 0, false);
            gpu.vcontext.VideoProcessorSetStreamSourceRect(&processor, 0, true, Some(&whole(from.0, from.1)));
            gpu.vcontext.VideoProcessorSetStreamDestRect(&processor, 0, true, Some(&whole(to.0, to.1)));
            gpu.vcontext.VideoProcessorSetOutputTargetRect(&processor, true, Some(&whole(to.0, to.1)));
            if let Ok(spaces) = gpu.vcontext.cast::<ID3D11VideoContext1>() {
                spaces.VideoProcessorSetStreamColorSpace1(&processor, 0, DXGI_COLOR_SPACE_RGB_FULL_G22_NONE_P709);
                spaces.VideoProcessorSetOutputColorSpace1(&processor, if format == DXGI_FORMAT_NV12 { DXGI_COLOR_SPACE_YCBCR_STUDIO_G22_LEFT_P709 } else { DXGI_COLOR_SPACE_RGB_FULL_G22_NONE_P709 });
            }
        }
        let mut outputs = Vec::new();
        for _ in 0..if format == DXGI_FORMAT_NV12 { 2 } else { 1 } {
            // The encoder's own bind flag where the driver takes it (some hardware encoders want it), else without.
            let texture = if format == DXGI_FORMAT_NV12 {
                gpu.texture(to.0, to.1, format, D3D11_BIND_RENDER_TARGET | D3D11_BIND_VIDEO_ENCODER).or_else(|_| gpu.texture(to.0, to.1, format, D3D11_BIND_RENDER_TARGET))?
            } else {
                gpu.texture(to.0, to.1, format, D3D11_BIND_RENDER_TARGET)?
            };
            let desc = D3D11_VIDEO_PROCESSOR_OUTPUT_VIEW_DESC {
                ViewDimension: D3D11_VPOV_DIMENSION_TEXTURE2D,
                Anonymous: D3D11_VIDEO_PROCESSOR_OUTPUT_VIEW_DESC_0 { Texture2D: D3D11_TEX2D_VPOV { MipSlice: 0 } },
            };
            let mut view = None;
            unsafe { gpu.video.CreateVideoProcessorOutputView(&texture, &enumerator, &desc, Some(&mut view))? };
            outputs.push((texture, view.unwrap()));
        }
        Ok(Scaler { from, crop: (0, 0, from.0, from.1), to, format, enumerator, processor, outputs, turn: 0 })
    }

    /// `crop` of `source` (left, top, width, height in its pixels) scaled into the next output, which it returns.
    pub fn run(&mut self, gpu: &Gpu, source: &ID3D11Texture2D, crop: (u32, u32, u32, u32)) -> Result<ID3D11Texture2D> {
        if crop != self.crop {
            self.crop = crop;
            let (x, y, w, h) = crop;
            let rect = RECT { left: x as i32, top: y as i32, right: (x + w) as i32, bottom: (y + h) as i32 };
            unsafe { gpu.vcontext.VideoProcessorSetStreamSourceRect(&self.processor, 0, true, Some(&rect)) };
        }
        let desc = D3D11_VIDEO_PROCESSOR_INPUT_VIEW_DESC {
            FourCC: 0,
            ViewDimension: D3D11_VPIV_DIMENSION_TEXTURE2D,
            Anonymous: D3D11_VIDEO_PROCESSOR_INPUT_VIEW_DESC_0 { Texture2D: D3D11_TEX2D_VPIV { MipSlice: 0, ArraySlice: 0 } },
        };
        let mut input = None;
        unsafe { gpu.video.CreateVideoProcessorInputView(source, &self.enumerator, &desc, Some(&mut input))? };
        let (texture, view) = &self.outputs[self.turn];
        self.turn = (self.turn + 1) % self.outputs.len();
        let stream = D3D11_VIDEO_PROCESSOR_STREAM { Enable: true.into(), pInputSurface: std::mem::ManuallyDrop::new(input), ..Default::default() };
        let streams = [stream];
        let done = unsafe { gpu.vcontext.VideoProcessorBlt(&self.processor, view, 0, &streams) };
        let [stream] = streams;
        drop(std::mem::ManuallyDrop::into_inner(stream.pInputSurface));
        done?;
        Ok(texture.clone())
    }
}

/// `width`×`height` fitted into the bounds, never larger, in even pixels (what 4:2:0 encodes).
pub fn fitted(width: u32, height: u32, max_width: u32, max_height: u32) -> (u32, u32) {
    let scale = (max_width as f64 / width as f64).min(max_height as f64 / height as f64).min(1.0);
    let even = |v: f64| ((v.round() as u32) & !1).max(2);
    (even(width as f64 * scale), even(height as f64 * scale))
}
