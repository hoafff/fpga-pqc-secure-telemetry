/* Reuse the endpoint model from the independent-link pair regression. */
#define main fpst_independent_pair_test_main
#include "test_primer_pair.c"
#undef main

static void test_routed_shared_link(void) {
    pair_mock_t p1;
    pair_mock_t p2;
    fpst_platform_t p1_platform;
    fpst_platform_t p2_platform;
    fpst_fpga_link_t shared_link;
    fpst_session_manager_t session;
    fpst_pair_bridge_t bridge;

    setup_platform(&p1, MOCK_PRIMER1_TX, &p1_platform);
    setup_platform(&p2, MOCK_PRIMER2_RX, &p2_platform);
    assert(fpst_fpga_link_init(&shared_link, &p1_platform) == FPST_OK);
    assert(fpst_session_init(&session, &shared_link) == FPST_OK);
    assert(fpst_pair_bridge_init_routed(&bridge, &session,
                                        &p1_platform, &p2_platform) == FPST_OK);

    uint8_t shared_secret[FPST_SHARED_SECRET_BYTES];
    for (size_t i = 0u; i < sizeof(shared_secret); ++i)
        shared_secret[i] = (uint8_t)(0x91u ^ (uint8_t)i);
    const uint32_t session_id = 0x55667788u;

    assert(fpst_session_establish_pair_routed(&session,
                                               &p1_platform, &p2_platform,
                                               shared_secret, session_id) == FPST_OK);
    assert(shared_link.platform == &p1_platform);
    assert(p1.session_active && p2.session_active);
    assert(p1.session_id == session_id && p2.session_id == session_id);
    assert(memcmp(p1.active_material, p2.active_material,
                  FPST_TX_MATERIAL_BYTES) == 0);
    fpst_secure_zero(shared_secret, sizeof(shared_secret));

    uint8_t sample[FPST_STP_SAMPLE_BYTES];
    for (size_t i = 0u; i < sizeof(sample); ++i)
        sample[i] = (uint8_t)(0x10u + (uint8_t)(3u * i));

    fpst_primer2_rx_result_t result;
    assert(fpst_pair_bridge_send_sample(&bridge, sample, &result) == FPST_OK);
    assert(shared_link.platform == &p1_platform);
    assert(result.commit_accepted && result.sequence == 0u);
    assert(result.plaintext_len == FPST_STP_SAMPLE_BYTES);
    assert(memcmp(result.plaintext, sample, sizeof(sample)) == 0);
    assert(session.next_sequence == 1u && p1.sequence == 1u && p2.sequence == 1u);

    /* Exercise the same lost-ACK reconciliation on the single shared link. */
    p2.lose_next_commit_response = true;
    sample[0] ^= 0xA5u;
    assert(fpst_pair_bridge_send_sample(&bridge, sample, &result) == FPST_OK);
    assert(shared_link.platform == &p1_platform);
    assert(session.next_sequence == 2u && p1.sequence == 2u && p2.sequence == 2u);
    assert(p2.replay_count == 1u);
    assert(result.remote_status == FPST_REMOTE_ERR_REPLAY);
    assert(result.sequence_valid && result.sequence == 2u);

    /* A full outage must remain recoverable through the retained-packet API. */
    p2.drop_rx_requests = true;
    sample[2] ^= 0x5Au;
    assert(fpst_pair_bridge_send_sample(&bridge, sample, &result) ==
           FPST_ERR_TIMEOUT);
    assert(bridge.retained_valid && bridge.retained_sequence == 2u);
    assert(shared_link.platform == &p1_platform);

    p2.drop_rx_requests = false;
    assert(fpst_pair_bridge_retry_retained(&bridge, &result) == FPST_OK);
    assert(!bridge.retained_valid && !p1.retained);
    assert(shared_link.platform == &p1_platform);
    assert(session.next_sequence == 3u && p1.sequence == 3u && p2.sequence == 3u);

    assert(fpst_session_zeroize_pair_routed(&session,
                                             &p1_platform, &p2_platform) == FPST_OK);
    assert(shared_link.platform == &p1_platform);
    assert(!p1.key_valid && !p2.key_valid);
}

int main(void) {
    test_routed_shared_link();
    puts("PASS: SN32 low-RAM routed one-link dual-Primer flow");
    return 0;
}
