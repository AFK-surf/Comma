//! The GPU side: one D3D11 device for the display's capture and the overlay's drawing. Windows Graphics Capture gives
//! the display in scRGB (FP16, 1.0 = 80 nits), without the cursor and without the overlay (which is left out of
//! captures); each frame is drawn into the screen texture as 8-bit sRGB with the display's SDR white as 1.0 (what an
//! SDR window shows there), with mips for the effect's blur. The effect (`effect.hlsl`) then draws the overlay from it.
//! The capture's frames arrive on a thread of their own; the device is multithread-protected and the screen texture
//! is behind a mutex.

use std::sync::{Arc, Mutex};

use windows::core::{s, Interface, Result, PCSTR};
use windows::Foundation::TypedEventHandler;
use windows::Graphics::Capture::{Direct3D11CaptureFramePool, GraphicsCaptureItem, GraphicsCaptureSession};
use windows::Graphics::DirectX::Direct3D11::IDirect3DDevice;
use windows::Graphics::DirectX::DirectXPixelFormat;
use windows::Graphics::SizeInt32;
use windows::Win32::Devices::Display::{
    DisplayConfigGetDeviceInfo, GetDisplayConfigBufferSizes, QueryDisplayConfig, DISPLAYCONFIG_DEVICE_INFO_GET_SDR_WHITE_LEVEL,
    DISPLAYCONFIG_DEVICE_INFO_GET_SOURCE_NAME, DISPLAYCONFIG_MODE_INFO, DISPLAYCONFIG_PATH_INFO, DISPLAYCONFIG_SDR_WHITE_LEVEL,
    DISPLAYCONFIG_SOURCE_DEVICE_NAME, QDC_ONLY_ACTIVE_PATHS,
};
use windows::Win32::Foundation::{HMODULE, POINT};
use windows::Win32::Graphics::Direct3D::Fxc::D3DCompile;
use windows::Win32::Graphics::Direct3D::{ID3DBlob, D3D11_PRIMITIVE_TOPOLOGY_TRIANGLELIST, D3D_DRIVER_TYPE_UNKNOWN};
use windows::Win32::Graphics::Direct3D11::*;
use windows::Win32::Graphics::Dxgi::Common::{DXGI_FORMAT_B8G8R8A8_UNORM, DXGI_SAMPLE_DESC};
use windows::Win32::Graphics::Dxgi::{CreateDXGIFactory1, IDXGIAdapter, IDXGIAdapter1, IDXGIDevice, IDXGIFactory1};
use windows::Win32::Graphics::Gdi::{GetMonitorInfoW, MonitorFromPoint, HMONITOR, MONITORINFOEXW, MONITOR_DEFAULTTOPRIMARY};
use windows::Win32::System::WinRT::Direct3D11::{CreateDirect3D11DeviceFromDXGIDevice, IDirect3DDxgiInterfaceAccess};
use windows::Win32::System::WinRT::Graphics::Capture::IGraphicsCaptureItemInterop;

use crate::effect::Values;

const CAPTURE_FORMAT: DirectXPixelFormat = DirectXPixelFormat::R16G16B16A16Float;

/// scRGB → sRGB with the SDR white as 1.0, pixel for pixel.
const CONVERT: &str = r#"
Texture2D<float4> screen : register(t0);
cbuffer White : register(b0) { float white; float3 pad; };
float4 vs(uint id : SV_VertexID) : SV_Position {
    float2 p = float2((id << 1) & 2, id & 2);
    return float4(p * float2(2, -2) + float2(-1, 1), 0, 1);
}
float encode(float v) { return v <= 0.0031308 ? 12.92 * v : 1.055 * pow(v, 1.0 / 2.4) - 0.055; }
float4 ps(float4 position : SV_Position) : SV_Target {
    float3 c = saturate(screen.Load(int3(position.xy, 0)).rgb / white);
    return float4(encode(c.r), encode(c.g), encode(c.b), 1);
}
"#;

const EFFECT: &str = include_str!("effect.hlsl");

/// The display's latest frame, drawn for the effect.
pub struct Screen {
    texture: Option<(ID3D11Texture2D, ID3D11RenderTargetView, ID3D11ShaderResourceView)>,
    size: SizeInt32,
    /// Frames drawn since the capture started; 0: none yet.
    pub frames: u64,
    white: f32,
}

// The screen is only touched under its mutex; the COM objects are free-threaded on a multithread-protected device.
unsafe impl Send for Screen {}

