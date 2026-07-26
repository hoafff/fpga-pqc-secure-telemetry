#include "fpst_sn32f407_port.h"
#include "fpst_crc32.h"
#include "fpst_fpga_link.h"
#include "fpst_mlkem_session.h"
#include "fpst_pair_bridge.h"
#include "fpst_primer1.h"
#include "fpst_primer2.h"
#include "fpst_profile.h"
#include "fpst_session.h"
#include "fpst_telemetry.h"

#include <SN32F400.h>

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <string.h>

typedef enum {
    FPST_HOST_COMMAND_MODE = 0,
    FPST_HOST_KEM_PUBLIC_KEY_HEX_MODE
} fpst_host_input_mode_t;

/*
 * The final two-Primer image deliberately keeps only one fpst_fpga_link_t.
 * Synchronous BTP transactions rebind this buffer set between P1 and P2.
 */
static fpst_platform_t g_platform_p1;
static fpst_platform_t g_platform_p2;
static fpst_fpga_link_t g_link;
static fpst_session_manager_t g_session;
static fpst_pair_bridge_t g_bridge;
static fpst_csprng_t g_csprng;
static fpst_telemetry_source_t g_telemetry;
static bool g_link_initialized;
static bool g_rng_initialized;

/* Public ML-KEM material is static to protect the Cortex-M0 stack. */
static uint8_t g_receiver_public_key[FPST_MLKEM512_PUBLIC_KEY_BYTES];
static fpst_host_input_mode_t g_input_mode;
static uint32_t g_pending_session_id;
static uint32_t g_pending_public_key_crc;
static size_t g_public_key_bytes;
static int8_t g_public_key_high_nibble;

static void console(const char *s) {
    fpst_sn32f407_uart0_write_cstr(s);
}

static void console_hex_nibble(uint8_t value) {
    const uint8_t digit = value < 10u
                              ? (uint8_t)((uint8_t)'0' + value)
                              : (uint8_t)((uint8_t)'A' + value - 10u);
    fpst_sn32f407_uart0_write(&digit, 1u);
}

static void console_hex8(uint8_t value) {
    console_hex_nibble((uint8_t)(value >> 4));
    console_hex_nibble((uint8_t)(value & 0x0Fu));
}

static void console_hex16(uint16_t value) {
    for (int shift = 12; shift >= 0; shift -= 4)
        console_hex_nibble((uint8_t)((value >> shift) & 0x0Fu));
}

static void console_hex32(uint32_t value) {
    for (int shift = 28; shift >= 0; shift -= 4)
        console_hex_nibble((uint8_t)((value >> shift) & 0x0Fu));
}

static void console_hex64(uint64_t value) {
    console_hex32((uint32_t)(value >> 32));
    console_hex32((uint32_t)value);
}

static int hex_value(char ch) {
    if (ch >= '0' && ch <= '9') return ch - '0';
    if (ch >= 'a' && ch <= 'f') return ch - 'a' + 10;
    if (ch >= 'A' && ch <= 'F') return ch - 'A' + 10;
    return -1;
}

static bool parse_hex32_exact(const char *text, uint32_t *out) {
    if (text == NULL || out == NULL) return false;
    uint32_t value = 0u;
    for (unsigned i = 0u; i < 8u; ++i) {
        const int nibble = hex_value(text[i]);
        if (nibble < 0) return false;
        value = (value << 4) | (uint32_t)nibble;
    }
    if (text[8] != '\0' && text[8] != ' ') return false;
    *out = value;
    return true;
}

static fpst_result_t bind_p1(void) {
    return fpst_fpga_link_rebind(&g_link, &g_platform_p1);
}

static fpst_result_t bind_p2(void) {
    return fpst_fpga_link_rebind(&g_link, &g_platform_p2);
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
        console("ERR code=0x");
        console_hex32((uint32_t)rc);
        console("\r\n");
    }
}

static bool require_link(void) {
    if (g_link_initialized) return true;
    console("BLOCKED: two-Primer harness is not verified/initialized.\r\n");
    return false;
}

static bool require_rng(void) {
    if (g_rng_initialized && fpst_sn32f407_csprng_ready()) return true;
    console("BLOCKED: conditioned ADC entropy is not ready.\r\n");
    return false;
}

static void report_rng(void) {
    console(g_rng_initialized && fpst_sn32f407_csprng_ready()
                ? "rng=ADC_P20-conditioned READY (research/competition)\r\n"
                : "rng=BLOCKED; check ADC_P20/potentiometer entropy\r\n");
}

