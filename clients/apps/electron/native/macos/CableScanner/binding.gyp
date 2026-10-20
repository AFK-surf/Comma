{
  "targets": [
    {
      "target_name": "comma_cable_scanner",
      "sources": ["src/cable_scanner.mm"],
      "defines": ["NAPI_VERSION=8"],
      "xcode_settings": {
        "CLANG_CXX_LANGUAGE_STANDARD": "c++20",
        "CLANG_ENABLE_OBJC_ARC": "YES",
        "GCC_ENABLE_OBJC_EXCEPTIONS": "YES",
        "MACOSX_DEPLOYMENT_TARGET": "13.0"
      },
      "libraries": [
        "-framework CoreBluetooth",
        "-framework Foundation"
      ]
    }
  ]
}