pub struct Gpu {
    pub device: ID3D11Device,
    pub context: ID3D11DeviceContext,
    winrt_device: IDirect3DDevice,
    convert: (ID3D11VertexShader, ID3D11PixelShader, ID3D11Buffer),
    effect: (ID3D11VertexShader, ID3D11PixelShader, ID3D11Buffer, ID3D11SamplerState),
    pub screen: Arc<Mutex<Screen>>,
}

// The device is multithread-protected; the capture's thread only draws under the screen's mutex.
unsafe impl Send for Gpu {}
unsafe impl Sync for Gpu {}

/// The adapter that drives `monitor`, so the frames stay on the GPU the display uses.
fn adapter_for(monitor: HMONITOR) -> Result<Option<IDXGIAdapter1>> {
    let factory: IDXGIFactory1 = unsafe { CreateDXGIFactory1()? };
    let mut index = 0;
    while let Ok(adapter) = unsafe { factory.EnumAdapters1(index) } {
        let mut output = 0;
        while let Ok(o) = unsafe { adapter.EnumOutputs(output) } {
            if unsafe { o.GetDesc()? }.Monitor == monitor {
                return Ok(Some(adapter));
            }
            output += 1;
        }
        index += 1;
    }
    Ok(None)
}

/// The display's SDR white in scRGB units (80 nits each): Windows' "SDR content brightness" when HDR is on, 1.0 when
/// it is off.
fn sdr_white(monitor: HMONITOR) -> f32 {
    unsafe {
        let mut info = MONITORINFOEXW::default();
        info.monitorInfo.cbSize = std::mem::size_of::<MONITORINFOEXW>() as u32;
        if !GetMonitorInfoW(monitor, &mut info.monitorInfo).as_bool() {
            return 1.0;
        }
        let (mut paths, mut modes) = (0, 0);
        if GetDisplayConfigBufferSizes(QDC_ONLY_ACTIVE_PATHS, &mut paths, &mut modes).is_err() {
            return 1.0;
        }
        let mut path_info = vec![DISPLAYCONFIG_PATH_INFO::default(); paths as usize];
        let mut mode_info = vec![DISPLAYCONFIG_MODE_INFO::default(); modes as usize];
        if QueryDisplayConfig(QDC_ONLY_ACTIVE_PATHS, &mut paths, path_info.as_mut_ptr(), &mut modes, mode_info.as_mut_ptr(), None)
            .is_err()
        {
            return 1.0;
        }
        for path in &path_info[..paths as usize] {
            let mut source = DISPLAYCONFIG_SOURCE_DEVICE_NAME::default();
            source.header.r#type = DISPLAYCONFIG_DEVICE_INFO_GET_SOURCE_NAME;
            source.header.size = std::mem::size_of::<DISPLAYCONFIG_SOURCE_DEVICE_NAME>() as u32;
            source.header.adapterId = path.sourceInfo.adapterId;
            source.header.id = path.sourceInfo.id;
            if DisplayConfigGetDeviceInfo(&mut source.header) != 0 || source.viewGdiDeviceName != info.szDevice {
                continue;
            }
            let mut white = DISPLAYCONFIG_SDR_WHITE_LEVEL::default();
            white.header.r#type = DISPLAYCONFIG_DEVICE_INFO_GET_SDR_WHITE_LEVEL;
            white.header.size = std::mem::size_of::<DISPLAYCONFIG_SDR_WHITE_LEVEL>() as u32;
            white.header.adapterId = path.targetInfo.adapterId;
            white.header.id = path.targetInfo.id;
            if DisplayConfigGetDeviceInfo(&mut white.header) == 0 && white.SDRWhiteLevel > 0 {
                return white.SDRWhiteLevel as f32 / 1000.0;
            }
        }
        1.0
    }
}

fn compile(source: &str, entry: PCSTR, target: PCSTR) -> Result<ID3DBlob> {
    let mut code = None;
    let mut errors = None;
    let result = unsafe {
        D3DCompile(source.as_ptr() as *const _, source.len(), None, None, None, entry, target, 0, 0, &mut code, Some(&mut errors))
    };
    if let Err(error) = result {
        if let Some(errors) = errors {
            eprintln!("{}", String::from_utf8_lossy(bytes(&errors)));
        }
        return Err(error);
    }
    Ok(code.expect("D3DCompile gave no code"))
}

fn bytes(blob: &ID3DBlob) -> &[u8] {
    unsafe { std::slice::from_raw_parts(blob.GetBufferPointer() as *const u8, blob.GetBufferSize()) }
}