static void reset_public_key_input(void) {
    fpst_secure_zero(g_receiver_public_key, sizeof(g_receiver_public_key));
    g_public_key_bytes = 0u;
    g_public_key_high_nibble = -1;
    g_pending_session_id = 0u;
    g_pending_public_key_crc = 0u;
    g_input_mode = FPST_HOST_COMMAND_MODE;
}

static fpst_result_t uart_ciphertext_sink(
    void *ctx,
    const uint8_t ciphertext[FPST_MLKEM512_CIPHERTEXT_BYTES],
    size_t len) {
    if (ciphertext == NULL || len != FPST_MLKEM512_CIPHERTEXT_BYTES)
        return FPST_ERR_ARGUMENT;

    const uint32_t session_id = ctx != NULL ? *(const uint32_t *)ctx : 0u;
    const uint32_t crc = fpst_crc32_iso_hdlc(ciphertext, len);

    console("KEM_CT_BEGIN session=0x");
    console_hex32(session_id);
    console(" len=0x");
    console_hex16((uint16_t)len);
    console(" crc32=0x");
    console_hex32(crc);
    console("\r\nKEM_CT_HEX=");
    for (size_t i = 0u; i < len; ++i) console_hex8(ciphertext[i]);
    console("\r\nKEM_CT_END\r\n");
    return FPST_OK;
}

static void abort_public_key_input(const char *reason) {
    console("\r\nKEM_PK_ABORT: ");
    console(reason);
    console("\r\n");
    reset_public_key_input();
    console("> ");
}

static void finish_public_key_input(void) {
    const uint32_t actual_crc = fpst_crc32_iso_hdlc(
        g_receiver_public_key, sizeof(g_receiver_public_key));
    if (actual_crc != g_pending_public_key_crc) {
        console("\r\nKEM_PK_CRC_FAIL expected=0x");
        console_hex32(g_pending_public_key_crc);
        console(" actual=0x");
        console_hex32(actual_crc);
        console("\r\n");
        reset_public_key_input();
        console("> ");
        return;
    }

    console("\r\nKEM_PK_OK; establishing ML-KEM-512 P1-TX/P2-RX session...\r\n");
    uint32_t session_id = g_pending_session_id;
    fpst_result_t rc = fpst_mlkem_session_establish_pair_routed_to_sink(
        &g_session,
        &g_platform_p1, &g_platform_p2,
        g_receiver_public_key, session_id, &g_csprng,
        uart_ciphertext_sink, &session_id);

    reset_public_key_input();

    if (rc == FPST_OK) {
        console("kem-pair-session=ACTIVE session=0x");
        console_hex32(session_id);
        console(" p1_seq=0 p2_expected=0\r\n");
    } else {
        console("kem-pair-session=FAILED ");
        print_result(rc);
    }
    console("> ");
}

static void consume_public_key_hex_byte(uint8_t ch) {
    if (ch == 0x03u || ch == 0x1Bu) {
        abort_public_key_input("operator abort");
        return;
    }
    if (ch == ' ' || ch == '\t' || ch == '\r' || ch == '\n') return;

    const int nibble = hex_value((char)ch);
    if (nibble < 0) {
        abort_public_key_input("non-hex input");
        return;
    }

    if (g_public_key_high_nibble < 0) {
        g_public_key_high_nibble = (int8_t)nibble;
        return;
    }
    if (g_public_key_bytes >= sizeof(g_receiver_public_key)) {
        abort_public_key_input("public key overflow");
        return;
    }

    g_receiver_public_key[g_public_key_bytes++] =
        (uint8_t)(((uint8_t)g_public_key_high_nibble << 4) | (uint8_t)nibble);
    g_public_key_high_nibble = -1;
    if (g_public_key_bytes == sizeof(g_receiver_public_key))
        finish_public_key_input();
}

static bool begin_kem_session_command(const char *line) {
    static const char prefix[] = "kem-session ";
    if (strncmp(line, prefix, sizeof(prefix) - 1u) != 0) return false;
    if (!require_link() || !require_rng()) return true;

    const char *args = line + sizeof(prefix) - 1u;
    uint32_t session_id = 0u;
    uint32_t public_key_crc = 0u;
    if (!parse_hex32_exact(args, &session_id) || session_id == 0u ||
        args[8] != ' ' || !parse_hex32_exact(&args[9], &public_key_crc) ||
        args[17] != '\0') {
        console("usage: kem-session SSSSSSSS CCCCCCCC\r\n");
        console("  S = nonzero session_id hex, C = CRC32/ISO-HDLC of 800-byte public key\r\n");
        return true;
    }

    reset_public_key_input();
    g_pending_session_id = session_id;
    g_pending_public_key_crc = public_key_crc;
    g_input_mode = FPST_HOST_KEM_PUBLIC_KEY_HEX_MODE;
    console("KEM_PK_READY bytes=800 encoding=hex; send exactly 1600 hex digits; ESC/Ctrl-C aborts\r\n");
    return true;
}

