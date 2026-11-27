//! Typed operation arguments, read the way the former gateway read them: a
//! value of the wrong type is absent, never an error.

use serde_json::{Map, Value};

pub type Args = Map<String, Value>;

pub fn string(args: &Args, key: &str) -> String {
    args.get(key)
        .and_then(Value::as_str)
        .unwrap_or_default()
        .to_owned()
}

pub fn optional_string(args: &Args, key: &str) -> Option<String> {
    Some(string(args, key)).filter(|value| !value.is_empty())
}

pub fn boolean(args: &Args, key: &str) -> bool {
    args.get(key).and_then(Value::as_bool).unwrap_or(false)
}

/// A non-negative JSON number or a decimal string; anything else is `fallback`.
pub fn uint64(args: &Args, key: &str, fallback: u64) -> u64 {
    match args.get(key) {
        Some(Value::Number(number)) => {
            if let Some(value) = number.as_u64() {
                value
            } else {
                match number.as_f64() {
                    Some(value) if value >= 0.0 => value as u64,
                    _ => fallback,
                }
            }
        }
        Some(Value::String(text)) => text.parse().unwrap_or(fallback),
        _ => fallback,
    }
}

/// A JSON number; a string is not accepted here.
pub fn int64(args: &Args, key: &str, fallback: i64) -> i64 {
    match args.get(key) {
        Some(Value::Number(number)) => number
            .as_i64()
            .or_else(|| number.as_f64().map(|value| value as i64))
            .unwrap_or(fallback),
        _ => fallback,
    }
}

pub fn uint32(args: &Args, key: &str, fallback: u32) -> u32 {
    u32::try_from(uint64(args, key, u64::from(fallback))).unwrap_or(fallback)
}

pub fn optional_uint32(args: &Args, key: &str) -> Option<u32> {
    if !args.contains_key(key) {
        return None;
    }
    u32::try_from(uint64(args, key, u64::from(u32::MAX) + 1)).ok()
}

/// The strings of a JSON array; other members are skipped.
pub fn string_list(args: &Args, key: &str) -> Vec<String> {
    match args.get(key) {
        Some(Value::Array(values)) => values
            .iter()
            .filter_map(|value| value.as_str().map(str::to_owned))
            .collect(),
        _ => Vec::new(),
    }
}

pub fn map_list<'a>(args: &'a Args, key: &str) -> Vec<&'a Args> {
    match args.get(key) {
        Some(Value::Array(values)) => values.iter().filter_map(Value::as_object).collect(),
        _ => Vec::new(),
    }
}

/// JSON with object keys in byte order at every depth: equal values give equal text.
pub fn canonical(value: &Value) -> String {
    fn write(value: &Value, out: &mut String) {
        match value {
            Value::Object(map) => {
                let mut keys: Vec<&String> = map.keys().collect();
                keys.sort();
                out.push('{');
                for (index, key) in keys.into_iter().enumerate() {
                    if index > 0 {
                        out.push(',');
                    }
                    out.push_str(&Value::String(key.clone()).to_string());
                    out.push(':');
                    write(&map[key], out);
                }
                out.push('}');
            }
            Value::Array(values) => {
                out.push('[');
                for (index, value) in values.iter().enumerate() {
                    if index > 0 {
                        out.push(',');
                    }
                    write(value, out);
                }
                out.push(']');
            }
            scalar => out.push_str(&scalar.to_string()),
        }
    }
    let mut out = String::new();
    write(value, &mut out);
    out
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn args(value: Value) -> Args {
        value.as_object().cloned().unwrap()
    }

    #[test]
    fn numbers_keep_the_former_gateway_reading() {
        let args = args(json!({
            "n": 7, "f": 7.9, "neg": -1, "text": "18446744073709551615", "bad": "x",
            "big": 4294967296u64, "flag": true, "list": ["a", 1, "b"]
        }));
        assert_eq!(uint64(&args, "n", 0), 7);
        assert_eq!(uint64(&args, "f", 0), 7);
        assert_eq!(uint64(&args, "neg", 9), 9);
        assert_eq!(uint64(&args, "text", 0), u64::MAX);
        assert_eq!(uint64(&args, "bad", 3), 3);
        assert_eq!(uint64(&args, "missing", 5), 5);
        assert_eq!(uint32(&args, "big", 11), 11);
        assert_eq!(optional_uint32(&args, "big"), None);
        assert_eq!(optional_uint32(&args, "n"), Some(7));
        assert_eq!(optional_uint32(&args, "missing"), None);
        // A deadline sent as text is not a number: the caller's fallback stands.
        assert_eq!(int64(&args, "text", 0), 0);
        assert_eq!(int64(&args, "neg", 0), -1);
        assert!(boolean(&args, "flag") && !boolean(&args, "n"));
        assert_eq!(string_list(&args, "list"), ["a", "b"]);
    }

    #[test]
    fn canonical_text_ignores_key_order() {
        let left: Value = serde_json::from_str(r#"{"b":[{"y":1,"x":2}],"a":"t"}"#).unwrap();
        let right: Value = serde_json::from_str(r#"{"a":"t","b":[{"x":2,"y":1}]}"#).unwrap();
        assert_eq!(canonical(&left), canonical(&right));
        assert_eq!(canonical(&left), r#"{"a":"t","b":[{"x":2,"y":1}]}"#);
    }
}
