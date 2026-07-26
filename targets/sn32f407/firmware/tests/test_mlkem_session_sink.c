#include <assert.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

#include "fpst_mlkem_session.h"

typedef struct {
    bool sink_fail;
    bool zeroize_fail;
    unsigned establish_calls;
    unsigned zeroize_calls;
    unsigned sink_calls;
    uint8_t captured_ct[FPST_MLKEM512_CIPHERTEXT_BYTES];
    uint8_t captured_ss[FPST_MLKEM512_SHARED_SECRET_BYTES];
} sink_test_state_t;

static sink_test_state_t g_state;

static fpst_result_t dummy_rng_fill(void *ctx, uint8_t *out, size_t len) {
    (void)ctx;
    if (len != 0u && out == NULL) return FPST_ERR_ARGUMENT;
    for (size_t i = 0u; i < len; ++i) out[i] = (uint8_t)(0xA0u + (uint8_t)i);
    return FPST_OK;
}

fpst_result_t fpst_mlkem512_bind_primer1(fpst_fpga_link_t *link) {
    return (link != NULL && link->platform != NULL) ? FPST_OK : FPST_ERR_ARGUMENT;
}

void fpst_mlkem512_unbind_primer1(void) {}

fpst_result_t fpst_mlkem512_encaps(
    uint8_t ciphertext[FPST_MLKEM512_CIPHERTEXT_BYTES],
    uint8_t shared_secret[FPST_MLKEM512_SHARED_SECRET_BYTES],
    const uint8_t public_key[FPST_MLKEM512_PUBLIC_KEY_BYTES],
    const fpst_csprng_t *rng) {
    if (ciphertext == NULL || shared_secret == NULL || public_key == NULL ||
        !fpst_csprng_is_valid(rng))
        return FPST_ERR_ARGUMENT;

    uint8_t coin = 0u;
    fpst_result_t rc = fpst_csprng_fill(rng, &coin, 1u);
    if (rc != FPST_OK) return rc;

    for (size_t i = 0u; i < FPST_MLKEM512_CIPHERTEXT_BYTES; ++i)
        ciphertext[i] = (uint8_t)(public_key[i % FPST_MLKEM512_PUBLIC_KEY_BYTES] ^
                                  (uint8_t)i ^ coin);
    for (size_t i = 0u; i < FPST_MLKEM512_SHARED_SECRET_BYTES; ++i)
        shared_secret[i] = (uint8_t)(0x55u ^ public_key[i] ^ coin);
    return FPST_OK;
}

fpst_result_t fpst_mlkem512_encaps_derand(
    uint8_t ciphertext[FPST_MLKEM512_CIPHERTEXT_BYTES],
    uint8_t shared_secret[FPST_MLKEM512_SHARED_SECRET_BYTES],
    const uint8_t public_key[FPST_MLKEM512_PUBLIC_KEY_BYTES],
    const uint8_t coins[FPST_MLKEM512_ENCAP_COINS_BYTES]) {
    fpst_csprng_t rng = {.ctx = NULL, .fill = dummy_rng_fill};
    (void)coins;
    return fpst_mlkem512_encaps(ciphertext, shared_secret, public_key, &rng);
}

fpst_result_t fpst_session_establish(
    fpst_session_manager_t *m,
    const uint8_t shared_secret[FPST_SHARED_SECRET_BYTES],
    uint32_t session_id,
    uint64_t initial_sequence,
    uint32_t policy_flags) {
    if (m == NULL || m->link == NULL || shared_secret == NULL || session_id == 0u ||
        initial_sequence != 0u || policy_flags != 0u)
        return FPST_ERR_ARGUMENT;

    ++g_state.establish_calls;
    memcpy(g_state.captured_ss, shared_secret, sizeof(g_state.captured_ss));

    /* Model a normal generic no-data BTP response. */
    memset(m->link->response_buf, 0xE1,
           FPST_FRAME_HEADER_BYTES + FPST_GENERIC_RESPONSE_BYTES +
               FPST_FRAME_TRAILER_BYTES);

    m->state = FPST_SESSION_ACTIVE;
    m->session_id = session_id;
    m->next_sequence = 0u;
    return FPST_OK;
}

fpst_result_t fpst_session_zeroize(fpst_session_manager_t *m) {
    if (m == NULL) return FPST_ERR_ARGUMENT;
    ++g_state.zeroize_calls;
    m->session_id = 0u;
    m->next_sequence = 0u;
    m->state = g_state.zeroize_fail ? FPST_SESSION_ERROR : FPST_SESSION_NO_KEY;
    return g_state.zeroize_fail ? FPST_ERR_IO : FPST_OK;
}

static fpst_result_t capture_sink(
    void *ctx,
    const uint8_t ciphertext[FPST_MLKEM512_CIPHERTEXT_BYTES],
    size_t len) {
    sink_test_state_t *state = (sink_test_state_t *)ctx;
    if (state == NULL || ciphertext == NULL ||
        len != FPST_MLKEM512_CIPHERTEXT_BYTES)
        return FPST_ERR_ARGUMENT;

    ++state->sink_calls;
    memcpy(state->captured_ct, ciphertext, len);
    return state->sink_fail ? FPST_ERR_IO : FPST_OK;
}

static void fill_public_key(uint8_t pk[FPST_MLKEM512_PUBLIC_KEY_BYTES]) {
    for (size_t i = 0u; i < FPST_MLKEM512_PUBLIC_KEY_BYTES; ++i)
        pk[i] = (uint8_t)(i * 17u + 3u);
}