static void handle_discover(void) {
    if (!require_link()) return;

    char id1[FPST_PRIMER1_DEVICE_ID_BYTES + 1u];
    char id2[FPST_PRIMER2_DEVICE_ID_BYTES + 1u];
    uint32_t state1 = 0u;
    uint32_t state2 = 0u;

    fpst_result_t rc = bind_p1();
    if (rc == FPST_OK) rc = fpst_primer1_get_device_id(&g_link, id1);
    if (rc == FPST_OK) rc = fpst_primer1_get_status(&g_link, &state1);
    if (rc == FPST_OK) rc = bind_p2();
    if (rc == FPST_OK) rc = fpst_primer2_get_device_id(&g_link, id2);
    if (rc == FPST_OK) rc = fpst_primer2_get_status(&g_link, &state2);
    (void)bind_p1();

    if (rc != FPST_OK) {
        print_result(rc);
        return;
    }

    console("primer1="); console(id1); console(" state=0x"); console_hex32(state1);
    console(" primer2="); console(id2); console(" state=0x"); console_hex32(state2);
    console("\r\n");
}

static void handle_selftest(void) {
    if (!require_link()) return;
    static const uint8_t p1_token[] = {'P','1','T','E','S','T'};
    static const uint8_t p2_token[] = {'P','2','T','E','S','T'};

    fpst_result_t rc = bind_p1();
    if (rc == FPST_OK) rc = fpst_primer1_ping(&g_link, p1_token, sizeof(p1_token));
    if (rc == FPST_OK) rc = bind_p2();
    if (rc == FPST_OK) rc = fpst_primer2_ping(&g_link, p2_token, sizeof(p2_token));
    (void)bind_p1();

    console(rc == FPST_OK ? "selftest-pair=PASS\r\n" : "selftest-pair=FAIL ");
    if (rc != FPST_OK) print_result(rc);
}

static void handle_telemetry(void) {
    if (!require_link()) return;
    if (g_session.state != FPST_SESSION_ACTIVE) {
        console("BLOCKED: no active P1/P2 session\r\n");
        return;
    }

    uint16_t adc = 0u;
    fpst_result_t rc = fpst_sn32f407_adc_read(&adc);
    uint8_t sample[FPST_STP_SAMPLE_BYTES];
    if (rc == FPST_OK) {
        rc = fpst_telemetry_build_adc_demo(&g_telemetry,
                                            fpst_sn32f407_uptime_ms64(),
                                            adc, sample);
    }

    fpst_primer2_rx_result_t result;
    if (rc == FPST_OK)
        rc = fpst_pair_bridge_send_sample(&g_bridge, sample, &result);
    fpst_secure_zero(sample, sizeof(sample));

    if (rc != FPST_OK) {
        print_result(rc);
        return;
    }

    console("telemetry=COMMITTED seq=0x");
    console_hex64(g_session.next_sequence - 1u);
    console(" plaintext_len=0x");
    console_hex16(result.plaintext_len);
    console(" receiver_status=0x");
    console_hex16(result.remote_status);
    console("\r\n");
    fpst_secure_zero(&result, sizeof(result));
}

static void handle_key_status(bool primer2) {
    if (!require_link()) return;
    fpst_result_t rc;
    if (!primer2) {
        fpst_primer1_key_status_t status;
        rc = bind_p1();
        if (rc == FPST_OK) rc = fpst_primer1_key_status(&g_link, &status);
        if (rc == FPST_OK) {
            console("p1 session=0x"); console_hex32(status.session_id);
            console(" tx_seq=0x"); console_hex64(status.tx_sequence);
            console(status.session_active ? " active=1\r\n" : " active=0\r\n");
        }
    } else {
        fpst_primer2_key_status_t status;
        rc = bind_p2();
        if (rc == FPST_OK) rc = fpst_primer2_key_status(&g_link, &status);
        (void)bind_p1();
        if (rc == FPST_OK) {
            console("p2 session=0x"); console_hex32(status.session_id);
            console(" expected=0x"); console_hex64(status.expected_sequence);
            console(status.session_active ? " active=1\r\n" : " active=0\r\n");
        }
    }
    if (rc != FPST_OK) print_result(rc);
}

