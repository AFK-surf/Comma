import Darwin
import Testing
@testable import CUStream

// A frame's stamp is on the clock the station reads (HostClock.swift): mach_continuous_time, which runs while the Mac
// sleeps, not mach_absolute_time, which ScreenCaptureKit, CoreAudio and DispatchTime say and which stops.

/// A Mac that slept 65,000 s since its boot (as the MacBook did): a capture time on mach_absolute_time is stamped as
/// mach_continuous_time says that moment.
@Test
func aStampCountsTheTimeTheMacSlept() {
    let timebase = mach_timebase_info_data_t(numer: 125, denom: 3)
    let ticks = { (µs: UInt64) in µs * 1000 * 3 / 125 }
    let absolute = ticks(3_600_000_000)
    let continuous = absolute + ticks(65_000_000_000)
    let slept = HostClock.slept(absolute: absolute, continuous: continuous, timebase: timebase)
    #expect(slept == 65_000_000_000)
    // A picture captured 20 ms before that moment.
    let captured = Int64(absolute * 125 / 3 / 1000) - 20_000
    let continuousµs = Int64(continuous * 125 / 3 / 1000)
    #expect(HostClock.stamp(uptime: captured, slept: slept) == continuousµs - 20_000)
}

/// A picture stamped now (a simulator's still screen, a frame with no capture time) is on this Mac's continuous clock
/// (CLOCK_MONOTONIC_RAW on Darwin: mach_continuous_time, as the station's process.hrtime reads it).
@Test
func aStampNowIsOnTheContinuousClock() {
    let before = Int64(clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW) / 1000)
    let stamped = HostClock.now()
    let after = Int64(clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW) / 1000)
    #expect(stamped >= before - 1 && stamped <= after + 1)
}
