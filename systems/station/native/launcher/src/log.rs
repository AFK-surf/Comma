//! The launcher's lines on stderr (launchd writes them to stillfail.log), shaped like the Rust station's: an RFC 3339
//! time, the level, what happened.

pub fn info(text: &str) {
    line("INFO", text);
}

pub fn warn(text: &str) {
    line("WARN", text);
}

pub fn error(text: &str) {
    line("ERROR", text);
}

fn line(level: &str, text: &str) {
    let line = format!("{} {level:>5} stillfail-station: {text}", iso(crate::data::now_ms()));
    // In tests, where the harness keeps it to show with a failure.
    #[cfg(test)]
    eprintln!("{line}");
    #[cfg(not(test))]
    {
        use std::io::Write;
        let _ = writeln!(std::io::stderr().lock(), "{line}");
    }
}

/// `ms` since the epoch as UTC, to the millisecond.
pub fn iso(ms: u64) -> String {
    let (days, rest) = ((ms / 86_400_000) as i64, ms % 86_400_000);
    // Civil date from days since 1970-01-01 (Howard Hinnant's algorithm).
    let z = days + 719_468;
    let era = z.div_euclid(146_097);
    let doe = z - era * 146_097;
    let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let day = doy - (153 * mp + 2) / 5 + 1;
    let month = if mp < 10 { mp + 3 } else { mp - 9 };
    let year = yoe + era * 400 + i64::from(month <= 2);
    let (h, m, s, milli) = (rest / 3_600_000, rest / 60_000 % 60, rest / 1000 % 60, rest % 1000);
    format!("{year:04}-{month:02}-{day:02}T{h:02}:{m:02}:{s:02}.{milli:03}Z")
}

#[cfg(test)]
mod tests {
    #[test]
    fn times_read_as_utc() {
        assert_eq!(super::iso(0), "1970-01-01T00:00:00.000Z");
        assert_eq!(super::iso(1_790_000_000_123), "2026-09-21T14:13:20.123Z");
        assert_eq!(super::iso(951_782_400_000), "2000-02-29T00:00:00.000Z");
    }
}
