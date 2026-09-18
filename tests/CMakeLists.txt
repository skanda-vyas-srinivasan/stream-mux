add_executable(multipoint_core_tests test_main.cpp)
target_link_libraries(multipoint_core_tests PRIVATE multipoint_core)
target_compile_options(multipoint_core_tests PRIVATE
    -Wall -Wextra -Wpedantic -Wconversion -Wsign-conversion
)
add_test(NAME multipoint_core_tests COMMAND multipoint_core_tests)
