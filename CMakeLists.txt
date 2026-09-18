cmake_minimum_required(VERSION 3.25)
project(multipoint LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)

add_subdirectory(core)

if(APPLE)
    enable_language(OBJCXX)
    add_subdirectory(macos/MultiAudioMac)
endif()

include(CTest)
if(BUILD_TESTING)
    add_subdirectory(tests)
endif()
