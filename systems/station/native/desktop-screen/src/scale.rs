// The main display's scale (Settings › Display › Scale: 100%, 125%…), read and set as Settings does: Windows says
// it relative to the recommended step (DisplayConfigGetDeviceInfo's type -3: the lowest, the current and the highest
// steps from the recommended one; -4 sets one), the steps being SCALES. Not in Windows' headers, but what Settings
// itself uses; set, it takes at once, nobody signed out.
#[cfg(windows)]
use serde_json::{Value, json};
#[cfg(windows)]
use windows::Win32::Devices::Display::{
    DISPLAYCONFIG_DEVICE_INFO_GET_SOURCE_NAME, DISPLAYCONFIG_DEVICE_INFO_HEADER, DISPLAYCONFIG_DEVICE_INFO_TYPE, DISPLAYCONFIG_MODE_INFO,
    DISPLAYCONFIG_PATH_INFO, DISPLAYCONFIG_SOURCE_DEVICE_NAME, DisplayConfigGetDeviceInfo, DisplayConfigSetDeviceInfo,
    GetDisplayConfigBufferSizes, QDC_ONLY_ACTIVE_PATHS, QueryDisplayConfig,
};
#[cfg(windows)]
use windows::Win32::Foundation::{ERROR_SUCCESS, LUID};
#[cfg(windows)]
use windows::Win32::Graphics::Gdi::{GetMonitorInfoW, HMONITOR, MONITORINFOEXW};

#[cfg(windows)]
use super::view::main_display;

/// The steps Windows has, in percent.
pub const SCALES: [u32; 12] = [100, 125, 150, 175, 200, 225, 250, 300, 350, 400, 450, 500];

#[cfg(windows)]
const GET_DPI_SCALE: DISPLAYCONFIG_DEVICE_INFO_TYPE = DISPLAYCONFIG_DEVICE_INFO_TYPE(-3);
#[cfg(windows)]
const SET_DPI_SCALE: DISPLAYCONFIG_DEVICE_INFO_TYPE = DISPLAYCONFIG_DEVICE_INFO_TYPE(-4);

#[cfg(windows)]
#[repr(C)]
struct GetScale {
    header: DISPLAYCONFIG_DEVICE_INFO_HEADER,
    min: i32,
    cur: i32,
    max: i32,
}

#[cfg(windows)]
#[repr(C)]
struct SetScale {
    header: DISPLAYCONFIG_DEVICE_INFO_HEADER,
    rel: i32,
}

#[cfg(windows)]
/// The main display's source: its adapter and id, as the display configuration has them.
fn main_source() -> Option<(LUID, u32)> {
    path(main_display().0).map(|p| (p.sourceInfo.adapterId, p.sourceInfo.id))
}

#[cfg(windows)]
/// A display's path in the display configuration (its source and its target, the monitor).
pub fn path(monitor: HMONITOR) -> Option<DISPLAYCONFIG_PATH_INFO> {
    let mut info = MONITORINFOEXW::default();
    info.monitorInfo.cbSize = std::mem::size_of::<MONITORINFOEXW>() as u32;
    unsafe {
        if !GetMonitorInfoW(monitor, &mut info as *mut MONITORINFOEXW as *mut _).as_bool() {
            return None;
        }
        let (mut paths, mut modes) = (0u32, 0u32);
        if GetDisplayConfigBufferSizes(QDC_ONLY_ACTIVE_PATHS, &mut paths, &mut modes) != ERROR_SUCCESS {
            return None;
        }
        let mut path = vec![DISPLAYCONFIG_PATH_INFO::default(); paths as usize];
        let mut mode = vec![DISPLAYCONFIG_MODE_INFO::default(); modes as usize];
        if QueryDisplayConfig(QDC_ONLY_ACTIVE_PATHS, &mut paths, path.as_mut_ptr(), &mut modes, mode.as_mut_ptr(), None) != ERROR_SUCCESS {
            return None;
        }
        path.truncate(paths as usize);
        path.into_iter().find(|p| {
            let mut name = DISPLAYCONFIG_SOURCE_DEVICE_NAME::default();
            name.header.r#type = DISPLAYCONFIG_DEVICE_INFO_GET_SOURCE_NAME;
            name.header.size = std::mem::size_of::<DISPLAYCONFIG_SOURCE_DEVICE_NAME>() as u32;
            name.header.adapterId = p.sourceInfo.adapterId;
            name.header.id = p.sourceInfo.id;
            DisplayConfigGetDeviceInfo(&mut name.header) == 0 && name.viewGdiDeviceName == info.szDevice
        })
    }
}