static void setup(fpst_fpga_link_t *link,
                  fpst_platform_t *platform,
                  fpst_session_manager_t *session,
                  fpst_csprng_t *rng) {
    memset(&g_state, 0, sizeof(g_state));
    memset(link, 0, sizeof(*link));
    memset(platform, 0, sizeof(*platform));
    memset(session, 0, sizeof(*session));

    link->platform = platform;
    session->state = FPST_SESSION_NO_KEY;
    session->link = link;
    rng->ctx = NULL;
    rng->fill = dummy_rng_fill;
}

static void assert_ciphertext_scratch_wiped(const fpst_fpga_link_t *link) {
    const uint8_t *scratch = &link->response_buf[FPST_LINK_MCU_SESSION_PREFIX_BYTES];
    for (size_t i = 0u; i < FPST_MLKEM512_CIPHERTEXT_BYTES; ++i)
        assert(scratch[i] == 0u);
}

static void test_success_keeps_session_and_wipes_scratch(void) {
    fpst_fpga_link_t link;
    fpst_platform_t platform;
    fpst_session_manager_t session;
    fpst_csprng_t rng;
    uint8_t pk[FPST_MLKEM512_PUBLIC_KEY_BYTES];
    uint8_t expected[FPST_MLKEM512_CIPHERTEXT_BYTES];
    uint8_t ss[FPST_MLKEM512_SHARED_SECRET_BYTES];

    setup(&link, &platform, &session, &rng);
    fill_public_key(pk);
    assert(fpst_mlkem512_encaps(expected, ss, pk, &rng) == FPST_OK);

    setup(&link, &platform, &session, &rng);
    assert(fpst_mlkem_session_establish_tx_to_sink(
               &session, pk, 0x11223344u, &rng, capture_sink, &g_state) == FPST_OK);
    assert(g_state.establish_calls == 1u);
    assert(g_state.zeroize_calls == 0u);
    assert(g_state.sink_calls == 1u);
    assert(session.state == FPST_SESSION_ACTIVE);
    assert(session.session_id == 0x11223344u);
    assert(memcmp(g_state.captured_ct, expected, sizeof(expected)) == 0);
    assert_ciphertext_scratch_wiped(&link);
}

static void test_routed_pair_status_response_preserves_ciphertext(void) {
    fpst_fpga_link_t link;
    fpst_platform_t p1_platform;
    fpst_platform_t p2_platform;
    fpst_session_manager_t session;
    fpst_csprng_t rng;
    uint8_t pk[FPST_MLKEM512_PUBLIC_KEY_BYTES];
    uint8_t expected[FPST_MLKEM512_CIPHERTEXT_BYTES];
    uint8_t ss[FPST_MLKEM512_SHARED_SECRET_BYTES];

    setup(&link, &p1_platform, &session, &rng);
    memset(&p2_platform, 0, sizeof(p2_platform));
    fill_public_key(pk);
    assert(fpst_mlkem512_encaps(expected, ss, pk, &rng) == FPST_OK);

    setup(&link, &p1_platform, &session, &rng);
    memset(&p2_platform, 0, sizeof(p2_platform));
    assert(fpst_mlkem_session_establish_pair_routed_to_sink(
               &session, &p1_platform, &p2_platform,
               pk, 0x55667788u, &rng, capture_sink, &g_state) == FPST_OK);

    /* Pair mock writes a 42-byte KEY_STATUS-sized response before the sink. */
    assert(FPST_LINK_MCU_SESSION_CONTROL_MAX_FRAME_BYTES == 42u);
    assert(FPST_LINK_MCU_SESSION_PREFIX_BYTES >= 42u);
    assert(g_state.sink_calls == 1u);
    assert(memcmp(g_state.captured_ct, expected, sizeof(expected)) == 0);
    assert(session.state == FPST_SESSION_ACTIVE);
    assert(session.session_id == 0x55667788u);
    assert(link.platform == &p1_platform);
    assert_ciphertext_scratch_wiped(&link);
}

static void test_sink_failure_rolls_back_session(void) {
    fpst_fpga_link_t link;
    fpst_platform_t platform;
    fpst_session_manager_t session;
    fpst_csprng_t rng;
    uint8_t pk[FPST_MLKEM512_PUBLIC_KEY_BYTES];

    setup(&link, &platform, &session, &rng);
    fill_public_key(pk);
    g_state.sink_fail = true;

    assert(fpst_mlkem_session_establish_tx_to_sink(
               &session, pk, 7u, &rng, capture_sink, &g_state) == FPST_ERR_IO);
    assert(g_state.establish_calls == 1u);
    assert(g_state.sink_calls == 1u);
    assert(g_state.zeroize_calls == 1u);
    assert(session.state == FPST_SESSION_NO_KEY);
    assert(session.session_id == 0u);
}

static void test_zeroize_failure_dominates_sink_failure(void) {
    fpst_fpga_link_t link;
    fpst_platform_t platform;
    fpst_session_manager_t session;
    fpst_csprng_t rng;
    uint8_t pk[FPST_MLKEM512_PUBLIC_KEY_BYTES];

    setup(&link, &platform, &session, &rng);
    fill_public_key(pk);
    g_state.sink_fail = true;
    g_state.zeroize_fail = true;

    assert(fpst_mlkem_session_establish_tx_to_sink(
               &session, pk, 9u, &rng, capture_sink, &g_state) == FPST_ERR_IO);
    assert(g_state.zeroize_calls == 1u);
    assert(session.state == FPST_SESSION_ERROR);
}

int main(void) {
    test_success_keeps_session_and_wipes_scratch();
    test_routed_pair_status_response_preserves_ciphertext();
    test_sink_failure_rolls_back_session();
    test_zeroize_failure_dominates_sink_failure();
    puts("PASS: SN32 ML-KEM ciphertext scratch, routed pair and rollback tests");
    return 0;
}
