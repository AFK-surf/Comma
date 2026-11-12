// An HDR display's pictures made SDR, as ScreenCam's Windows recording does (screen-cam-win #39, its white level from
// 8fed714f). With HDR on, the compositor works in scRGB (linear, 1.0 = 80 nits) and puts SDR white at the display's
// "SDR content brightness" (2.5 at 200 nits, 4.5 at 360); a capture taken as 8-bit BGRA clips each channel at 1.0,
// so everything brighter than 80 nits came out white (the picture washed out). The capture is taken as FP16 instead
// and drawn into the view's BGRA picture by a pixel shader: divided by the SDR white, a colour still over 1.0 (an HDR
// highlight) scaled down whole (its hue kept, not clipped towards white), then sRGB-encoded.
//
// The white level: DisplayConfigGetDeviceInfo's (DISPLAYCONFIG_SDR_WHITE_LEVEL, 1000 = 80 nits), except that it can
// say the 1000 default while the compositor uses the level the user set (seen at 360 nits): then the one Windows
// keeps for the monitor, under MonitorDataStore by a name made from its EDID.

/// DISPLAYCONFIG_SDR_WHITE_LEVEL's default, 80 nits: also what it says when it does not know.
pub const DEFAULT_WHITE: u32 = 1000;

/// The white level to use: the one reported unless it is the default and Windows keeps another.
pub fn resolve(reported: Option<u32>, persisted: Option<u32>) -> Option<u32> {
    match reported {
        Some(level) if level > 0 && level != DEFAULT_WHITE => Some(level),
        _ => persisted.filter(|l| *l > 0).or(reported),
    }
}

/// A white level in nits.
pub fn nits(level: u32) -> f32 {
    level as f32 / 1000.0 * 80.0
}