/// The steps from Windows' answer: the recommended one's index, the current one's, the lowest and highest index taken.
pub fn steps(min: i32, cur: i32, max: i32) -> Option<(usize, usize, usize, usize)> {
    let recommended = min.unsigned_abs() as usize;
    let at = |rel: i32| usize::try_from(recommended as i32 + rel).ok().filter(|i| *i < SCALES.len());
    Some((recommended.min(SCALES.len() - 1), at(cur)?, at(min)?, at(max).unwrap_or(SCALES.len() - 1)))
}

#[cfg(windows)]
/// `{percent, recommended, steps}` of the main display, or `{error}`.
pub fn read() -> Value {
    let Some((adapter, id)) = main_source() else { return json!({ "error": "the main display's source was not found" }) };
    let mut get = GetScale { header: DISPLAYCONFIG_DEVICE_INFO_HEADER { r#type: GET_DPI_SCALE, size: std::mem::size_of::<GetScale>() as u32, adapterId: adapter, id }, min: 0, cur: 0, max: 0 };
    if unsafe { DisplayConfigGetDeviceInfo(&mut get.header) } != 0 {
        return json!({ "error": "Windows did not say the display's scale" });
    }
    match steps(get.min, get.cur, get.max) {
        Some((recommended, current, low, high)) => json!({ "percent": SCALES[current], "recommended": SCALES[recommended], "steps": SCALES[low..=high] }),
        None => json!({ "error": "the display's scale is not one of Windows' steps" }),
    }
}

#[cfg(windows)]
/// Sets the main display's scale to `percent` (one of its steps), then says it as `read` does.
pub fn set(percent: u32) -> Value {
    let Some((adapter, id)) = main_source() else { return json!({ "error": "the main display's source was not found" }) };
    let mut get = GetScale { header: DISPLAYCONFIG_DEVICE_INFO_HEADER { r#type: GET_DPI_SCALE, size: std::mem::size_of::<GetScale>() as u32, adapterId: adapter, id }, min: 0, cur: 0, max: 0 };
    if unsafe { DisplayConfigGetDeviceInfo(&mut get.header) } != 0 {
        return json!({ "error": "Windows did not say the display's scale" });
    }
    let Some((recommended, _, low, high)) = steps(get.min, get.cur, get.max) else { return json!({ "error": "the display's scale is not one of Windows' steps" }) };
    let Some(index) = SCALES.iter().position(|s| *s == percent).filter(|i| (low..=high).contains(i)) else {
        return json!({ "error": format!("{percent}% is not a step of this display") });
    };
    let set = SetScale { header: DISPLAYCONFIG_DEVICE_INFO_HEADER { r#type: SET_DPI_SCALE, size: std::mem::size_of::<SetScale>() as u32, adapterId: adapter, id }, rel: index as i32 - recommended as i32 };
    if unsafe { DisplayConfigSetDeviceInfo(&set.header) } != 0 {
        return json!({ "error": "Windows did not take the scale" });
    }
    read()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn steps_from_the_recommended_one() {
        // Recommended 150% (min -2: 100% is two below), now 300% (+5), up to 350% (+6).
        assert_eq!(steps(-2, 5, 6), Some((2, 7, 0, 8)));
        assert_eq!((SCALES[2], SCALES[7], SCALES[8]), (150, 300, 350));
        // Recommended 100%: nothing below.
        assert_eq!(steps(0, 1, 3), Some((0, 1, 0, 3)));
        // Past the steps: not one.
        assert_eq!(steps(-2, 20, 5), None);
    }
}
