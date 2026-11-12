# LAN script runtime

A copy of AFK-surf/Hardware `firmware/components/lan_script` (without its PSA crypto, which is
`src/lan_script.rs` here): the runtime the gateway boards run LAN scripts in, on Micro QuickJS
(`mquickjs/`, MIT, bellard/mquickjs 6d4d7eb). Change both copies together; `tests/lan_script_selftest.js`
is the same file as Hardware's `firmware/tools/lan_script_test/selftest.js`.
