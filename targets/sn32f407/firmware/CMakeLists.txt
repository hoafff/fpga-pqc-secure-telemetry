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
    src/fpst_transport.c
    src/fpst_platform.c
    src/fpst_fpga_link.c
    src/fpst_primer1.c
    src/fpst_session.c
    src/fpst_csprng.c
    src/fpst_entropy_rng.c
    src/fpst_mlkem512_wrapper.c
    src/fpst_mlkem_session.c)
target_include_directories(fpst_firmware_core PUBLIC include)
target_compile_options(fpst_firmware_core PRIVATE -Wall -Wextra -Werror -Wpedantic)

if(FPST_ENABLE_MLKEM_NATIVE)
    set(FPST_MLKEM_NATIVE_MONOLITHIC "${FPST_MLKEM_NATIVE_ROOT}/mlkem/mlkem_native.c")
    set(FPST_MLKEM_NATIVE_API_DIR "${FPST_MLKEM_NATIVE_ROOT}/mlkem")
    if(NOT EXISTS "${FPST_MLKEM_NATIVE_MONOLITHIC}")
        message(FATAL_ERROR
            "Pinned mlkem-native source not found. See software/third_party/mlkem-native/LOCK.md")
    endif()

    # Production profile: upstream ML-KEM-512 frontend with the qualified
    # Primer #1 forward-NTT backend hook.
    add_library(fpst_mlkem_native_upstream STATIC "${FPST_MLKEM_NATIVE_MONOLITHIC}")
    target_include_directories(fpst_mlkem_native_upstream PRIVATE
        "${FPST_MLKEM_NATIVE_API_DIR}"
        "${CMAKE_CURRENT_SOURCE_DIR}/include")
    target_compile_definitions(fpst_mlkem_native_upstream PRIVATE
        MLK_CONFIG_FILE=\"fpst_mlkem512_config.h\")

    target_include_directories(fpst_firmware_core PRIVATE "${FPST_MLKEM_NATIVE_API_DIR}")
    target_compile_definitions(fpst_firmware_core PRIVATE FPST_MLKEM_NATIVE_ENABLED=1)
    target_link_libraries(fpst_firmware_core PUBLIC fpst_mlkem_native_upstream)

    # Independent pure-C instance from the exact same upstream revision. It is
    # linked only into the host differential test and never into board firmware.
    add_library(fpst_mlkem_native_reference STATIC "${FPST_MLKEM_NATIVE_MONOLITHIC}")
    target_include_directories(fpst_mlkem_native_reference PRIVATE
        "${FPST_MLKEM_NATIVE_API_DIR}"
        "${CMAKE_CURRENT_SOURCE_DIR}/include")
    target_compile_definitions(fpst_mlkem_native_reference PRIVATE
        MLK_CONFIG_FILE=\"fpst_mlkem512_reference_config.h\")

    add_executable(test_mlkem_native_wrapper
        tests/test_mlkem_native_wrapper.c
        tests/mlkem_reference_randombytes_forbidden.c
        src/fpst_csprng.c
        src/fpst_mlkem512_wrapper.c
        src/fpst_mlkem_session.c)
    target_include_directories(test_mlkem_native_wrapper PRIVATE
        include
        "${FPST_MLKEM_NATIVE_API_DIR}")
    target_compile_definitions(test_mlkem_native_wrapper PRIVATE
        FPST_MLKEM_NATIVE_ENABLED=1)
    target_compile_options(test_mlkem_native_wrapper PRIVATE
        -Wall -Wextra -Werror -Wpedantic)
    target_link_libraries(test_mlkem_native_wrapper PRIVATE
        fpst_mlkem_native_upstream
        fpst_mlkem_native_reference)
endif()

add_executable(test_firmware_core tests/test_firmware_core.c)
target_link_libraries(test_firmware_core PRIVATE fpst_firmware_core)
target_compile_options(test_firmware_core PRIVATE -Wall -Wextra -Werror -Wpedantic)

add_executable(test_entropy_rng tests/test_entropy_rng.c)
target_link_libraries(test_entropy_rng PRIVATE fpst_firmware_core)
target_compile_options(test_entropy_rng PRIVATE -Wall -Wextra -Werror -Wpedantic)

enable_testing()
add_test(NAME firmware_core COMMAND test_firmware_core)
add_test(NAME entropy_rng COMMAND test_entropy_rng)
if(FPST_ENABLE_MLKEM_NATIVE)
    add_test(NAME mlkem_native_wrapper COMMAND test_mlkem_native_wrapper)
endif()
