#include "fpst_sn32f407_port.h"
#include "fpst_fpga_link.h"
#include "fpst_primer1.h"
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

static void console_hex_nibble(uint8_t value) {
    const char digit = (char)(value < 10u ? ('0' + value) : ('A' + value - 10u));
    fpst_sn32f407_uart0_write((const uint8_t *)&digit, 1u);
}

static void console_hex16(uint16_t value) {
    for (int shift = 12; shift >= 0; shift -= 4)
        console_hex_nibble((uint8_t)((value >> shift) & 0x0Fu));
}

static void console_hex32(uint32_t value) {
    for (int shift = 28; shift >= 0; shift -= 4)
        console_hex_nibble((uint8_t)((value >> shift) & 0x0Fu));
}

static void print_result(fpst_result_t rc) {
    if (rc == FPST_OK) {
        console("OK\r\n");
    } else if (rc == FPST_ERR_REMOTE && g_link_initialized) {
        console("REMOTE_ERR status=0x");
        console_hex16(g_link.last_remote_status);
        console(" detail=0x");
        console_hex16(g_link.last_remote_detail);
        console("\r\n");
    } else {
        console("ERR\r\n");
    }
}

static bool require_link(void) {
    if (g_link_initialized) return true;
    console("BLOCKED: Primer #1 harness is not verified/initialized.\r\n");
    return false;
}

static void handle_command(const char *line) {
    if (strcmp(line, "help") == 0) {
        console("help wiring ping id status error key-status pqc-status zeroize reset\r\n");
        return;
    }
    if (strcmp(line, "wiring") == 0) {
        console(fpst_sn32f407_link_wiring_verified()
                    ? "wiring=verified\r\n"
                    : "wiring=UNVERIFIED\r\n");
        return;
    }
    if (strcmp(line, "ping") == 0) {
        if (!require_link()) return;
        static const uint8_t token[] = {'S','N','3','2'};
        print_result(fpst_primer1_ping(&g_link, token, sizeof(token)));
        return;
    }
    if (strcmp(line, "id") == 0) {
        if (!require_link()) return;
        char id[FPST_PRIMER1_DEVICE_ID_BYTES + 1u];
        const fpst_result_t rc = fpst_primer1_get_device_id(&g_link, id);
        if (rc == FPST_OK) {
            console("device=");
            console(id);
            console("\r\n");
        } else {
            print_result(rc);
        }
        return;
    }
    if (strcmp(line, "status") == 0) {
        if (!require_link()) return;
        uint32_t state = 0u;
        const fpst_result_t rc = fpst_primer1_get_status(&g_link, &state);
        if (rc == FPST_OK) {
            console("state=0x");
            console_hex32(state);
            console("\r\n");
        } else {
            print_result(rc);
        }
        return;
    }
    if (strcmp(line, "error") == 0) {
        if (!require_link()) return;
        uint16_t error_code = 0u;
        const fpst_result_t rc = fpst_primer1_get_error(&g_link, &error_code);
        if (rc == FPST_OK) {
            console("error=0x");
            console_hex16(error_code);
            console("\r\n");
        } else {
            print_result(rc);
        }
        return;
    }
    if (strcmp(line, "key-status") == 0) {
        if (!require_link()) return;
        fpst_primer1_key_status_t status;
        const fpst_result_t rc = fpst_primer1_key_status(&g_link, &status);
        if (rc == FPST_OK) {
            console("session_id=0x");
            console_hex32(status.session_id);
            console(status.session_active ? " active=1\r\n" : " active=0\r\n");
        } else {
            print_result(rc);
        }
        return;
    }
    if (strcmp(line, "pqc-status") == 0) {
        if (!require_link()) return;
        fpst_primer1_pqc_status_t status;
        const fpst_result_t rc = fpst_primer1_pqc_get_result(&g_link, &status);
        if (rc == FPST_OK) {
            console(status.busy ? "pqc=busy\r\n" : "pqc=idle\r\n");
        } else {
            print_result(rc);
        }
        return;
    }
    if (strcmp(line, "zeroize") == 0) {
        if (!require_link()) return;
        print_result(fpst_session_zeroize(&g_session));
        return;
    }
    if (strcmp(line, "reset") == 0) {
        console("UNAVAILABLE: Primer reset/zeroize sidebands are supervisor-owned.\r\n");
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
    console("baseline=FPST-SYS-SPEC-001-v1.1 Primer1-BTP-v1\r\n");
    console("host=UART0-115200 link=SPI0-1MHz-mode0-direct-BTP\r\n");

    if (!fpst_sn32f407_link_wiring_verified()) {
        console("WARNING: MCU-to-Primer harness is not yet continuity-verified.\r\n");
        console("BTP SPI transactions are intentionally blocked.\r\n");
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
        if (g_platform.watchdog_feed != NULL)
            g_platform.watchdog_feed(g_platform.ctx);
    }
}