static void handle_rx_counters(void) {
    if (!require_link()) return;
    fpst_primer2_counters_t counters;
    fpst_result_t rc = bind_p2();
    if (rc == FPST_OK) rc = fpst_primer2_get_counters(&g_link, &counters);
    (void)bind_p1();
    if (rc != FPST_OK) {
        print_result(rc);
        return;
    }
    console("rx accepted=0x"); console_hex32(counters.accepted);
    console(" replay=0x"); console_hex32(counters.replay);
    console(" auth_fail=0x"); console_hex32(counters.auth_fail);
    console(" expected=0x"); console_hex64(counters.expected_sequence);
    console("\r\n");
}

static void handle_command(const char *line) {
    if (begin_kem_session_command(line)) return;

    if (strcmp(line, "help") == 0) {
        console("help wiring adc rng-status rng-reseed ping ping2 discover selftest id id2 status status2 key-status key-status2 pqc-status rx-counters telemetry fault zeroize kem-session\r\n");
        console("kem-session SSSSSSSS CCCCCCCC -> provision P1 TX + P2 RX atomically\r\n");
        return;
    }
    if (strcmp(line, "wiring") == 0) {
        console(fpst_sn32f407_link_wiring_verified()
                    ? "wiring=verified-two-primer\r\n"
                    : "wiring=UNVERIFIED\r\n");
        return;
    }
    if (strcmp(line, "adc") == 0) {
        uint16_t value = 0u;
        const fpst_result_t rc = fpst_sn32f407_adc_read(&value);
        if (rc == FPST_OK) {
            console("ADC_P20=0x"); console_hex16(value); console("\r\n");
        } else print_result(rc);
        return;
    }
    if (strcmp(line, "rng-status") == 0) { report_rng(); return; }
    if (strcmp(line, "rng-reseed") == 0) {
        fpst_sn32f407_csprng_zeroize();
        memset(&g_csprng, 0, sizeof(g_csprng));
        g_rng_initialized = fpst_sn32f407_csprng_init(&g_csprng) == FPST_OK;
        report_rng();
        return;
    }
    if (strcmp(line, "ping") == 0 || strcmp(line, "ping2") == 0) {
        if (!require_link()) return;
        static const uint8_t token[] = {'S','N','3','2'};
        const bool p2 = strcmp(line, "ping2") == 0;
        fpst_result_t rc = p2 ? bind_p2() : bind_p1();
        if (rc == FPST_OK)
            rc = p2 ? fpst_primer2_ping(&g_link, token, sizeof(token))
                    : fpst_primer1_ping(&g_link, token, sizeof(token));
        (void)bind_p1();
        print_result(rc);
        return;
    }
    if (strcmp(line, "discover") == 0) { handle_discover(); return; }
    if (strcmp(line, "selftest") == 0) { handle_selftest(); return; }

    if (strcmp(line, "id") == 0 || strcmp(line, "id2") == 0) {
        if (!require_link()) return;
        const bool p2 = strcmp(line, "id2") == 0;
        char id[FPST_PRIMER1_DEVICE_ID_BYTES + 1u];
        fpst_result_t rc = p2 ? bind_p2() : bind_p1();
        if (rc == FPST_OK)
            rc = p2 ? fpst_primer2_get_device_id(&g_link, id)
                    : fpst_primer1_get_device_id(&g_link, id);
        (void)bind_p1();
        if (rc == FPST_OK) { console(p2 ? "device2=" : "device1="); console(id); console("\r\n"); }
        else print_result(rc);
        return;
    }

    if (strcmp(line, "status") == 0 || strcmp(line, "status2") == 0) {
        if (!require_link()) return;
        const bool p2 = strcmp(line, "status2") == 0;
        uint32_t state = 0u;
        fpst_result_t rc = p2 ? bind_p2() : bind_p1();
        if (rc == FPST_OK)
            rc = p2 ? fpst_primer2_get_status(&g_link, &state)
                    : fpst_primer1_get_status(&g_link, &state);
        (void)bind_p1();
        if (rc == FPST_OK) { console(p2 ? "state2=0x" : "state1=0x"); console_hex32(state); console("\r\n"); }
        else print_result(rc);
        return;
    }

    if (strcmp(line, "key-status") == 0) { handle_key_status(false); return; }
    if (strcmp(line, "key-status2") == 0) { handle_key_status(true); return; }
    if (strcmp(line, "pqc-status") == 0) {
        if (!require_link()) return;
        fpst_primer1_pqc_status_t status;
        fpst_result_t rc = bind_p1();
        if (rc == FPST_OK) rc = fpst_primer1_pqc_get_result(&g_link, &status);
        if (rc == FPST_OK) console(status.busy ? "pqc=busy\r\n" : "pqc=idle\r\n");
        else print_result(rc);
        return;
    }
    if (strcmp(line, "rx-counters") == 0) { handle_rx_counters(); return; }
    if (strcmp(line, "telemetry") == 0) { handle_telemetry(); return; }

    if (strcmp(line, "fault") == 0) {
        console("session_state=0x"); console_hex16((uint16_t)g_session.state);
        console(" last_status=0x"); console_hex16(g_link.last_remote_status);
        console(" last_detail=0x"); console_hex16(g_link.last_remote_detail);
        console("\r\n");
        return;
    }

    if (strcmp(line, "zeroize") == 0) {
        if (!require_link()) return;
        const fpst_result_t rc = fpst_session_zeroize_pair_routed(
            &g_session, &g_platform_p1, &g_platform_p2);
        fpst_pair_bridge_forget_local_copy(&g_bridge);
        fpst_sn32f407_csprng_zeroize();
        memset(&g_csprng, 0, sizeof(g_csprng));
        g_rng_initialized = false;
        reset_public_key_input();
        print_result(rc);
        return;
    }

    console("UNKNOWN\r\n");
}

