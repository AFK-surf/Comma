{
  "targets": [
    {
      "target_name": "comma_sleep_guard",
      "sources": ["src/sleep_guard.mm"],
      "defines": ["NAPI_VERSION=8"],
      "xcode_settings": {
        "CLANG_CXX_LANGUAGE_STANDARD": "c++20",
        "CLANG_ENABLE_OBJC_ARC": "YES",
        "GCC_ENABLE_OBJC_EXCEPTIONS": "YES",
        "MACOSX_DEPLOYMENT_TARGET": "13.0"
      },
      "libraries": [
        "-framework Foundation",
        "-framework ServiceManagement"
      ]
    }
  ]
}
