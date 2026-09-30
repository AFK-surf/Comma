# Bundled notices

The build copies these notices into the application's `priv/licenses` directory.
It also copies the Lean and mimalloc licenses from their pinned source trees.

- `libuv.txt`: libuv v1.48.0, the version in the pinned Lean SDK.
- `otp.txt`: Erlang/OTP 29.0.2, the source of the Unicode grapheme tables.
- `unicode.txt`: Unicode data license for those tables.

The NIF uses Lean's built-in bignum implementation. It does not link GMP.
