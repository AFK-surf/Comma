// The main display's resolution (Settings › Display › Display resolution: 2560×1440, 1920×1080…), read and set as
// Settings does: the modes its adapter lists for it (EnumDisplaySettingsW), one of them set at once
// (ChangeDisplaySettingsExW with no flags: for now, not written to the registry, so nothing outlasts the session
// should the station go before putting it back).
#[cfg(windows)]
use serde_json::{Value, json};
#[cfg(windows)]
use windows::Win32::Graphics::Gdi::{
    CDS_TYPE, ChangeDisplaySettingsExW, DEVMODEW, DISP_CHANGE_SUCCESSFUL, ENUM_CURRENT_SETTINGS, ENUM_DISPLAY_SETTINGS_MODE,
    EnumDisplaySettingsW, GetMonitorInfoW, MONITORINFOEXW,
};
#[cfg(windows)]
use windows::core::PCWSTR;

#[cfg(windows)]
use super::view::main_display;

/// The least width a mode offered has (narrower is no use to look at a desktop through).
pub const LEAST_WIDTH: u32 = 800;

/// A mode as the adapter lists it: its width and height in pixels, its colour depth, its refresh rate.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Mode {
    pub width: u32,
    pub height: u32,
    pub bits: u32,
    pub hz: u32,
}

/// The sizes worth offering of `all`, as `now` is: at its depth and refresh rate (any rate a size has none at it),
/// landscape, at least LEAST_WIDTH wide, each once, the largest first; the current one always among them.
pub fn offered(all: &[Mode], now: Mode) -> Vec<(u32, u32)> {
    let mut sizes: Vec<(u32, u32)> = all
        .iter()
        .filter(|m| m.bits == now.bits && m.width >= LEAST_WIDTH && m.width > m.height)
        .map(|m| (m.width, m.height))
        .collect();
    sizes.push((now.width, now.height));
    sizes.sort_by(|a, b| (b.0 * b.1, b.0).cmp(&(a.0 * a.1, a.0)));
    sizes.dedup();
    sizes
}

/// The mode of `all` to set for `width`×`height`: at `now`'s depth, its refresh rate where the size has it, else the
/// highest the size has; None when the adapter lists no such size.
pub fn chosen(all: &[Mode], now: Mode, width: u32, height: u32) -> Option<Mode> {
    let same = |m: &&Mode| m.width == width && m.height == height && m.bits == now.bits;
    all.iter().filter(same).find(|m| m.hz == now.hz).or_else(|| all.iter().filter(same).max_by_key(|m| m.hz)).copied()
}

/// `WxH` (or `W×H`) as a size.
pub fn parse(s: &str) -> Option<(u32, u32)> {
    let (w, h) = s.split_once(['x', 'X', '×'])?;
    Some((w.trim().parse().ok()?, h.trim().parse().ok()?))
}

#[cfg(windows)]
/// The main display's device name (`\\.\DISPLAY1`), as a wide string ending in its nul.
fn device() -> Option<Vec<u16>> {
    let mut info = MONITORINFOEXW::default();
    info.monitorInfo.cbSize = std::mem::size_of::<MONITORINFOEXW>() as u32;
    if !unsafe { GetMonitorInfoW(main_display().0, &mut info as *mut MONITORINFOEXW as *mut _) }.as_bool() {
        return None;
    }
    let end = info.szDevice.iter().position(|c| *c == 0).unwrap_or(info.szDevice.len());
    let mut name = info.szDevice[..end].to_vec();
    name.push(0);
    Some(name)
}

#[cfg(windows)]
fn devmode() -> DEVMODEW {
    DEVMODEW { dmSize: std::mem::size_of::<DEVMODEW>() as u16, ..Default::default() }
}

#[cfg(windows)]
fn mode_of(d: &DEVMODEW) -> Mode {
    Mode { width: d.dmPelsWidth, height: d.dmPelsHeight, bits: d.dmBitsPerPel, hz: d.dmDisplayFrequency }
}

#[cfg(windows)]
/// The display's current mode and every mode its adapter lists for it (the DEVMODEs too, to set one).
fn modes(name: &[u16]) -> Option<(Mode, Vec<(Mode, DEVMODEW)>)> {
    let name = PCWSTR(name.as_ptr());
    let mut now = devmode();
    if !unsafe { EnumDisplaySettingsW(name, ENUM_CURRENT_SETTINGS, &mut now) }.as_bool() {
        return None;
    }
    let mut all = Vec::new();
    for i in 0.. {
        let mut d = devmode();
        if !unsafe { EnumDisplaySettingsW(name, ENUM_DISPLAY_SETTINGS_MODE(i), &mut d) }.as_bool() {
            break;
        }
        all.push((mode_of(&d), d));
    }
    Some((mode_of(&now), all))
}

