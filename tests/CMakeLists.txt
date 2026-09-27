add_executable(multipoint_core_tests test_main.cpp)
target_link_libraries(multipoint_core_tests PRIVATE multipoint_core)
target_compile_options(multipoint_core_tests PRIVATE
    -Wall -Wextra -Wpedantic -Wconversion -Wsign-conversion
)
add_test(NAME multipoint_core_tests COMMAND multipoint_core_tests)

if(APPLE)
    add_executable(soundmux_capture_conversion_tests capture_conversion_tests.cpp)
    target_link_libraries(soundmux_capture_conversion_tests PRIVATE soundmux_capture_conversion)
    target_compile_options(soundmux_capture_conversion_tests PRIVATE
        -Wall -Wextra -Wpedantic -Wconversion -Wsign-conversion
    )
    add_test(NAME soundmux_capture_conversion_tests COMMAND soundmux_capture_conversion_tests)
endif()
