cmake_minimum_required(VERSION 3.16)
project(fpst_sn32f407_core C)
set(CMAKE_C_STANDARD 11)
set(CMAKE_C_STANDARD_REQUIRED ON)

option(FPST_ENABLE_MLKEM_NATIVE "Build pinned mlkem-native ML-KEM-512 integration" OFF)
set(FPST_MLKEM_NATIVE_ROOT
    "${CMAKE_CURRENT_SOURCE_DIR}/../../../software/third_party/mlkem-native/src"
    CACHE PATH "Path to pq-code-package/mlkem-native v1.0.0 checkout")

add_library(fpst_firmware_core
    src/fpst_crc32.c
    src/fpst_sha3.c
    src/fpst_kdf.c
    src/fpst_heartbeat_gate.c
    src/fpst_transport.c
    src/fpst_platform.c
    src/fpst_fpga_link.c
    src/fpst_primer1.c
    src/fpst_primer2.c
    src/fpst_pair_bridge.c
    src/fpst_session.c
    src/fpst_csprng.c
    src/fpst_entropy_rng.c
    src/fpst_telemetry.c
    src/fpst_mlkem512_lowram.c
    src/fpst_mlkem512_wrapper.c
    src/fpst_mlkem_session.c)
target_include_directories(fpst_firmware_core PUBLIC include)
target_compile_options(fpst_firmware_core PRIVATE -Wall -Wextra -Werror -Wpedantic)

# Host-only syntax gate for the two new target-specific board sources. The fake
# SN32 header models only register names touched by these files; real sign-off is
# still ARM Compiler 6 + organizer DFP as documented in KEIL_DUAL_PRIMER_BUILD.md.
add_library(test_sn32_dual_board_syntax OBJECT
    platform/sn32f407/fpst_sn32f407_multiport.c
    platform/sn32f407/fpst_sn32f407_dual_main.c)
target_include_directories(test_sn32_dual_board_syntax PRIVATE
    tests/sn32_fake
    include
    platform/sn32f407)
target_compile_options(test_sn32_dual_board_syntax PRIVATE
    -Wall -Wextra -Werror -Wpedantic)

