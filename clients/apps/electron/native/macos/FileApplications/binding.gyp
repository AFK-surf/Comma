{
  "targets": [
    {
      "target_name": "comma_file_applications",
      "sources": ["src/file_applications.mm"],
      "defines": ["NAPI_VERSION=8"],
      "xcode_settings": {
        "CLANG_CXX_LANGUAGE_STANDARD": "c++20",
        "CLANG_ENABLE_OBJC_ARC": "YES",
        "GCC_ENABLE_OBJC_EXCEPTIONS": "YES",
        "MACOSX_DEPLOYMENT_TARGET": "13.0"
      },
      "libraries": [
        "-framework Foundation",
        "-framework AppKit",
        "-framework UniformTypeIdentifiers"
      ]
    }
  ]
}
