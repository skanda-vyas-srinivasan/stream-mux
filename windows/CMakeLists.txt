add_executable(soundmux_windows_receiver
    receiver_main.cpp
    receiver_runtime.cpp
    wasapi_output.cpp
    windows_identity.cpp
)

target_link_libraries(soundmux_windows_receiver PRIVATE
    multipoint_core
    advapi32
    crypt32
    ole32
    uuid
)

target_compile_definitions(soundmux_windows_receiver PRIVATE
    NOMINMAX
    WIN32_LEAN_AND_MEAN
)

target_compile_options(soundmux_windows_receiver PRIVATE /W4 /permissive-)
