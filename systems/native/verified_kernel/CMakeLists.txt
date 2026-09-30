cmake_minimum_required(VERSION 3.24)
project(salix_verified_kernel C CXX)
include(FetchContent)

if(NOT CMAKE_SYSTEM_NAME MATCHES "^(Linux|Darwin)$")
  message(FATAL_ERROR "The verified kernel supports Linux and macOS only")
endif()
set(CMAKE_CXX_STANDARD 20)
set(CMAKE_POSITION_INDEPENDENT_CODE ON)

# Same sources as the pinned Lean 4.33.1 compiler and its mimalloc dependency.
FetchContent_Declare(lean
  URL https://codeload.github.com/leanprover/lean4/tar.gz/819816b2e0a3bf405af45ae5c7af2491d8f5bee6
  SOURCE_SUBDIR salix-download-only)
FetchContent_Declare(mimalloc
  URL https://codeload.github.com/microsoft/mimalloc/tar.gz/94036de6fe20bfd8a73d4a6d142fcf532ea604d9
  SOURCE_SUBDIR salix-download-only)
FetchContent_MakeAvailable(lean mimalloc)

find_package(PkgConfig REQUIRED)
pkg_check_modules(UV REQUIRED IMPORTED_TARGET libuv)
find_package(OpenSSL REQUIRED)
find_package(Threads REQUIRED)

set(GIT_SHA1 "819816b2e0a3bf405af45ae5c7af2491d8f5bee6")
configure_file("${lean_SOURCE_DIR}/src/githash.h.in" githash.h @ONLY)

# Build runtime sources, not the compiler or prover. Installed libleanrt.a
# uses local-exec TLS and cannot be embedded in a dlopen-loaded NIF.
file(GLOB runtime_sources CONFIGURE_DEPENDS
  "${lean_SOURCE_DIR}/src/runtime/*.cpp" "${lean_SOURCE_DIR}/src/runtime/uv/*.cpp")
add_library(leanrt_pic STATIC ${runtime_sources} "${mimalloc_SOURCE_DIR}/src/static.c")
target_include_directories(leanrt_pic PRIVATE
  "${LEAN_PREFIX}/include" "${lean_SOURCE_DIR}/src" "${mimalloc_SOURCE_DIR}/include" "${CMAKE_CURRENT_BINARY_DIR}")
# Use Lean's built-in bignum implementation. This avoids an embedded LGPL
# library and Bookworm's GMP version, which is older than Lean's minimum.
target_compile_definitions(leanrt_pic PRIVATE LEAN_MULTI_THREAD LEAN_EXPORTING)
target_compile_options(leanrt_pic PRIVATE -O3 -fvisibility=hidden -ffunction-sections -fdata-sections)
if(CMAKE_SYSTEM_NAME STREQUAL "Linux")
  target_compile_options(leanrt_pic PRIVATE -ftls-model=global-dynamic)
  # TLS descriptors keep the dlopen-safe model without a `__tls_get_addr`
  # call on each access; every allocation reads the thread's heap and
  # heartbeat.
  include(CheckCCompilerFlag)
  check_c_compiler_flag(-mtls-dialect=gnu2 tls_descriptors)
  if(tls_descriptors)
    target_compile_options(leanrt_pic PRIVATE -mtls-dialect=gnu2)
  endif()
endif()
set_source_files_properties("${mimalloc_SOURCE_DIR}/src/static.c" PROPERTIES
  COMPILE_DEFINITIONS "MI_SHARED_LIB;MI_SHARED_LIB_EXPORT;MI_SECURE=0")
target_include_directories(leanrt_pic PRIVATE ${UV_INCLUDE_DIRS})
target_link_libraries(leanrt_pic PRIVATE OpenSSL::SSL)