fn shaders(device: &ID3D11Device, source: &str) -> Result<(ID3D11VertexShader, ID3D11PixelShader)> {
    let (vs, ps) = (compile(source, s!("vs"), s!("vs_5_0"))?, compile(source, s!("ps"), s!("ps_5_0"))?);
    let (mut vertex, mut pixel) = (None, None);
    unsafe {
        device.CreateVertexShader(bytes(&vs), None, Some(&mut vertex))?;
        device.CreatePixelShader(bytes(&ps), None, Some(&mut pixel))?;
    }
    Ok((vertex.expect("no vertex shader"), pixel.expect("no pixel shader")))
}

fn constants(device: &ID3D11Device, size: u32) -> Result<ID3D11Buffer> {
    let mut buffer = None;
    unsafe {
        device.CreateBuffer(
            &D3D11_BUFFER_DESC {
                ByteWidth: size,
                Usage: D3D11_USAGE_DEFAULT,
                BindFlags: D3D11_BIND_CONSTANT_BUFFER.0 as u32,
                ..Default::default()
            },
            None,
            Some(&mut buffer),
        )?
    };
    Ok(buffer.expect("no buffer"))
}

fn viewport(width: f32, height: f32) -> D3D11_VIEWPORT {
    D3D11_VIEWPORT { TopLeftX: 0.0, TopLeftY: 0.0, Width: width, Height: height, MinDepth: 0.0, MaxDepth: 1.0 }
}

impl Gpu {
    pub fn new() -> Result<Self> {
        // The primary display's GPU; Windows copies a capture of a display on another GPU across.
        let primary = unsafe { MonitorFromPoint(POINT { x: 0, y: 0 }, MONITOR_DEFAULTTOPRIMARY) };
        let adapter = adapter_for(primary)?.map(|a| a.cast::<IDXGIAdapter>()).transpose()?;
        let (mut device, mut context) = (None, None);
        unsafe {
            D3D11CreateDevice(
                adapter.as_ref(),
                D3D_DRIVER_TYPE_UNKNOWN,
                HMODULE::default(),
                D3D11_CREATE_DEVICE_BGRA_SUPPORT,
                None,
                D3D11_SDK_VERSION,
                Some(&mut device),
                None,
                Some(&mut context),
            )?
        };
        let device: ID3D11Device = device.expect("no device");
        let context = context.expect("no context");
        let multithread: ID3D11Multithread = context.cast()?;
        unsafe {
            let _ = multithread.SetMultithreadProtected(true);
        }
        let dxgi_device: IDXGIDevice = device.cast()?;
        let winrt_device: IDirect3DDevice = unsafe { CreateDirect3D11DeviceFromDXGIDevice(&dxgi_device)? }.cast()?;
        let convert = shaders(&device, CONVERT)?;
        let effect = shaders(&device, EFFECT)?;
        let mut sampler = None;
        unsafe {
            device.CreateSamplerState(
                &D3D11_SAMPLER_DESC {
                    Filter: D3D11_FILTER_MIN_MAG_MIP_LINEAR,
                    AddressU: D3D11_TEXTURE_ADDRESS_CLAMP,
                    AddressV: D3D11_TEXTURE_ADDRESS_CLAMP,
                    AddressW: D3D11_TEXTURE_ADDRESS_CLAMP,
                    MaxLOD: f32::MAX,
                    ..Default::default()
                },
                Some(&mut sampler),
            )?
        };
        Ok(Self {
            convert: (convert.0, convert.1, constants(&device, 16)?),
            effect: (effect.0, effect.1, constants(&device, std::mem::size_of::<Values>() as u32)?, sampler.expect("no sampler")),
            device,
            context,
            winrt_device,
            screen: Arc::new(Mutex::new(Screen { texture: None, size: SizeInt32::default(), frames: 0, white: 1.0 })),
        })
    }

    /// The screen texture's mip count less one, for the effect's blur.
    pub fn max_lod(&self) -> f32 {
        let screen = self.screen.lock().unwrap();
        (screen.size.Width.max(screen.size.Height).max(1) as f32).log2().floor()
    }

