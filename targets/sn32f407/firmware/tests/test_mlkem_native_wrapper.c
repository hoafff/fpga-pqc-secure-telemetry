#include <assert.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

#include "fpst_mlkem512_wrapper.h"
#include "fpst_mlkem_session.h"
#include "fpst_primer1.h"

/* Pure-C reference instance built from the same pinned mlkem-native v1.0.0. */
int fpst_mlkem512_ref_keypair_derand(
    uint8_t public_key[FPST_MLKEM512_PUBLIC_KEY_BYTES],
    uint8_t secret_key[FPST_MLKEM512_SECRET_KEY_BYTES],
    const uint8_t coins[FPST_MLKEM512_KEYGEN_COINS_BYTES]);
int fpst_mlkem512_ref_enc_derand(
    uint8_t ciphertext[FPST_MLKEM512_CIPHERTEXT_BYTES],
    uint8_t shared_secret[FPST_MLKEM512_SHARED_SECRET_BYTES],
    const uint8_t public_key[FPST_MLKEM512_PUBLIC_KEY_BYTES],
    const uint8_t coins[FPST_MLKEM512_ENCAP_COINS_BYTES]);
int fpst_mlkem512_ref_dec(
    uint8_t shared_secret[FPST_MLKEM512_SHARED_SECRET_BYTES],
    const uint8_t ciphertext[FPST_MLKEM512_CIPHERTEXT_BYTES],
    const uint8_t secret_key[FPST_MLKEM512_SECRET_KEY_BYTES]);

typedef struct {
    uint32_t now_ms;
    uint16_t coeff[FPST_PQC_COEFFICIENTS];
    bool complete;
    uint8_t domain;
    bool done;
    uint8_t last_operation;
    unsigned ntt_calls;
} mlkem_mock_t;

typedef struct {
    const uint8_t *bytes;
    size_t length;
    size_t offset;
    bool fail;
} rng_mock_t;

static mlkem_mock_t g_mock;
static uint8_t g_session_shared_secret[FPST_MLKEM512_SHARED_SECRET_BYTES];
static uint32_t g_session_id;
static unsigned g_session_establish_calls;

static uint32_t mock_millis(void *ctx) {
    return ((mlkem_mock_t *)ctx)->now_ms;
}

static void mock_delay(void *ctx, uint32_t ms) {
    ((mlkem_mock_t *)ctx)->now_ms += ms;
}

static fpst_result_t mock_rng_fill(void *ctx, uint8_t *out, size_t len) {
    rng_mock_t *rng = (rng_mock_t *)ctx;
    if (rng == NULL || (len != 0u && out == NULL)) return FPST_ERR_ARGUMENT;
    if (rng->fail) return FPST_ERR_IO;
    if (rng->offset + len > rng->length) return FPST_ERR_IO;
    if (len != 0u) memcpy(out, &rng->bytes[rng->offset], len);
    rng->offset += len;
    return FPST_OK;
}

static bool all_zero(const uint8_t *data, size_t len) {
    uint8_t aggregate = 0u;
    for (size_t i = 0u; i < len; ++i) aggregate |= data[i];
    return aggregate == 0u;
}

static uint16_t mod_pow(uint16_t base, uint8_t exponent) {
    uint32_t acc = 1u;
    uint32_t x = base;
    uint8_t e = exponent;
    while (e != 0u) {
        if ((e & 1u) != 0u) acc = (acc * x) % FPST_PQC_MODULUS;
        x = (x * x) % FPST_PQC_MODULUS;
        e >>= 1;
    }
    return (uint16_t)acc;
}

static uint8_t bit_reverse7(uint8_t value) {
    uint8_t out = 0u;
    for (unsigned i = 0u; i < 7u; ++i) {
        out = (uint8_t)((out << 1) | (value & 1u));
        value >>= 1;
    }
    return out;
}

