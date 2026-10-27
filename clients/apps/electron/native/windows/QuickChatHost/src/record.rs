//! Tests: `QUICK_CHAT_TEST_RECORD` names a folder where every frame shown is recorded, as screen recordings cannot
//! (the overlay is left out of screen captures): the bottom middle of the overlay, `CROP` DIPs, at half its pixels,
//! appended to `frames.raw` (BGRA) with its time in `frames.txt`. A thread of its own writes them.

use std::io::Write;
use std::sync::mpsc::{channel, Sender};

use windows::core::Result;
use windows::Win32::Graphics::Direct3D11::*;
use windows::Win32::Graphics::Dxgi::Common::{DXGI_FORMAT_B8G8R8A8_UNORM, DXGI_SAMPLE_DESC};
use windows::Win32::Graphics::Dxgi::IDXGISwapChain1;

use crate::gpu::Gpu;

/// The part recorded, DIPs: the words, the buttons and the glow above the taskbar.
const CROP: (f64, f64) = (1440.0, 880.0);

pub struct Recorder {
    crop: ID3D11Texture2D,
    view: ID3D11ShaderResourceView,
    /// Read back two frames late, so that the GPU never waits for it.
    staging: Vec<ID3D11Texture2D>,
    waiting: std::cell::RefCell<std::collections::VecDeque<(usize, f64)>>,
    next: std::cell::Cell<usize>,
    region: D3D11_BOX,
    size: (u32, u32),
    frames: Sender<(f64, Vec<u8>)>,
}

impl Recorder {
    /// For an overlay `width` × `height` px at `scale`.
    pub fn new(gpu: &Gpu, dir: &str, width: u32, height: u32, scale: f64) -> Result<Self> {
        // Even, for the half-size mip.
        let w = ((CROP.0 * scale) as u32).min(width) & !1;
        let h = ((CROP.1 * scale) as u32).min(height) & !1;
        let left = (width - w) / 2;
        let top = height - h;
        unsafe {
            let mut crop = None;
            gpu.device.CreateTexture2D(
                &D3D11_TEXTURE2D_DESC {
                    Width: w,
                    Height: h,
                    MipLevels: 2,
                    ArraySize: 1,
                    Format: DXGI_FORMAT_B8G8R8A8_UNORM,
                    SampleDesc: DXGI_SAMPLE_DESC { Count: 1, Quality: 0 },
                    Usage: D3D11_USAGE_DEFAULT,
                    BindFlags: (D3D11_BIND_RENDER_TARGET.0 | D3D11_BIND_SHADER_RESOURCE.0) as u32,
                    CPUAccessFlags: 0,
                    MiscFlags: D3D11_RESOURCE_MISC_GENERATE_MIPS.0 as u32,
                },
                None,
                Some(&mut crop),
            )?;
            let crop = crop.unwrap();
            let mut view = None;
            gpu.device.CreateShaderResourceView(&crop, None, Some(&mut view))?;
            let mut stagings = Vec::new();
            for _ in 0..3 {
            let mut staging = None;
            gpu.device.CreateTexture2D(
                &D3D11_TEXTURE2D_DESC {
                    Width: w / 2,
                    Height: h / 2,
                    MipLevels: 1,
                    ArraySize: 1,
                    Format: DXGI_FORMAT_B8G8R8A8_UNORM,
                    SampleDesc: DXGI_SAMPLE_DESC { Count: 1, Quality: 0 },
                    Usage: D3D11_USAGE_STAGING,
                    BindFlags: 0,
                    CPUAccessFlags: D3D11_CPU_ACCESS_READ.0 as u32,
                    MiscFlags: 0,
                },
                None,
                Some(&mut staging),
            )?;
            stagings.push(staging.unwrap());
            }
            let (frames, receive) = channel::<(f64, Vec<u8>)>();
            let dir = dir.to_string();
            let size = (w / 2, h / 2);
            std::fs::create_dir_all(&dir).ok();
            std::fs::write(format!("{dir}\\size.txt"), format!("{} {}", size.0, size.1)).ok();
            std::thread::spawn(move || {
                let mut raw = std::fs::OpenOptions::new().create(true).append(true).open(format!("{dir}\\frames.raw"));
                let mut times =
                    std::fs::OpenOptions::new().create(true).append(true).open(format!("{dir}\\frames.txt"));
                for (t, pixels) in receive {
                    if let (Ok(raw), Ok(times)) = (raw.as_mut(), times.as_mut()) {
                        let _ = raw.write_all(&pixels);
                        let _ = writeln!(times, "{t:.6}");
                    }
                }
            });
            Ok(Self {
                crop,
                view: view.unwrap(),
                staging: stagings,
                waiting: Default::default(),
                next: Default::default(),
                region: D3D11_BOX { left, top, front: 0, right: left + w, bottom: top + h, back: 1 },
                size,
                frames,
            })
        }
    }

    /// The frame about to be presented, at `t`.
    pub fn record(&self, gpu: &Gpu, swap_chain: &IDXGISwapChain1, t: f64) -> Result<()> {
        unsafe {
            let buffer: ID3D11Texture2D = swap_chain.GetBuffer(0)?;
            gpu.context.CopySubresourceRegion(&self.crop, 0, 0, 0, 0, &buffer, 0, Some(&self.region));
            gpu.context.GenerateMips(&self.view);
            let slot = self.next.get();
            self.next.set((slot + 1) % self.staging.len());
            gpu.context.CopySubresourceRegion(&self.staging[slot], 0, 0, 0, 0, &self.crop, 1, None);
            let mut waiting = self.waiting.borrow_mut();
            waiting.push_back((slot, t));
            if waiting.len() < self.staging.len() {
                return Ok(());
            }
            let (slot, t) = waiting.pop_front().unwrap();
            let staging = &self.staging[slot];
            let mut mapped = D3D11_MAPPED_SUBRESOURCE::default();
            gpu.context.Map(staging, 0, D3D11_MAP_READ, 0, Some(&mut mapped))?;
            let (width, height) = (self.size.0 as usize, self.size.1 as usize);
            let mut pixels = Vec::with_capacity(width * height * 4);
            for row in 0..height {
                let start = (mapped.pData as *const u8).add(row * mapped.RowPitch as usize);
                pixels.extend_from_slice(std::slice::from_raw_parts(start, width * 4));
            }
            gpu.context.Unmap(staging, 0);
            let _ = self.frames.send((t, pixels));
        }
        Ok(())
    }
}