    /// Draws the effect at `values` into `target` (the overlay's back buffer).
    pub fn draw(&self, target: &ID3D11RenderTargetView, values: &Values) {
        let screen = self.screen.lock().unwrap();
        let view = screen.texture.as_ref().map(|t| t.2.clone());
        let (vertex, pixel, buffer, sampler) = &self.effect;
        let context = &self.context;
        unsafe {
            context.UpdateSubresource(buffer, 0, None, values as *const Values as *const _, 0, 0);
            context.OMSetRenderTargets(Some(&[Some(target.clone())]), None);
            context.RSSetViewports(Some(&[viewport(values.size[0], values.size[1])]));
            context.IASetPrimitiveTopology(D3D11_PRIMITIVE_TOPOLOGY_TRIANGLELIST);
            context.VSSetShader(vertex, None);
            context.PSSetShader(pixel, None);
            context.PSSetShaderResources(0, Some(&[view]));
            context.PSSetSamplers(0, Some(&[Some(sampler.clone())]));
            context.PSSetConstantBuffers(0, Some(&[Some(buffer.clone())]));
            context.Draw(3, 0);
            context.PSSetShaderResources(0, Some(&[None]));
        }
    }

    /// Saves the swap chain's back buffer as a 32-bit BMP (tests).
    pub fn save_frame(&self, swap_chain: &windows::Win32::Graphics::Dxgi::IDXGISwapChain1, path: &str) -> Result<()> {
        unsafe {
            let buffer: ID3D11Texture2D = swap_chain.GetBuffer(0)?;
            let mut desc = D3D11_TEXTURE2D_DESC::default();
            buffer.GetDesc(&mut desc);
            desc.Usage = D3D11_USAGE_STAGING;
            desc.BindFlags = 0;
            desc.CPUAccessFlags = D3D11_CPU_ACCESS_READ.0 as u32;
            desc.MiscFlags = 0;
            let mut staging = None;
            self.device.CreateTexture2D(&desc, None, Some(&mut staging))?;
            let staging = staging.expect("no staging texture");
            self.context.CopyResource(&staging, &buffer);
            let mut mapped = D3D11_MAPPED_SUBRESOURCE::default();
            self.context.Map(&staging, 0, D3D11_MAP_READ, 0, Some(&mut mapped))?;
            let (width, height) = (desc.Width as usize, desc.Height as usize);
            let mut pixels = Vec::with_capacity(width * height * 4);
            for row in 0..height {
                let start = (mapped.pData as *const u8).add(row * mapped.RowPitch as usize);
                pixels.extend_from_slice(std::slice::from_raw_parts(start, width * 4));
            }
            self.context.Unmap(&staging, 0);
            let mut file = Vec::with_capacity(54 + pixels.len());
            let size = (54 + pixels.len()) as u32;
            file.extend_from_slice(b"BM");
            file.extend_from_slice(&size.to_le_bytes());
            file.extend_from_slice(&[0, 0, 0, 0]);
            file.extend_from_slice(&54u32.to_le_bytes());
            file.extend_from_slice(&40u32.to_le_bytes());
            file.extend_from_slice(&(width as i32).to_le_bytes());
            // Negative: top-down rows.
            file.extend_from_slice(&(-(height as i32)).to_le_bytes());
            file.extend_from_slice(&1u16.to_le_bytes());
            file.extend_from_slice(&32u16.to_le_bytes());
            file.extend_from_slice(&[0; 24]);
            file.extend_from_slice(&pixels);
            std::fs::write(path, file).map_err(|_| windows::core::Error::from_win32())?;
        }
        Ok(())
    }

