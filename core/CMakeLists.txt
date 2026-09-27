add_library(multipoint_core STATIC
    ../third_party/monocypher/monocypher.c
    protocol/audio_packet.cpp
    protocol/fec.cpp
    protocol/session.cpp
    protocol/session_crypto.cpp
    jitter/jitter_buffer.cpp
    network/connection_plan.cpp
    transport/receiver_engine.cpp
    transport/fanout_sender.cpp
    transport/sender_engine.cpp
)

if(WIN32)
    target_sources(multipoint_core PRIVATE network/udp_socket_windows.cpp)
    target_link_libraries(multipoint_core PUBLIC ws2_32 bcrypt)
else()
    target_sources(multipoint_core PRIVATE network/udp_socket_posix.cpp)
endif()

target_include_directories(multipoint_core
    PUBLIC include
    PRIVATE ../third_party/monocypher
)
target_compile_features(multipoint_core PUBLIC cxx_std_20)
if(MSVC)
    target_compile_options(multipoint_core PRIVATE /W4 /permissive-)
else()
    target_compile_options(multipoint_core PRIVATE
        -Wall -Wextra -Wpedantic -Wconversion -Wsign-conversion
    )
endif()