/* Canonical standard-domain equivalent of the Primer #1 forward NTT. */
static void mock_forward_ntt(uint16_t a[FPST_PQC_COEFFICIENTS]) {
    uint16_t k = 1u;
    for (uint16_t len = 128u; len >= 2u; len >>= 1) {
        uint16_t start = 0u;
        while (start < FPST_PQC_COEFFICIENTS) {
            const uint16_t zeta = mod_pow(17u, bit_reverse7((uint8_t)k));
            ++k;
            uint16_t j = start;
            for (; j < (uint16_t)(start + len); ++j) {
                const uint16_t t = (uint16_t)(((uint32_t)zeta * a[j + len]) %
                                              FPST_PQC_MODULUS);
                const uint16_t left = a[j];
                a[j] = (uint16_t)(((uint32_t)left + t) % FPST_PQC_MODULUS);
                a[j + len] = (uint16_t)(((uint32_t)left + FPST_PQC_MODULUS - t) %
                                        FPST_PQC_MODULUS);
            }
            start = (uint16_t)(j + len);
        }
    }
    assert(k == 128u);
}

/* The wrapper under test calls these project APIs; this host test models only
 * the exact Primer #1 NTT transaction semantics needed by the native hook. */
fpst_result_t fpst_primer1_pqc_load_poly(fpst_fpga_link_t *link,
                                          const uint16_t *coefficients,
                                          uint16_t count) {
    (void)link;
    if (coefficients == NULL || count != FPST_PQC_COEFFICIENTS)
        return FPST_ERR_ARGUMENT;
    for (uint16_t i = 0u; i < count; ++i) {
        if (coefficients[i] >= FPST_PQC_MODULUS) return FPST_ERR_ARGUMENT;
        g_mock.coeff[i] = coefficients[i];
    }
    g_mock.complete = true;
    g_mock.domain = 1u;
    g_mock.done = false;
    g_mock.last_operation = 0u;
    return FPST_OK;
}

fpst_result_t fpst_primer1_pqc_start_ntt(fpst_fpga_link_t *link) {
    (void)link;
    if (!g_mock.complete || g_mock.domain != 1u) return FPST_ERR_STATE;
    mock_forward_ntt(g_mock.coeff);
    g_mock.domain = 2u;
    g_mock.done = true;
    g_mock.last_operation = 1u;
    ++g_mock.ntt_calls;
    return FPST_OK;
}

fpst_result_t fpst_primer1_pqc_get_result(fpst_fpga_link_t *link,
                                           fpst_primer1_pqc_status_t *status) {
    (void)link;
    if (status == NULL) return FPST_ERR_ARGUMENT;
    memset(status, 0, sizeof(*status));
    status->busy = false;
    status->done_latched = g_mock.done;
    status->domain = g_mock.domain;
    status->polynomial_complete = g_mock.complete;
    status->last_operation = g_mock.last_operation;
    return FPST_OK;
}

fpst_result_t fpst_primer1_pqc_read_poly(fpst_fpga_link_t *link,
                                          uint16_t *coefficients,
                                          uint16_t count) {
    (void)link;
    if (coefficients == NULL || count != FPST_PQC_COEFFICIENTS ||
        !g_mock.complete || g_mock.domain != 2u) {
        return FPST_ERR_STATE;
    }
    memcpy(coefficients, g_mock.coeff, sizeof(g_mock.coeff));
    return FPST_OK;
}

/* Composition-test seam: the real function already has independent BTP/KDF/
 * atomic-commit tests in test_firmware_core. Here we verify that the ML-KEM
 * orchestration passes the exact secret internally and never exposes it in its
 * public result. */
fpst_result_t fpst_session_establish(
    fpst_session_manager_t *m,
    const uint8_t shared_secret[FPST_SHARED_SECRET_BYTES],
    uint32_t session_id,
    uint64_t initial_sequence,
    uint32_t policy_flags) {
    if (m == NULL || shared_secret == NULL || session_id == 0u ||
        initial_sequence != 0u || policy_flags != 0u)
        return FPST_ERR_ARGUMENT;
    memcpy(g_session_shared_secret, shared_secret,
           sizeof(g_session_shared_secret));
    g_session_id = session_id;
    ++g_session_establish_calls;
    m->state = FPST_SESSION_ACTIVE;
    m->session_id = session_id;
    m->next_sequence = 0u;
    return FPST_OK;
}

static void fill_pattern(uint8_t *out, size_t len, uint8_t seed) {
    uint8_t x = seed;
    for (size_t i = 0u; i < len; ++i) {
        x = (uint8_t)(x * 29u + 17u);
        out[i] = (uint8_t)(x ^ (uint8_t)i);
    }
}