    /// Draws a captured frame into the screen texture, made anew at another size.
    fn take(&self, screen: &mut Screen, source: &ID3D11Texture2D, size: SizeInt32) -> Result<()> {
        if screen.texture.is_none() || screen.size != size {
            let desc = D3D11_TEXTURE2D_DESC {
                Width: size.Width as u32,
                Height: size.Height as u32,
                MipLevels: 0,
                ArraySize: 1,
                Format: DXGI_FORMAT_B8G8R8A8_UNORM,
                SampleDesc: DXGI_SAMPLE_DESC { Count: 1, Quality: 0 },
                Usage: D3D11_USAGE_DEFAULT,
                BindFlags: (D3D11_BIND_SHADER_RESOURCE.0 | D3D11_BIND_RENDER_TARGET.0) as u32,
                CPUAccessFlags: 0,
                MiscFlags: D3D11_RESOURCE_MISC_GENERATE_MIPS.0 as u32,
            };
            let mut texture = None;
            unsafe { self.device.CreateTexture2D(&desc, None, Some(&mut texture))? };
            let texture = texture.expect("no texture");
            let (mut target, mut view) = (None, None);
            unsafe {
                self.device.CreateRenderTargetView(
                    &texture,
                    Some(&D3D11_RENDER_TARGET_VIEW_DESC {
                        Format: DXGI_FORMAT_B8G8R8A8_UNORM,
                        ViewDimension: D3D11_RTV_DIMENSION_TEXTURE2D,
                        Anonymous: D3D11_RENDER_TARGET_VIEW_DESC_0 { Texture2D: D3D11_TEX2D_RTV { MipSlice: 0 } },
                    }),
                    Some(&mut target),
                )?;
                self.device.CreateShaderResourceView(&texture, None, Some(&mut view))?;
            }
            screen.texture = Some((texture, target.expect("no target"), view.expect("no view")));
            screen.size = size;
        }
        let (_, target, view) = screen.texture.as_ref().expect("screen texture");
        let mut source_view = None;
        unsafe { self.device.CreateShaderResourceView(source, None, Some(&mut source_view))? };
        let (vertex, pixel, buffer) = &self.convert;
        let white = [screen.white, 0.0, 0.0, 0.0];
        let context = &self.context;
        unsafe {
            context.UpdateSubresource(buffer, 0, None, white.as_ptr() as *const _, 0, 0);
            context.OMSetRenderTargets(Some(&[Some(target.clone())]), None);
            context.RSSetViewports(Some(&[viewport(size.Width as f32, size.Height as f32)]));
            context.IASetPrimitiveTopology(D3D11_PRIMITIVE_TOPOLOGY_TRIANGLELIST);
            context.VSSetShader(vertex, None);
            context.PSSetShader(pixel, None);
            context.PSSetShaderResources(0, Some(&[source_view]));
            context.PSSetConstantBuffers(0, Some(&[Some(buffer.clone())]));
            context.Draw(3, 0);
            context.PSSetShaderResources(0, Some(&[None]));
            context.OMSetRenderTargets(None, None);
            context.GenerateMips(view);
        }
        screen.frames += 1;
        Ok(())
    }
}

/// A display being captured into the screen texture.
pub struct Capture {
    pool: Direct3D11CaptureFramePool,
    session: GraphicsCaptureSession,
}

impl Capture {
    /// Captures `monitor` until stopped; its first frame counts the screen's frames from 1.
    pub fn start(gpu: &Arc<Gpu>, monitor: HMONITOR) -> Result<Self> {
        let interop = windows::core::factory::<GraphicsCaptureItem, IGraphicsCaptureItemInterop>()?;
        let item: GraphicsCaptureItem = unsafe { interop.CreateForMonitor(monitor)? };
        let size = item.Size()?;
        {
            let mut screen = gpu.screen.lock().unwrap();
            screen.white = sdr_white(monitor);
            screen.frames = 0;
        }
        let pool = Direct3D11CaptureFramePool::CreateFreeThreaded(&gpu.winrt_device, CAPTURE_FORMAT, 2, size)?;
        let session = pool.CreateCaptureSession(&item)?;
        session.SetIsCursorCaptureEnabled(false)?;
        // The overlay draws at most 60 frames a second: the capture need not run faster (Windows 11 24H2).
        let _ = session.SetMinUpdateInterval(windows::Foundation::TimeSpan { Duration: 166_666 });
        // Windows 11: no yellow border around the display while it is captured.
        let _ = session.SetIsBorderRequired(false);
        let frames = gpu.clone();
        let pool_size = Arc::new(Mutex::new(size));
        pool.FrameArrived(&TypedEventHandler::new(move |pool: windows::core::Ref<Direct3D11CaptureFramePool>, _| {
            let pool = pool.as_ref().expect("frame pool");
            let frame = pool.TryGetNextFrame()?;
            let content = frame.ContentSize()?;
            let mut current = pool_size.lock().unwrap();
            if content != *current {
                // The display changed size: the pool follows.
                pool.Recreate(&frames.winrt_device, CAPTURE_FORMAT, 2, content)?;
                *current = content;
                return Ok(());
            }
            let access: IDirect3DDxgiInterfaceAccess = frame.Surface()?.cast()?;
            let texture: ID3D11Texture2D = unsafe { access.GetInterface()? };
            let mut screen = frames.screen.lock().unwrap();
            frames.take(&mut screen, &texture, content)
        }))?;
        session.StartCapture()?;
        Ok(Self { pool, session })
    }

    pub fn stop(self) {
        let _ = self.session.Close();
        let _ = self.pool.Close();
    }
}
