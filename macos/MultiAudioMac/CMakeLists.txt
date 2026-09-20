add_executable(multipoint_sine_sender synthetic_sender.cpp)
target_link_libraries(multipoint_sine_sender PRIVATE multipoint_core)

add_executable(multipoint_mac_sender sender_main.mm)
target_link_libraries(multipoint_mac_sender PRIVATE
    multipoint_core
    "-framework AppKit"
    "-framework ApplicationServices"
    "-framework CoreAudio"
    "-framework Foundation"
)
target_compile_options(multipoint_mac_sender PRIVATE
    -Wall -Wextra -Wpedantic -fobjc-arc
)
target_link_options(multipoint_mac_sender PRIVATE
    "LINKER:-sectcreate,__TEXT,__info_plist,${CMAKE_CURRENT_SOURCE_DIR}/SenderInfo.plist"
)

add_executable(soundmux_sender_app MACOSX_BUNDLE sender_main.mm)
target_link_libraries(soundmux_sender_app PRIVATE
    multipoint_core
    "-framework AppKit"
    "-framework ApplicationServices"
    "-framework CoreAudio"
    "-framework Foundation"
)
target_compile_options(soundmux_sender_app PRIVATE
    -Wall -Wextra -Wpedantic -fobjc-arc
)
set_target_properties(soundmux_sender_app PROPERTIES
    OUTPUT_NAME "SoundMux Sender"
    MACOSX_BUNDLE_BUNDLE_NAME "SoundMux Sender"
    MACOSX_BUNDLE_GUI_IDENTIFIER "com.skandavyas.soundmux.mac-sender"
    MACOSX_BUNDLE_INFO_PLIST "${CMAKE_CURRENT_SOURCE_DIR}/SenderAppInfo.plist.in"
    MACOSX_BUNDLE_SHORT_VERSION_STRING "0.1.0"
)

add_executable(multipoint_receiver receiver_main.mm)
target_link_libraries(multipoint_receiver PRIVATE
    multipoint_core
    "-framework AudioToolbox"
    "-framework CoreAudio"
    "-framework Foundation"
)
target_compile_options(multipoint_receiver PRIVATE -Wall -Wextra -Wpedantic)
