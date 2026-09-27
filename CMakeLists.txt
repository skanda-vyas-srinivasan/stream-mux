cmake_minimum_required(VERSION 3.25)
project(multipoint LANGUAGES C CXX)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)

if(MSVC)
    # Produce a receiver that does not require a separately installed VC runtime.
    set(CMAKE_MSVC_RUNTIME_LIBRARY "MultiThreaded$<$<CONFIG:Debug>:Debug>")
endif()

add_subdirectory(core)

if(APPLE)
    enable_language(OBJCXX)
    add_subdirectory(macos/MultiAudioMac)
endif()

if(WIN32)
    add_subdirectory(windows)
endif()

include(CTest)
if(BUILD_TESTING)
    add_subdirectory(tests)
endif()
