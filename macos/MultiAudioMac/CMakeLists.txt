add_executable(multipoint_sine_sender synthetic_sender.cpp)
target_link_libraries(multipoint_sine_sender PRIVATE multipoint_core)

add_executable(multipoint_receiver receiver_main.mm)
target_link_libraries(multipoint_receiver PRIVATE
    multipoint_core
    "-framework AudioToolbox"
    "-framework CoreAudio"
    "-framework Foundation"
)
target_compile_options(multipoint_receiver PRIVATE -Wall -Wextra -Wpedantic)