# Lake records the native entry point's transitive import artifacts in its compiler setup.
# Use that graph so proof-only or stale IR cannot enter the runtime library.
set(lean_ir_root "${CMAKE_CURRENT_SOURCE_DIR}/.lake/build/ir")
set(lean_object_root "${CMAKE_CURRENT_SOURCE_DIR}/.lake/build/lib/lean")
set(lean_standard_root "${LEAN_PREFIX}/lib/lean")
set(dispatch_setup "${lean_ir_root}/VerifiedKernel/Native.setup.json")
set_property(DIRECTORY APPEND PROPERTY CMAKE_CONFIGURE_DEPENDS "${dispatch_setup}")
file(READ "${dispatch_setup}" dispatch_setup_json)
string(JSON import_count LENGTH "${dispatch_setup_json}" importArts)
set(generated_sources "${lean_ir_root}/VerifiedKernel/Native.c")
if(import_count GREATER 0)
  math(EXPR last_import "${import_count} - 1")
  foreach(import_index RANGE 0 ${last_import})
    string(JSON import_name MEMBER "${dispatch_setup_json}" importArts ${import_index})
    string(JSON import_object GET "${dispatch_setup_json}" importArts "${import_name}" 0 0)
    cmake_path(IS_PREFIX lean_object_root "${import_object}" NORMALIZE local_import)
    cmake_path(IS_PREFIX lean_standard_root "${import_object}" NORMALIZE standard_import)
    if(local_import)
      file(RELATIVE_PATH import_relative "${lean_object_root}" "${import_object}")
      string(REGEX REPLACE "\\.olean$" ".c" import_source "${import_relative}")
      list(APPEND generated_sources "${lean_ir_root}/${import_source}")
    elseif(NOT standard_import)
      message(FATAL_ERROR "No native source mapping for runtime import ${import_name}: ${import_object}")
    endif()
  endforeach()
endif()
add_library(verified_kernel SHARED c/verified_kernel_nif.c ${generated_sources})
set_target_properties(verified_kernel PROPERTIES PREFIX "" SUFFIX ".so" LIBRARY_OUTPUT_DIRECTORY "${CMAKE_CURRENT_SOURCE_DIR}/priv")
target_include_directories(verified_kernel PRIVATE "${LEAN_PREFIX}/include" "${ERTS_INCLUDE}")
target_compile_options(verified_kernel PRIVATE -O3 -fvisibility=hidden -ffunction-sections -fdata-sections)
if(APPLE)
  # BEAM loads .so files and resolves the NIF API from the host executable.
  target_link_options(verified_kernel PRIVATE
    "-Wl,-exported_symbol,_nif_init" -Wl,-dead_strip -Wl,-undefined,dynamic_lookup)
  target_link_libraries(verified_kernel PRIVATE
    "${LEAN_PREFIX}/lib/lean/libStd.a" "${LEAN_PREFIX}/lib/lean/libInit.a" leanrt_pic
    "${LEAN_PREFIX}/lib/libuv.a")
else()
  target_link_options(verified_kernel PRIVATE
    "-Wl,--version-script=${CMAKE_CURRENT_SOURCE_DIR}/c/exports.map" -Wl,--gc-sections)
  set_property(TARGET verified_kernel APPEND PROPERTY LINK_DEPENDS "${CMAKE_CURRENT_SOURCE_DIR}/c/exports.map")
  target_link_libraries(verified_kernel PRIVATE
    -Wl,--start-group "${LEAN_PREFIX}/lib/lean/libStd.a" "${LEAN_PREFIX}/lib/lean/libInit.a" leanrt_pic
    "${LEAN_PREFIX}/lib/libuv.a" -Wl,--end-group)
endif()
target_link_libraries(verified_kernel PRIVATE OpenSSL::SSL OpenSSL::Crypto Threads::Threads ${CMAKE_DL_LIBS} m)

# Link-time optimization inlines the runtime's allocation and reference-count
# paths into the generated kernel code, which calls them on every term.
include(CheckIPOSupported)
check_ipo_supported(RESULT ipo_supported OUTPUT ipo_message LANGUAGES C CXX)
if(ipo_supported)
  set_property(TARGET leanrt_pic verified_kernel PROPERTY INTERPROCEDURAL_OPTIMIZATION TRUE)
endif()

file(MAKE_DIRECTORY "${CMAKE_CURRENT_SOURCE_DIR}/priv/licenses")
configure_file("${lean_SOURCE_DIR}/LICENSE" "${CMAKE_CURRENT_SOURCE_DIR}/priv/licenses/lean.txt" COPYONLY)
configure_file("${mimalloc_SOURCE_DIR}/LICENSE" "${CMAKE_CURRENT_SOURCE_DIR}/priv/licenses/mimalloc.txt" COPYONLY)
file(COPY "${CMAKE_CURRENT_SOURCE_DIR}/licenses/" DESTINATION "${CMAKE_CURRENT_SOURCE_DIR}/priv/licenses")
