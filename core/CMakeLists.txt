add_library(multipoint_core STATIC
    protocol/audio_packet.cpp
    jitter/jitter_buffer.cpp
    network/udp_socket_posix.cpp
)

target_include_directories(multipoint_core PUBLIC include)
target_compile_features(multipoint_core PUBLIC cxx_std_20)
target_compile_options(multipoint_core PRIVATE
    -Wall -Wextra -Wpedantic -Wconversion -Wsign-conversion
)

if(NOT APPLE AND NOT UNIX)
    message(FATAL_ERROR "This phase provides the POSIX UDP backend only")
endif()