if(FPST_ENABLE_MLKEM_NATIVE)
    set(FPST_MLKEM_NATIVE_MONOLITHIC "${FPST_MLKEM_NATIVE_ROOT}/mlkem/mlkem_native.c")
    set(FPST_MLKEM_NATIVE_API_DIR "${FPST_MLKEM_NATIVE_ROOT}/mlkem")
    if(NOT EXISTS "${FPST_MLKEM_NATIVE_MONOLITHIC}")
        message(FATAL_ERROR
            "Pinned mlkem-native source not found. See software/third_party/mlkem-native/LOCK.md")
    endif()

    add_library(fpst_mlkem_native_upstream STATIC "${FPST_MLKEM_NATIVE_MONOLITHIC}")
    target_include_directories(fpst_mlkem_native_upstream PRIVATE
        "${FPST_MLKEM_NATIVE_API_DIR}"
        "${CMAKE_CURRENT_SOURCE_DIR}/include")
    target_compile_definitions(fpst_mlkem_native_upstream PRIVATE
        MLK_CONFIG_FILE=\"fpst_mlkem512_config.h\")

    target_include_directories(fpst_firmware_core PRIVATE "${FPST_MLKEM_NATIVE_API_DIR}")
    target_compile_definitions(fpst_firmware_core PRIVATE
        FPST_MLKEM_NATIVE_ENABLED=1
        MLK_CONFIG_FILE=\"fpst_mlkem512_config.h\")
    target_link_libraries(fpst_firmware_core PUBLIC fpst_mlkem_native_upstream)

    add_library(fpst_mlkem_native_reference STATIC "${FPST_MLKEM_NATIVE_MONOLITHIC}")
    target_include_directories(fpst_mlkem_native_reference PRIVATE
        "${FPST_MLKEM_NATIVE_API_DIR}"
        "${CMAKE_CURRENT_SOURCE_DIR}/include")
    target_compile_definitions(fpst_mlkem_native_reference PRIVATE
        MLK_CONFIG_FILE=\"fpst_mlkem512_reference_config.h\")

    add_executable(test_mlkem_native_wrapper
        tests/test_mlkem_native_wrapper.c
        tests/mlkem_reference_randombytes_forbidden.c
        tests/mlkem_session_zeroize_mock.c
        tests/mlkem_session_pair_link_mock.c
        src/fpst_csprng.c
        src/fpst_mlkem512_lowram.c
        src/fpst_mlkem512_wrapper.c
        src/fpst_mlkem_session.c)
    target_include_directories(test_mlkem_native_wrapper PRIVATE
        include
        "${FPST_MLKEM_NATIVE_API_DIR}")
    target_compile_definitions(test_mlkem_native_wrapper PRIVATE
        FPST_MLKEM_NATIVE_ENABLED=1
        MLK_CONFIG_FILE=\"fpst_mlkem512_config.h\")
    target_compile_options(test_mlkem_native_wrapper PRIVATE
        -Wall -Wextra -Werror -Wpedantic)
    target_link_libraries(test_mlkem_native_wrapper PRIVATE
        fpst_mlkem_native_upstream
        fpst_mlkem_native_reference)

    add_executable(test_mlkem_memory_preflight
        tests/test_mlkem_memory_preflight.c)
    target_link_libraries(test_mlkem_memory_preflight PRIVATE fpst_firmware_core)
    target_compile_options(test_mlkem_memory_preflight PRIVATE
        -Wall -Wextra -Werror -Wpedantic)
endif()

add_executable(test_firmware_core tests/test_firmware_core.c)
target_link_libraries(test_firmware_core PRIVATE fpst_firmware_core)
target_compile_options(test_firmware_core PRIVATE -Wall -Wextra -Werror -Wpedantic)

add_executable(test_primer_pair tests/test_primer_pair.c)
target_link_libraries(test_primer_pair PRIVATE fpst_firmware_core)
target_compile_options(test_primer_pair PRIVATE -Wall -Wextra -Werror -Wpedantic)

add_executable(test_primer_pair_routed tests/test_primer_pair_routed.c)
target_link_libraries(test_primer_pair_routed PRIVATE fpst_firmware_core)
target_compile_options(test_primer_pair_routed PRIVATE -Wall -Wextra -Werror -Wpedantic)

add_executable(test_entropy_rng tests/test_entropy_rng.c)
target_link_libraries(test_entropy_rng PRIVATE fpst_firmware_core)
target_compile_options(test_entropy_rng PRIVATE -Wall -Wextra -Werror -Wpedantic)

add_executable(test_telemetry tests/test_telemetry.c)
target_link_libraries(test_telemetry PRIVATE fpst_firmware_core)
target_compile_options(test_telemetry PRIVATE -Wall -Wextra -Werror -Wpedantic)

add_executable(test_heartbeat_gate tests/test_heartbeat_gate.c)
target_link_libraries(test_heartbeat_gate PRIVATE fpst_firmware_core)
target_compile_options(test_heartbeat_gate PRIVATE -Wall -Wextra -Werror -Wpedantic)

add_executable(test_mlkem_session_sink
    tests/test_mlkem_session_sink.c
    tests/mlkem_session_pair_link_mock.c
    src/fpst_csprng.c
    src/fpst_mlkem_session.c)
target_include_directories(test_mlkem_session_sink PRIVATE include)
target_compile_options(test_mlkem_session_sink PRIVATE -Wall -Wextra -Werror -Wpedantic)

enable_testing()
add_test(NAME firmware_core COMMAND test_firmware_core)
add_test(NAME primer_pair COMMAND test_primer_pair)
add_test(NAME primer_pair_routed COMMAND test_primer_pair_routed)
add_test(NAME entropy_rng COMMAND test_entropy_rng)
add_test(NAME telemetry COMMAND test_telemetry)
add_test(NAME heartbeat_gate COMMAND test_heartbeat_gate)
add_test(NAME mlkem_session_sink COMMAND test_mlkem_session_sink)
if(FPST_ENABLE_MLKEM_NATIVE)
    add_test(NAME mlkem_native_wrapper COMMAND test_mlkem_native_wrapper)
    add_test(NAME mlkem_memory_preflight COMMAND test_mlkem_memory_preflight)
endif()