#[cfg(windows)]
/// `{width, height, modes: [{width, height}…]}` of the main display, or `{error}`.
pub fn read() -> Value {
    let Some(name) = device() else { return json!({ "error": "the main display was not found" }) };
    let Some((now, all)) = modes(&name) else { return json!({ "error": "Windows did not say the display's mode" }) };
    let listed: Vec<Mode> = all.iter().map(|(m, _)| *m).collect();
    let sizes: Vec<Value> = offered(&listed, now).into_iter().map(|(w, h)| json!({ "width": w, "height": h })).collect();
    json!({ "width": now.width, "height": now.height, "modes": sizes })
}

#[cfg(windows)]
/// Sets the main display to `width`×`height` (one of its modes), then says it as `read` does.
pub fn set(width: u32, height: u32) -> Value {
    let Some(name) = device() else { return json!({ "error": "the main display was not found" }) };
    let Some((now, all)) = modes(&name) else { return json!({ "error": "Windows did not say the display's mode" }) };
    let listed: Vec<Mode> = all.iter().map(|(m, _)| *m).collect();
    let Some(want) = chosen(&listed, now, width, height) else {
        return json!({ "error": format!("{width}×{height} is not a mode of this display") });
    };
    if want != now {
        let Some((_, d)) = all.iter().find(|(m, _)| *m == want) else { return json!({ "error": "the mode went" }) };
        let mut d = *d;
        // (the size and rate alone: the rest as the adapter listed it)
        d.dmFields = windows::Win32::Graphics::Gdi::DM_PELSWIDTH
            | windows::Win32::Graphics::Gdi::DM_PELSHEIGHT
            | windows::Win32::Graphics::Gdi::DM_BITSPERPEL
            | windows::Win32::Graphics::Gdi::DM_DISPLAYFREQUENCY;
        let r = unsafe { ChangeDisplaySettingsExW(PCWSTR(name.as_ptr()), Some(&d), None, CDS_TYPE(0), None) };
        if r != DISP_CHANGE_SUCCESSFUL {
            return json!({ "error": format!("Windows did not take {width}×{height} ({})", r.0) });
        }
    }
    read()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn m(width: u32, height: u32, bits: u32, hz: u32) -> Mode {
        Mode { width, height, bits, hz }
    }

    #[test]
    fn the_sizes_offered() {
        let now = m(2560, 1440, 32, 144);
        let all = [
            m(2560, 1440, 32, 60),
            m(2560, 1440, 32, 144),
            m(1920, 1080, 32, 60),
            m(1920, 1080, 32, 144),
            m(1600, 1200, 32, 60),
            m(1680, 1050, 32, 60),
            // too narrow, another depth, upright: none of them
            m(640, 480, 32, 60),
            m(1280, 1024, 16, 60),
            m(1080, 1920, 32, 60),
            m(1280, 720, 32, 60),
        ];
        assert_eq!(offered(&all, now), vec![(2560, 1440), (1920, 1080), (1600, 1200), (1680, 1050), (1280, 720)]);
    }

    #[test]
    fn the_current_one_is_offered_even_unlisted() {
        assert_eq!(offered(&[], m(1366, 768, 32, 60)), vec![(1366, 768)]);
    }

    #[test]
    fn the_mode_set_keeps_the_rate_where_it_can() {
        let now = m(2560, 1440, 32, 144);
        let all = [m(1920, 1080, 32, 60), m(1920, 1080, 32, 144), m(1600, 1200, 32, 60), m(1600, 1200, 32, 75)];
        assert_eq!(chosen(&all, now, 1920, 1080), Some(m(1920, 1080, 32, 144)));
        assert_eq!(chosen(&all, now, 1600, 1200), Some(m(1600, 1200, 32, 75)));
        assert_eq!(chosen(&all, now, 1024, 768), None);
    }

    #[test]
    fn sizes_parsed() {
        assert_eq!(parse("1920x1080"), Some((1920, 1080)));
        assert_eq!(parse("1600×1200"), Some((1600, 1200)));
        assert_eq!(parse("1920"), None);
    }
}