static void test_differential_mlkem512(void) {
    static uint8_t keygen_coins[FPST_MLKEM512_KEYGEN_COINS_BYTES];
    static uint8_t encap_coins[FPST_MLKEM512_ENCAP_COINS_BYTES];
    static uint8_t pk_hw[FPST_MLKEM512_PUBLIC_KEY_BYTES];
    static uint8_t pk_ref[FPST_MLKEM512_PUBLIC_KEY_BYTES];
    static uint8_t pk_live[FPST_MLKEM512_PUBLIC_KEY_BYTES];
    static uint8_t sk_hw[FPST_MLKEM512_SECRET_KEY_BYTES];
    static uint8_t sk_ref[FPST_MLKEM512_SECRET_KEY_BYTES];
    static uint8_t sk_live[FPST_MLKEM512_SECRET_KEY_BYTES];
    static uint8_t ct_hw[FPST_MLKEM512_CIPHERTEXT_BYTES];
    static uint8_t ct_ref[FPST_MLKEM512_CIPHERTEXT_BYTES];
    static uint8_t ct_live[FPST_MLKEM512_CIPHERTEXT_BYTES];
    static uint8_t ct_session[FPST_MLKEM512_CIPHERTEXT_BYTES];
    static uint8_t ct_fail[FPST_MLKEM512_CIPHERTEXT_BYTES];
    static uint8_t ss_hw[FPST_MLKEM512_SHARED_SECRET_BYTES];
    static uint8_t ss_ref[FPST_MLKEM512_SHARED_SECRET_BYTES];
    static uint8_t ss_live[FPST_MLKEM512_SHARED_SECRET_BYTES];
    static uint8_t ss_fail[FPST_MLKEM512_SHARED_SECRET_BYTES];
    static uint8_t ss_dec_hw[FPST_MLKEM512_SHARED_SECRET_BYTES];
    static uint8_t ss_dec_ref[FPST_MLKEM512_SHARED_SECRET_BYTES];

    memset(&g_mock, 0, sizeof(g_mock));
    memset(g_session_shared_secret, 0, sizeof(g_session_shared_secret));
    g_session_id = 0u;
    g_session_establish_calls = 0u;
    fill_pattern(keygen_coins, sizeof(keygen_coins), 0x31u);
    fill_pattern(encap_coins, sizeof(encap_coins), 0xA7u);

    fpst_platform_t platform;
    memset(&platform, 0, sizeof(platform));
    platform.ctx = &g_mock;
    platform.millis = mock_millis;
    platform.delay_ms = mock_delay;

    fpst_fpga_link_t link;
    memset(&link, 0, sizeof(link));
    link.platform = &platform;

    assert(fpst_mlkem512_is_available());
    assert(fpst_mlkem512_bind_primer1(&link) == FPST_OK);

    /* Deterministic hooked implementation must match the same upstream source
     * compiled as an independent pure-C backend, byte for byte. */
    assert(fpst_mlkem512_keypair_derand(pk_hw, sk_hw, keygen_coins) == FPST_OK);
    assert(fpst_mlkem512_ref_keypair_derand(pk_ref, sk_ref, keygen_coins) == 0);
    assert(memcmp(pk_hw, pk_ref, sizeof(pk_hw)) == 0);
    assert(memcmp(sk_hw, sk_ref, sizeof(sk_hw)) == 0);

    assert(fpst_mlkem512_encaps_derand(ct_hw, ss_hw, pk_hw, encap_coins) == FPST_OK);
    assert(fpst_mlkem512_ref_enc_derand(ct_ref, ss_ref, pk_ref, encap_coins) == 0);
    assert(memcmp(ct_hw, ct_ref, sizeof(ct_hw)) == 0);
    assert(memcmp(ss_hw, ss_ref, sizeof(ss_hw)) == 0);

    assert(fpst_mlkem512_decaps(ss_dec_hw, ct_hw, sk_hw) == FPST_OK);
    assert(fpst_mlkem512_ref_dec(ss_dec_ref, ct_ref, sk_ref) == 0);
    assert(memcmp(ss_dec_hw, ss_hw, sizeof(ss_hw)) == 0);
    assert(memcmp(ss_dec_ref, ss_ref, sizeof(ss_ref)) == 0);
    assert(memcmp(ss_dec_hw, ss_dec_ref, sizeof(ss_dec_hw)) == 0);

    /* Runtime CSPRNG adapters must produce the same result when the provider
     * yields the same coins, while preserving an explicit failure path. */
    rng_mock_t key_rng_state = {
        .bytes = keygen_coins, .length = sizeof(keygen_coins),
        .offset = 0u, .fail = false
    };
    fpst_csprng_t key_rng = {.ctx = &key_rng_state, .fill = mock_rng_fill};
    assert(fpst_mlkem512_keypair(pk_live, sk_live, &key_rng) == FPST_OK);
    assert(key_rng_state.offset == sizeof(keygen_coins));
    assert(memcmp(pk_live, pk_ref, sizeof(pk_live)) == 0);
    assert(memcmp(sk_live, sk_ref, sizeof(sk_live)) == 0);

    rng_mock_t enc_rng_state = {
        .bytes = encap_coins, .length = sizeof(encap_coins),
        .offset = 0u, .fail = false
    };
    fpst_csprng_t enc_rng = {.ctx = &enc_rng_state, .fill = mock_rng_fill};
    assert(fpst_mlkem512_encaps(ct_live, ss_live, pk_live, &enc_rng) == FPST_OK);
    assert(enc_rng_state.offset == sizeof(encap_coins));
    assert(memcmp(ct_live, ct_ref, sizeof(ct_live)) == 0);
    assert(memcmp(ss_live, ss_ref, sizeof(ss_live)) == 0);

    memset(ct_fail, 0xA5, sizeof(ct_fail));
    memset(ss_fail, 0x5A, sizeof(ss_fail));
    rng_mock_t fail_rng_state = {
        .bytes = encap_coins, .length = sizeof(encap_coins),
        .offset = 0u, .fail = true
    };
    fpst_csprng_t fail_rng = {.ctx = &fail_rng_state, .fill = mock_rng_fill};
    assert(fpst_mlkem512_encaps(ct_fail, ss_fail, pk_live, &fail_rng) == FPST_ERR_IO);
    assert(all_zero(ct_fail, sizeof(ct_fail)));
    assert(all_zero(ss_fail, sizeof(ss_fail)));

    fpst_mlkem512_unbind_primer1();

    /* End-to-end composition boundary: encapsulated secret is handed directly
     * into session establishment while the caller sees only ciphertext. */
    fpst_session_manager_t session;
    memset(&session, 0, sizeof(session));
    session.state = FPST_SESSION_NO_KEY;
    session.link = &link;
    assert(fpst_mlkem_session_establish_tx_derand(
               &session, pk_ref, 0x10203040u, encap_coins, ct_session) == FPST_OK);
    assert(session.state == FPST_SESSION_ACTIVE);
    assert(session.session_id == 0x10203040u);
    assert(g_session_establish_calls == 1u);
    assert(g_session_id == 0x10203040u);
    assert(memcmp(ct_session, ct_ref, sizeof(ct_session)) == 0);
    assert(memcmp(g_session_shared_secret, ss_ref,
                  sizeof(g_session_shared_secret)) == 0);

    assert(g_mock.ntt_calls != 0u);

    fpst_secure_zero(sk_hw, sizeof(sk_hw));
    fpst_secure_zero(sk_ref, sizeof(sk_ref));
    fpst_secure_zero(sk_live, sizeof(sk_live));
    fpst_secure_zero(ss_hw, sizeof(ss_hw));
    fpst_secure_zero(ss_ref, sizeof(ss_ref));
    fpst_secure_zero(ss_live, sizeof(ss_live));
    fpst_secure_zero(ss_dec_hw, sizeof(ss_dec_hw));
    fpst_secure_zero(ss_dec_ref, sizeof(ss_dec_ref));
    fpst_secure_zero(g_session_shared_secret, sizeof(g_session_shared_secret));
}

int main(void) {
    test_differential_mlkem512();
    puts("PASS: mlkem-native v1.0.0 ML-KEM-512 Primer #1 differential/runtime test");
    return 0;
}
