# The client core's engine (packages/core/native/engine.cpp, shared with the iOS app) and its JNI (jni.cpp): Hermes
# (com.facebook.react:hermes-android) and the JSI it is built against (com.facebook.react:react-android of the same
# release), both through prefab.
cmake_minimum_required(VERSION 3.22.1)
project(comma_core CXX)
set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

find_package(hermes-engine REQUIRED CONFIG)
find_package(ReactAndroid REQUIRED CONFIG)

set(CORE_NATIVE ${CMAKE_CURRENT_SOURCE_DIR}/../../../../../../packages/core/native)
add_library(comma_core SHARED jni.cpp ${CORE_NATIVE}/engine.cpp)
target_include_directories(comma_core PRIVATE ${CORE_NATIVE})
target_compile_options(comma_core PRIVATE -fexceptions -frtti -O2 -Wall)
target_link_libraries(comma_core hermes-engine::libhermes ReactAndroid::jsi log)
target_link_options(comma_core PRIVATE -Wl,-z,max-page-size=16384)

# The phones' iroh (clients/packages/mesh/native), where Gradle got it (core/build.gradle.kts `meshNative`): the
# engine answers the core's `mesh.*` operations with it. Without it the app reaches no station. Its `state` says
# whether there is one; a change to it configures this again.
if(COMMA_MESH_DIR AND EXISTS ${COMMA_MESH_DIR}/state)
  set_property(DIRECTORY APPEND PROPERTY CMAKE_CONFIGURE_DEPENDS ${COMMA_MESH_DIR}/state)
  file(READ ${COMMA_MESH_DIR}/state mesh_state)
  if(mesh_state STREQUAL "linked")
    add_library(comma_mesh STATIC IMPORTED)
    set_target_properties(comma_mesh PROPERTIES IMPORTED_LOCATION ${COMMA_MESH_DIR}/libcomma_mesh.a)
    target_compile_definitions(comma_core PRIVATE COMMA_MESH=1)
    target_link_libraries(comma_core comma_mesh)
  endif()
endif()