int main(void) {
    SystemInit();
    SystemCoreClockUpdate();

    fpst_result_t rc = fpst_sn32f407_platform_pair_init(
        &g_platform_p1, &g_platform_p2);
    if (rc != FPST_OK) {
        while (1) __WFI();
    }

    reset_public_key_input();
    console("\r\nFPST SN32F407F dual-Primer control firmware\r\n");
    console("baseline=FPST-SYS-SPEC-001-v1.1 P1-TX/P2-RX shared-SPI\r\n");
    console("host=UART0-115200 link=SPI0-1MHz-mode0 CS1=P2.1 CS2=P2.2\r\n");
    console("memory=single-shared-BTP-link low-RAM profile\r\n");

    fpst_telemetry_source_init(&g_telemetry, 1u);
    memset(&g_csprng, 0, sizeof(g_csprng));
    g_rng_initialized = fpst_sn32f407_csprng_init(&g_csprng) == FPST_OK;
    report_rng();

    if (!fpst_sn32f407_link_wiring_verified()) {
        console("WARNING: two-Primer harness is not continuity-verified.\r\n");
        console("BTP SPI transactions are intentionally blocked.\r\n");
        g_link_initialized = false;
        memset(&g_session, 0, sizeof(g_session));
        g_session.state = FPST_SESSION_NO_KEY;
    } else {
        rc = fpst_fpga_link_init(&g_link, &g_platform_p1);
        if (rc == FPST_OK) rc = fpst_session_init(&g_session, &g_link);
        if (rc == FPST_OK) rc = fpst_pair_bridge_init_routed(
            &g_bridge, &g_session, &g_platform_p1, &g_platform_p2);
        g_link_initialized = rc == FPST_OK;
        console(g_link_initialized ? "pair-link-init=OK\r\n" : "pair-link-init=ERR\r\n");
    }

    console("type 'help' followed by Enter\r\n> ");

    char line[48];
    size_t used = 0u;
    for (;;) {
        uint8_t ch;
        if (fpst_sn32f407_uart0_read_byte(&ch)) {
            if (g_input_mode == FPST_HOST_KEM_PUBLIC_KEY_HEX_MODE) {
                consume_public_key_hex_byte(ch);
            } else if (ch == '\r' || ch == '\n') {
                if (used != 0u) {
                    line[used] = '\0';
                    handle_command(line);
                    used = 0u;
                    if (g_input_mode == FPST_HOST_COMMAND_MODE) console("> ");
                }
            } else if (ch == 0x08u || ch == 0x7Fu) {
                if (used != 0u) --used;
            } else if (used + 1u < sizeof(line)) {
                line[used++] = (char)ch;
            }
        }
        if (g_platform_p1.watchdog_feed != NULL)
            g_platform_p1.watchdog_feed(g_platform_p1.ctx);
    }
}
