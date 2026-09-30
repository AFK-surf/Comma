{
  "targets": [
    {
      "target_name": "comma_side_chat_backdrop",
      "sources": ["src/side_chat_backdrop.mm"],
      "defines": ["NAPI_VERSION=8"],
      "xcode_settings": {
        "CLANG_CXX_LANGUAGE_STANDARD": "c++20",
        "CLANG_ENABLE_OBJC_ARC": "YES",
        "MACOSX_DEPLOYMENT_TARGET": "13.0"
      },
      "libraries": [
        "-framework AppKit",
        "-framework CoreGraphics",
        "-framework QuartzCore"
      ]
    }
  ]
}
