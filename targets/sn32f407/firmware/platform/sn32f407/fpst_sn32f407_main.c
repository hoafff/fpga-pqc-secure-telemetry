#include "fpst_sn32f407_port.h"
#include "fpst_fpga_link.h"
#include "fpst_session.h"
#include "fpst_profile.h"

#include <SN32F400.h>

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <string.h>

static fpst_platform_t g_platform;
static fpst_fpga_link_t g_link;
static fpst_session_manager_t g_session;
static bool g_link_initialized;

static void console(const char *s) {
    fpst_sn32f407_uart0_write_cstr(s);
}

static void print_result(fpst_result_t rc) {
    if (rc == FPST_OK) {
        console("OK\r\n");
    } else {
        console("ERR\r\n");
    }
}

static fpst_result_t link_simple_command(fpst_opcode_t opcode) {
    uint8_t response[64];
    uint16_t response_len = 0u;
    if (!g_link_initialized) return FPST_ERR_STATE;
    return fpst_fpga_link_command(&g_link, opcode, NULL, 0u,
                                  response, sizeof(response), &response_len,
                                  FPST_LINK_COMMAND_TIMEOUT_MS);
}

static void handle_command(const char *line) {
    if (strcmp(line, "help") == 0) {
        console("help ping caps status zeroize reset wiring\r\n");
        return;
    }
    if (strcmp(line, "wiring") == 0) {
        console(fpst_sn32f407_link_wiring_verified()
                    ? "wiring=verified\r\n"
                    : "wiring=UNVERIFIED\r\n");
        return;
    }
    if (strcmp(line, "ping") == 0) {
        print_result(link_simple_command(FPST_OP_PING));
        return;
    }
    if (strcmp(line, "caps") == 0) {
        print_result(link_simple_command(FPST_OP_GET_CAPS));
        return;
    }
    if (strcmp(line, "status") == 0) {
        print_result(link_simple_command(FPST_OP_GET_STATUS));
        return;
    }
    if (strcmp(line, "zeroize") == 0) {
        if (!g_link_initialized) {
            g_platform.fpga_zeroize(g_platform.ctx,
                                    FPST_LINK_ZEROIZE_PULSE_MS);
            console("OK\r\n");
        } else {
            fpst_session_zeroize(&g_session);
            console("OK\r\n");
        }
        return;
    }
    if (strcmp(line, "reset") == 0) {
        g_platform.fpga_reset(g_platform.ctx, FPST_LINK_RESET_PULSE_MS);
        console("OK\r\n");
        return;
    }

    console("UNKNOWN\r\n");
}

int main(void) {
    SystemInit();
    SystemCoreClockUpdate();

    fpst_result_t rc = fpst_sn32f407_platform_init(&g_platform);
    if (rc != FPST_OK) {
        while (1) {
            __WFI();
        }
    }

    console("\r\nFPST SN32F407F control firmware\r\n");
    console("baseline=FPST-SYS-SPEC-001-v1.1\r\n");
    console("host=UART0-115200 link=SPI0-3MHz-mode0\r\n");

    if (!fpst_sn32f407_link_wiring_verified()) {
        console("WARNING: MCU-to-Primer harness is not yet verified.\r\n");
        console("SPI mailbox commands are intentionally blocked.\r\n");
        g_link_initialized = false;
    } else {
        rc = fpst_fpga_link_init(&g_link, &g_platform);
        if (rc == FPST_OK) rc = fpst_session_init(&g_session, &g_link);
        g_link_initialized = (rc == FPST_OK);
        console(g_link_initialized ? "link-init=OK\r\n" : "link-init=ERR\r\n");
    }

    console("type 'help' followed by Enter\r\n> ");

    char line[40];
    size_t used = 0u;
    for (;;) {
        uint8_t ch;
        if (fpst_sn32f407_uart0_read_byte(&ch)) {
            if (ch == '\r' || ch == '\n') {
                if (used != 0u) {
                    line[used] = '\0';
                    handle_command(line);
                    used = 0u;
                    console("> ");
                }
            } else if (ch == 0x08u || ch == 0x7Fu) {
                if (used != 0u) --used;
            } else if (used + 1u < sizeof(line)) {
                line[used++] = (char)ch;
            }
        }
        if (g_platform.watchdog_feed != NULL) {
            g_platform.watchdog_feed(g_platform.ctx);
        }
    }
}