/// The device instance of a monitor's device path: `\\?\DISPLAY#MSI3DD2#5&…&UID4357#{guid}` is
/// `DISPLAY\MSI3DD2\5&…&UID4357`.
pub fn instance_path(device_path: &str) -> Option<String> {
    let path = device_path.trim_end_matches('\0');
    let path = path.strip_prefix(r"\\?\").unwrap_or(path);
    let parts: Vec<&str> = path.split('#').take(3).collect();
    (parts.len() == 3 && parts.iter().all(|p| !p.is_empty())).then(|| parts.join(r"\"))
}

/// `DISPLAY\MSI3DD2` from DISPLAYCONFIG_TARGET_DEVICE_NAME's EDID ids (the manufacturer's bytes swapped).
pub fn hardware_key(manufacturer: u16, product: u16) -> Option<String> {
    let m = manufacturer.swap_bytes();
    let letters = [(m >> 10) & 0x1F, (m >> 5) & 0x1F, m & 0x1F];
    letters.iter().all(|l| (1..=26).contains(l)).then(|| {
        let name: String = letters.iter().map(|l| (b'A' - 1 + *l as u8) as char).collect();
        format!(r"DISPLAY\{name}{product:04X}")
    })
}

/// The monitor's device instance: the device path's where Windows gives one, else (a DisplayPort target can have an
/// empty path) the one instance of the hardware whose name ends in `UID{target}`.
pub fn select_instance(device_path: &str, hardware: Option<&str>, names: &[String], target: u32) -> Option<String> {
    if let Some(path) = instance_path(device_path) {
        return Some(path);
    }
    let hardware = hardware?;
    let suffix = format!("UID{target}");
    let found: Vec<&String> = names
        .iter()
        .filter(|n| n.len() >= suffix.len() && n[n.len() - suffix.len()..].eq_ignore_ascii_case(&suffix))
        .filter(|n| n.len() == suffix.len() || n.as_bytes()[n.len() - suffix.len() - 1] == b'&')
        .collect();
    (found.len() == 1).then(|| format!(r"{hardware}\{}", found[0]))
}

/// The MonitorDataStore key Windows names from an EDID: PnP id and product code, the descriptor's serial (or the
/// numeric one), week, year and checksum, e.g. `MSI3DD216843009_04_07E8_DC`.
pub fn store_name(edid: &[u8]) -> Option<String> {
    if edid.len() < 128 || edid[0] != 0 || edid[1] != 0xFF || edid[7] != 0 {
        return None;
    }
    let m = (edid[8] as u16) << 8 | edid[9] as u16;
    let pnp: String = [(m >> 10) & 0x1F, (m >> 5) & 0x1F, m & 0x1F].iter().map(|l| (b'A' - 1 + *l as u8) as char).collect();
    let product = u16::from_le_bytes([edid[10], edid[11]]);
    let serial = [54, 72, 90, 108]
        .iter()
        .filter(|&&at| edid[at] == 0 && edid[at + 1] == 0 && edid[at + 3] == 0xFF)
        .find_map(|&at| {
            let text = String::from_utf8_lossy(&edid[at + 5..at + 18]);
            let text = text.split('\n').next().unwrap_or("").trim().to_string();
            (!text.is_empty()).then_some(text)
        })
        .unwrap_or_else(|| u32::from_le_bytes([edid[12], edid[13], edid[14], edid[15]]).to_string());
    Some(format!("{pnp}{product:04X}{serial}_{:02X}_{:04X}_{:02X}", edid[16], edid[17] as u32 + 1990, edid[127]))
}

#[cfg(windows)]
pub use self::windows_only::*;

#[cfg(windows)]
mod windows_only {
    use windows::Win32::Devices::Display::{
        DISPLAYCONFIG_DEVICE_INFO_GET_ADVANCED_COLOR_INFO, DISPLAYCONFIG_DEVICE_INFO_GET_SDR_WHITE_LEVEL, DISPLAYCONFIG_DEVICE_INFO_GET_TARGET_NAME,
        DISPLAYCONFIG_GET_ADVANCED_COLOR_INFO, DISPLAYCONFIG_SDR_WHITE_LEVEL, DISPLAYCONFIG_TARGET_DEVICE_NAME, DisplayConfigGetDeviceInfo,
    };
    use windows::Win32::Foundation::{ERROR_SUCCESS, LUID};
    use windows::Win32::Graphics::Direct3D::Fxc::D3DCompile;
    use windows::Win32::Graphics::Direct3D::ID3DBlob;
    use windows::Win32::Graphics::Direct3D11::*;
    use windows::Win32::Graphics::Dxgi::Common::DXGI_FORMAT_R16G16B16A16_FLOAT;
    use windows::Win32::Graphics::Gdi::HMONITOR;
    use windows::Win32::System::Registry::{
        HKEY, HKEY_LOCAL_MACHINE, KEY_READ, RRF_RT_REG_BINARY, RRF_RT_REG_DWORD, RegCloseKey, RegEnumKeyExW, RegGetValueW, RegOpenKeyExW,
    };
    use windows::core::{HSTRING, PWSTR, Result, s};

    use super::{DEFAULT_WHITE, hardware_key, nits, resolve, select_instance, store_name};

    /// The display's SDR white in nits when HDR is on for it; none when it is off (or Windows does not say).
    pub fn sdr_white(monitor: HMONITOR) -> Option<f32> {
        let path = super::super::scale::path(monitor)?;
        let (adapter, target) = (path.targetInfo.adapterId, path.targetInfo.id);
        let mut color = DISPLAYCONFIG_GET_ADVANCED_COLOR_INFO::default();
        color.header.r#type = DISPLAYCONFIG_DEVICE_INFO_GET_ADVANCED_COLOR_INFO;
        color.header.size = std::mem::size_of::<DISPLAYCONFIG_GET_ADVANCED_COLOR_INFO>() as u32;
        color.header.adapterId = adapter;
        color.header.id = target;
        // advancedColorEnabled: the second bit.
        if unsafe { DisplayConfigGetDeviceInfo(&mut color.header) } != 0 || unsafe { color.Anonymous.value } & 2 == 0 {
            return None;
        }
        let mut white = DISPLAYCONFIG_SDR_WHITE_LEVEL::default();
        white.header.r#type = DISPLAYCONFIG_DEVICE_INFO_GET_SDR_WHITE_LEVEL;
        white.header.size = std::mem::size_of::<DISPLAYCONFIG_SDR_WHITE_LEVEL>() as u32;
        white.header.adapterId = adapter;
        white.header.id = target;
        let reported = (unsafe { DisplayConfigGetDeviceInfo(&mut white.header) } == 0 && white.SDRWhiteLevel != 0).then_some(white.SDRWhiteLevel);
        let persisted = if reported.is_none_or(|l| l == DEFAULT_WHITE) { persisted_white(adapter, target) } else { None };
        Some(nits(resolve(reported, persisted).unwrap_or(DEFAULT_WHITE)))
    }

    /// The SDR white level Windows keeps for the monitor (MonitorDataStore), found by its EDID.
    fn persisted_white(adapter: LUID, target: u32) -> Option<u32> {
        let mut name = DISPLAYCONFIG_TARGET_DEVICE_NAME::default();
        name.header.r#type = DISPLAYCONFIG_DEVICE_INFO_GET_TARGET_NAME;
        name.header.size = std::mem::size_of::<DISPLAYCONFIG_TARGET_DEVICE_NAME>() as u32;
        name.header.adapterId = adapter;
        name.header.id = target;
        if unsafe { DisplayConfigGetDeviceInfo(&mut name.header) } != 0 {
            return None;
        }
        let path = String::from_utf16_lossy(&name.monitorDevicePath);
        let hardware = hardware_key(name.edidManufactureId, name.edidProductCodeId);
        let names = match (&hardware, super::instance_path(&path)) {
            (Some(hardware), None) => subkeys(&format!(r"SYSTEM\CurrentControlSet\Enum\{hardware}")),
            _ => Vec::new(),
        };
        let instance = select_instance(&path, hardware.as_deref(), &names, target)?;
        let mut edid = vec![0u8; 1024];
        let mut size = edid.len() as u32;
        let key = HSTRING::from(format!(r"SYSTEM\CurrentControlSet\Enum\{instance}\Device Parameters"));
        if unsafe { RegGetValueW(HKEY_LOCAL_MACHINE, &key, &HSTRING::from("EDID"), RRF_RT_REG_BINARY, None, Some(edid.as_mut_ptr().cast()), Some(&mut size)) } != ERROR_SUCCESS {
            return None;
        }
        edid.truncate(size as usize);
        let store = HSTRING::from(format!(r"SYSTEM\CurrentControlSet\Control\GraphicsDrivers\MonitorDataStore\{}", store_name(&edid)?));
        let mut level = 0u32;
        let mut size = 4u32;
        let read = unsafe { RegGetValueW(HKEY_LOCAL_MACHINE, &store, &HSTRING::from("SDRWhiteLevel"), RRF_RT_REG_DWORD, None, Some((&mut level as *mut u32).cast()), Some(&mut size)) };
        (read == ERROR_SUCCESS && level > 0).then_some(level)
    }

    /// The names of a key's subkeys (under HKLM).
    fn subkeys(key: &str) -> Vec<String> {
        let mut names = Vec::new();
        let mut open = HKEY::default();
        if unsafe { RegOpenKeyExW(HKEY_LOCAL_MACHINE, &HSTRING::from(key), None, KEY_READ, &mut open) } != ERROR_SUCCESS {
            return names;
        }
        for index in 0.. {
            let mut name = [0u16; 256];
            let mut length = name.len() as u32;
            if unsafe { RegEnumKeyExW(open, index, Some(PWSTR(name.as_mut_ptr())), &mut length, None, None, None, None) } != ERROR_SUCCESS {
                break;
            }
            names.push(String::from_utf16_lossy(&name[..length as usize]));
        }
        unsafe {
            let _ = RegCloseKey(open);
        }
        names
    }

    const SHADER: &str = r"
Texture2D<float4> picture : register(t0);
cbuffer White : register(b0) { float white; float3 unused; };

float4 vs(uint id : SV_VertexID) : SV_POSITION {
    // One triangle over the whole target.
    float2 at = float2((id << 1) & 2, id & 2);
    return float4(at * float2(2, -2) + float2(-1, 1), 0, 1);
}

float encode(float v) {
    return v <= 0.0031308 ? v * 12.92 : 1.055 * pow(v, 1.0 / 2.4) - 0.055;
}

float4 ps(float4 at : SV_POSITION) : SV_TARGET {
    float3 c = max(picture.Load(int3(at.xy, 0)).rgb, 0) * (80.0 / max(white, 80.0));
    c /= max(1.0, max(c.r, max(c.g, c.b)));
    return float4(encode(c.r), encode(c.g), encode(c.b), 1);
}
";

    /// The pixel shader from an FP16 (scRGB) picture to an SDR one (sRGB, the BGRA texture it draws into).
    pub struct ToSdr {
        pub white: f32,
        vs: ID3D11VertexShader,
        ps: ID3D11PixelShader,
        constants: ID3D11Buffer,
        /// A copy of the capture's picture, when the capture's own cannot be read by a shader.
        copy: Option<ID3D11Texture2D>,
    }

    fn compile(entry: windows::core::PCSTR, target: windows::core::PCSTR) -> Result<ID3DBlob> {
        let mut code = None;
        unsafe { D3DCompile(SHADER.as_ptr().cast(), SHADER.len(), None, None, None, entry, target, 0, 0, &mut code, None)? };
        Ok(code.unwrap())
    }

    fn bytes(blob: &ID3DBlob) -> &[u8] {
        unsafe { std::slice::from_raw_parts(blob.GetBufferPointer() as *const u8, blob.GetBufferSize()) }
    }

    impl ToSdr {
        pub fn new(device: &ID3D11Device, white: f32) -> Result<ToSdr> {
            let (vs_code, ps_code) = (compile(s!("vs"), s!("vs_4_0"))?, compile(s!("ps"), s!("ps_4_0"))?);
            let (mut vs, mut ps, mut constants) = (None, None, None);
            let desc = D3D11_BUFFER_DESC { ByteWidth: 16, Usage: D3D11_USAGE_IMMUTABLE, BindFlags: D3D11_BIND_CONSTANT_BUFFER.0 as u32, ..Default::default() };
            let data = [white, 0.0, 0.0, 0.0];
            let initial = D3D11_SUBRESOURCE_DATA { pSysMem: data.as_ptr().cast(), ..Default::default() };
            unsafe {
                device.CreateVertexShader(bytes(&vs_code), None, Some(&mut vs))?;
                device.CreatePixelShader(bytes(&ps_code), None, Some(&mut ps))?;
                device.CreateBuffer(&desc, Some(&initial), Some(&mut constants))?;
            }
            Ok(ToSdr { white, vs: vs.unwrap(), ps: ps.unwrap(), constants: constants.unwrap(), copy: None })
        }

        /// `source`'s top left `width`×`height` (FP16) drawn into `target` (BGRA, that size).
        pub fn run(&mut self, device: &ID3D11Device, context: &ID3D11DeviceContext, source: &ID3D11Texture2D, target: &ID3D11Texture2D, width: u32, height: u32) -> Result<()> {
            let mut desc = D3D11_TEXTURE2D_DESC::default();
            unsafe { source.GetDesc(&mut desc) };
            let read = if desc.BindFlags & D3D11_BIND_SHADER_RESOURCE.0 as u32 != 0 {
                source.clone()
            } else {
                let fits = self.copy.as_ref().is_some_and(|c| {
                    let mut d = D3D11_TEXTURE2D_DESC::default();
                    unsafe { c.GetDesc(&mut d) };
                    d.Width == desc.Width && d.Height == desc.Height
                });
                if !fits {
                    let copy = D3D11_TEXTURE2D_DESC {
                        Format: DXGI_FORMAT_R16G16B16A16_FLOAT,
                        Usage: D3D11_USAGE_DEFAULT,
                        BindFlags: D3D11_BIND_SHADER_RESOURCE.0 as u32,
                        CPUAccessFlags: 0,
                        MiscFlags: 0,
                        MipLevels: 1,
                        ArraySize: 1,
                        ..desc
                    };
                    let mut texture = None;
                    unsafe { device.CreateTexture2D(&copy, None, Some(&mut texture))? };
                    self.copy = texture;
                }
                let copy = self.copy.clone().unwrap();
                unsafe { context.CopyResource(&copy, source) };
                copy
            };
            let view_desc = D3D11_SHADER_RESOURCE_VIEW_DESC {
                Format: DXGI_FORMAT_R16G16B16A16_FLOAT,
                ViewDimension: windows::Win32::Graphics::Direct3D::D3D11_SRV_DIMENSION_TEXTURE2D,
                Anonymous: D3D11_SHADER_RESOURCE_VIEW_DESC_0 { Texture2D: D3D11_TEX2D_SRV { MostDetailedMip: 0, MipLevels: 1 } },
            };
            let (mut view, mut out) = (None, None);
            unsafe {
                device.CreateShaderResourceView(&read, Some(&view_desc), Some(&mut view))?;
                device.CreateRenderTargetView(target, None, Some(&mut out))?;
                let viewport = D3D11_VIEWPORT { TopLeftX: 0.0, TopLeftY: 0.0, Width: width as f32, Height: height as f32, MinDepth: 0.0, MaxDepth: 1.0 };
                context.OMSetRenderTargets(Some(&[out]), None);
                context.RSSetViewports(Some(&[viewport]));
                context.IASetInputLayout(None);
                context.IASetPrimitiveTopology(windows::Win32::Graphics::Direct3D::D3D11_PRIMITIVE_TOPOLOGY_TRIANGLELIST);
                context.VSSetShader(&self.vs, None);
                context.PSSetShader(&self.ps, None);
                context.PSSetShaderResources(0, Some(&[view]));
                context.PSSetConstantBuffers(0, Some(&[Some(self.constants.clone())]));
                context.Draw(3, 0);
                // Nothing left bound: the capture's picture goes back to its pool.
                context.PSSetShaderResources(0, Some(&[None]));
                context.OMSetRenderTargets(None, None);
            }
            Ok(())
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_white_level_kept_when_windows_says_the_default() {
        assert_eq!(resolve(Some(1000), Some(4500)), Some(4500));
        assert_eq!(resolve(None, Some(4500)), Some(4500));
        assert_eq!(resolve(Some(2500), Some(4500)), Some(2500));
        assert_eq!(resolve(Some(1000), None), Some(1000));
        assert_eq!(resolve(None, None), None);
        assert_eq!(nits(4500), 360.0);
        assert_eq!(nits(1000), 80.0);
    }

    #[test]
    fn the_monitors_instance() {
        assert_eq!(
            instance_path(r"\\?\DISPLAY#MSI3DD2#5&20af29f7&1&UID4357#{e6f07b5f-ee97-4a90-b076-33f57bf4eaa7}").as_deref(),
            Some(r"DISPLAY\MSI3DD2\5&20af29f7&1&UID4357")
        );
        assert_eq!(instance_path(""), None);
        assert_eq!(hardware_key(0x6936, 0x3DD2).as_deref(), Some(r"DISPLAY\MSI3DD2"));
        // A DisplayPort target with no device path: the instance by UID{target}.
        let names = ["1&8713bca&0&UID0".to_string(), "5&20af29f7&1&UID4357".to_string()];
        assert_eq!(select_instance("", Some(r"DISPLAY\MSI3DD2"), &names, 4357).as_deref(), Some(r"DISPLAY\MSI3DD2\5&20af29f7&1&UID4357"));
        assert_eq!(select_instance("", Some(r"DISPLAY\MSI3DD2"), &["1&8713bca&0&UID14357".to_string()], 4357), None);
    }

    fn edid(m: [u8; 2], product: u16, serial: u32, week: u8, year: u8, checksum: u8, text: Option<&str>) -> Vec<u8> {
        let mut e = vec![0u8; 128];
        e[..8].copy_from_slice(&[0x00, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x00]);
        e[8..10].copy_from_slice(&m);
        e[10..12].copy_from_slice(&product.to_le_bytes());
        e[12..16].copy_from_slice(&serial.to_le_bytes());
        e[16] = week;
        e[17] = year;
        if let Some(text) = text {
            e[72 + 3] = 0xFF;
            let padded = format!("{text}\n{}", " ".repeat(13));
            e[77..90].copy_from_slice(&padded.as_bytes()[..13]);
        }
        e[127] = checksum;
        e
    }

    #[test]
    fn the_stores_name_from_the_edid() {
        assert_eq!(store_name(&edid([0x36, 0x69], 0x3DD2, 16843009, 4, 34, 0xDC, None)).as_deref(), Some("MSI3DD216843009_04_07E8_DC"));
        assert_eq!(store_name(&edid([0x10, 0xAC], 0xD0E6, 810179157, 36, 29, 0x2C, Some("7JQXBY2"))).as_deref(), Some("DELD0E67JQXBY2_24_07E3_2C"));
        assert_eq!(store_name(&[0u8; 64]), None);
    }

    /// The shader against the sum on the CPU (ScreenCam's), on WARP (Windows' software GPU: no display needed), at
    /// several white levels: within a byte. The frame's right column and bottom row are past the picture: left out.
    #[cfg(windows)]
    #[test]
    fn an_hdr_picture_made_sdr_on_the_gpu() {
        use windows::Win32::Foundation::HMODULE;
        use windows::Win32::Graphics::Direct3D::{D3D_DRIVER_TYPE_WARP, D3D_FEATURE_LEVEL_11_0};
        use windows::Win32::Graphics::Direct3D11::*;
        use windows::Win32::Graphics::Dxgi::Common::*;

        fn half(v: f32) -> u16 {
            let bits = v.to_bits();
            let sign = ((bits >> 16) & 0x8000) as u16;
            let exp = ((bits >> 23) & 0xFF) as i32 - 127 + 15;
            if v == 0.0 || exp <= 0 {
                return sign;
            }
            sign | ((exp as u16) << 10) | (((bits >> 13) & 0x3FF) as u16)
        }
        fn unhalf(h: u16) -> f32 {
            let exp = ((h >> 10) & 0x1F) as i32;
            let m = (h & 0x3FF) as f32;
            let v = if exp == 0 { m / 1024.0 * 2f32.powi(-14) } else { (1.0 + m / 1024.0) * 2f32.powi(exp - 15) };
            if h & 0x8000 != 0 { -v } else { v }
        }
        fn expected(rgb: [f32; 3], white: f32) -> [u8; 3] {
            let scale = white.max(80.0) / 80.0;
            let c = rgb.map(|v| v.max(0.0) / scale);
            let peak = c[0].max(c[1]).max(c[2]).max(1.0);
            c.map(|v| {
                let v = v / peak;
                let e = if v <= 0.0031308 { v * 12.92 } else { 1.055 * v.powf(1.0 / 2.4) - 0.055 };
                (e * 255.0).round() as u8
            })
        }

        let (mut device, mut context) = (None, None);
        unsafe {
            D3D11CreateDevice(None, D3D_DRIVER_TYPE_WARP, HMODULE::default(), D3D11_CREATE_DEVICE_BGRA_SUPPORT, Some(&[D3D_FEATURE_LEVEL_11_0]), D3D11_SDK_VERSION, Some(&mut device), None, Some(&mut context)).unwrap();
        }
        let (device, context): (ID3D11Device, ID3D11DeviceContext) = (device.unwrap(), context.unwrap());
        // SDR greys and primaries at 80 to 400 nits' white, HDR highlights past it, a negative (out of sRGB's gamut).
        let colors: [[f32; 3]; 8] = [[0.0, 0.0, 0.0], [0.2, 0.2, 0.2], [1.0, 1.0, 1.0], [2.5, 2.5, 2.5], [4.5, 4.5, 4.5], [4.5, 0.5, 0.2], [12.0, 6.0, 1.0], [-0.1, 1.2, 3.0]];
        let (width, height) = (colors.len() as u32, 2u32);
        // The frame one pixel wider and taller than the picture, as the capture's can be.
        let (fw, fh) = (width + 1, height + 1);
        let mut pixels = vec![0u16; (fw * fh * 4) as usize];
        for y in 0..fh {
            for x in 0..fw {
                let c = colors.get(x as usize).copied().unwrap_or([100.0, 0.0, 0.0]);
                let at = ((y * fw + x) * 4) as usize;
                pixels[at..at + 4].copy_from_slice(&[half(c[0]), half(c[1]), half(c[2]), half(1.0)]);
            }
        }
        let desc = D3D11_TEXTURE2D_DESC {
            Width: fw,
            Height: fh,
            MipLevels: 1,
            ArraySize: 1,
            Format: DXGI_FORMAT_R16G16B16A16_FLOAT,
            SampleDesc: DXGI_SAMPLE_DESC { Count: 1, Quality: 0 },
            Usage: D3D11_USAGE_DEFAULT,
            // As the capture's: no shader resource (the copy taken).
            BindFlags: 0,
            CPUAccessFlags: 0,
            MiscFlags: 0,
        };
        let data = D3D11_SUBRESOURCE_DATA { pSysMem: pixels.as_ptr().cast(), SysMemPitch: fw * 8, SysMemSlicePitch: 0 };
        let mut source = None;
        unsafe { device.CreateTexture2D(&desc, Some(&data), Some(&mut source)).unwrap() };
        let source = source.unwrap();
        let target_desc = D3D11_TEXTURE2D_DESC { Width: width, Height: height, Format: DXGI_FORMAT_B8G8R8A8_UNORM, BindFlags: D3D11_BIND_RENDER_TARGET.0 as u32, ..desc };
        let staging_desc = D3D11_TEXTURE2D_DESC { Usage: D3D11_USAGE_STAGING, BindFlags: 0, CPUAccessFlags: D3D11_CPU_ACCESS_READ.0 as u32, ..target_desc };
        let (mut target, mut staging) = (None, None);
        unsafe {
            device.CreateTexture2D(&target_desc, None, Some(&mut target)).unwrap();
            device.CreateTexture2D(&staging_desc, None, Some(&mut staging)).unwrap();
        }
        let (target, staging) = (target.unwrap(), staging.unwrap());
        for white in [0.0f32, 80.0, 160.0, 203.0, 360.0, 400.0] {
            let mut sdr = ToSdr::new(&device, white).unwrap();
            sdr.run(&device, &context, &source, &target, width, height).unwrap();
            let mut mapped = D3D11_MAPPED_SUBRESOURCE::default();
            unsafe {
                context.CopyResource(&staging, &target);
                context.Map(&staging, 0, D3D11_MAP_READ, 0, Some(&mut mapped)).unwrap();
            }
            for y in 0..height as usize {
                let row = unsafe { std::slice::from_raw_parts((mapped.pData as *const u8).add(y * mapped.RowPitch as usize), width as usize * 4) };
                for (x, c) in colors.iter().enumerate() {
                    // The colour as FP16 holds it.
                    let want = expected(c.map(|v| unhalf(half(v))), white);
                    let got = [row[x * 4 + 2], row[x * 4 + 1], row[x * 4]];
                    for i in 0..3 {
                        assert!(got[i].abs_diff(want[i]) <= 1, "white {white}, {c:?}: {got:?}, not {want:?}");
                    }
                    assert_eq!(row[x * 4 + 3], 255);
                }
            }
            unsafe { context.Unmap(&staging, 0) };
        }
    }
}
