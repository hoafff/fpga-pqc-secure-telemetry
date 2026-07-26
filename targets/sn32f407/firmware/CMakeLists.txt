cmake_minimum_required(VERSION 3.16)
project(fpst_sn32f407_core C)
set(CMAKE_C_STANDARD 11)
set(CMAKE_C_STANDARD_REQUIRED ON)
add_library(fpst_firmware_core
    src/fpst_crc16.c src/fpst_sha3.c src/fpst_kdf.c src/fpst_transport.c
    src/fpst_spi_mem.c src/fpst_platform.c src/fpst_fpga_link.c src/fpst_session.c)
target_include_directories(fpst_firmware_core PUBLIC include)
target_compile_options(fpst_firmware_core PRIVATE -Wall -Wextra -Werror -Wpedantic)
add_executable(test_firmware_core tests/test_firmware_core.c)
target_link_libraries(test_firmware_core PRIVATE fpst_firmware_core)
target_compile_options(test_firmware_core PRIVATE -Wall -Wextra -Werror -Wpedantic)
enable_testing()
add_test(NAME firmware_core COMMAND test_firmware_core)
