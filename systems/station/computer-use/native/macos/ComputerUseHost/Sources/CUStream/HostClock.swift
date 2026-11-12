// The clock a view's frames and sound are stamped on: the station's `hostNow` (src/mesh/screen-pace.ts,
// process.hrtime), which on macOS counts while the Mac sleeps (libuv reads mach_continuous_time). ScreenCaptureKit's and
// CoreSimulator's presentation times, CoreAudio's host time and DispatchTime are mach_absolute_time, which stops while
// the Mac sleeps: a stamp on it is behind the station's clock by all the sleep since the boot, and the station does not
// count a frame more than 10 s off (FrameLatency). Each stamp is made here, on the clock that runs through sleep.
import Darwin
import Dispatch

enum HostClock {
    /// mach_absolute_time's ticks to ns.
    static let timebase: mach_timebase_info_data_t = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return info
    }()

    /// How far mach_continuous_time is ahead of mach_absolute_time, in µs: the time the Mac slept since its boot.
    static func slept(
        absolute: UInt64 = mach_absolute_time(), continuous: UInt64 = mach_continuous_time(),
        timebase: mach_timebase_info_data_t = HostClock.timebase
    ) -> Int64 {
        guard continuous > absolute else { return 0 }
        return Int64((continuous - absolute) * UInt64(timebase.numer) / UInt64(timebase.denom) / 1000)
    }

    /// The stamp of a time `uptime` µs on mach_absolute_time: µs since the boot, sleep included.
    static func stamp(uptime: Int64, slept: Int64 = HostClock.slept()) -> Int64 {
        uptime + slept
    }

    /// The stamp of now.
    static func now() -> Int64 {
        stamp(uptime: Int64(DispatchTime.now().uptimeNanoseconds / 1000))
    }
}
