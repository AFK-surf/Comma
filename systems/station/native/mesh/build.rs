fn main() {
    // Node's symbols come from the process that loads the addon (-undefined dynamic_lookup on macOS).
    napi_build::setup();
}
