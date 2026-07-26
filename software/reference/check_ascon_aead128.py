#!/usr/bin/env python3
"""Independent Ascon-AEAD128 reference checks for RTL verification.

The implementation follows NIST SP 800-232 little-endian byte conversion. The
first directed vectors are copied from the official ascon-c
LWC_AEAD_KAT_128_128.txt file. The final 24/24 vector is the FPST nominal shape
used by the Kiwi Primer 20K board self-test.
"""

MASK64 = (1 << 64) - 1
ASCON_AEAD128_IV = 0x00001000808C0001
ROUND_CONSTANTS = (
    0x3C, 0x2D, 0x1E, 0x0F,
    0xF0, 0xE1, 0xD2, 0xC3,
    0xB4, 0xA5, 0x96, 0x87,
    0x78, 0x69, 0x5A, 0x4B,
)


def rotr64(value: int, amount: int) -> int:
    return ((value >> amount) | (value << (64 - amount))) & MASK64


def ascon_round(state: list[int], round_constant: int) -> list[int]:
    x0, x1, x2, x3, x4 = state
    x2 ^= round_constant

    y0 = (x4 & x1) ^ x3 ^ (x2 & x1) ^ x2 ^ (x1 & x0) ^ x1 ^ x0
    y1 = x4 ^ (x3 & x2) ^ (x3 & x1) ^ x3 ^ (x2 & x1) ^ x2 ^ x1 ^ x0
    y2 = (x4 & x3) ^ x4 ^ x2 ^ x1 ^ MASK64
    y3 = (x4 & x0) ^ x4 ^ (x3 & x0) ^ x3 ^ x2 ^ x1 ^ x0
    y4 = (x4 & x1) ^ x4 ^ x3 ^ (x1 & x0) ^ x1

    return [
        y0 ^ rotr64(y0, 19) ^ rotr64(y0, 28),
        y1 ^ rotr64(y1, 61) ^ rotr64(y1, 39),
        y2 ^ rotr64(y2, 1) ^ rotr64(y2, 6),
        y3 ^ rotr64(y3, 10) ^ rotr64(y3, 17),
        y4 ^ rotr64(y4, 7) ^ rotr64(y4, 41),
    ]


def permutation(state: list[int], rounds: int) -> list[int]:
    current = state
    for index in range(rounds):
        current = ascon_round(
            current,
            ROUND_CONSTANTS[16 - rounds + index],
        )
    return [word & MASK64 for word in current]


def xor_rate_bytes(state: list[int], data: bytes) -> None:
    for index, value in enumerate(data):
        state[index // 8] ^= value << (8 * (index % 8))


def add_padding(state: list[int], valid_bytes: int) -> None:
    state[valid_bytes // 8] ^= 1 << (8 * (valid_bytes % 8))


def encrypt(key: bytes, nonce: bytes, associated_data: bytes, plaintext: bytes) -> bytes:
    if len(key) != 16 or len(nonce) != 16:
        raise ValueError("Ascon-AEAD128 key and nonce must each be 16 bytes")

    key0 = int.from_bytes(key[:8], "little")
    key1 = int.from_bytes(key[8:], "little")
    nonce0 = int.from_bytes(nonce[:8], "little")
    nonce1 = int.from_bytes(nonce[8:], "little")

    state = permutation([ASCON_AEAD128_IV, key0, key1, nonce0, nonce1], 12)
    state[3] ^= key0
    state[4] ^= key1

    if associated_data:
        offset = 0
        while len(associated_data) - offset >= 16:
            block = associated_data[offset:offset + 16]
            state[0] ^= int.from_bytes(block[:8], "little")
            state[1] ^= int.from_bytes(block[8:], "little")
            state = permutation(state, 8)
            offset += 16

        partial = associated_data[offset:]
        xor_rate_bytes(state, partial)
        add_padding(state, len(partial))
        state = permutation(state, 8)

    state[4] ^= 1 << 63

    ciphertext = bytearray()
    offset = 0
    while len(plaintext) - offset >= 16:
        block = plaintext[offset:offset + 16]
        state[0] ^= int.from_bytes(block[:8], "little")
        state[1] ^= int.from_bytes(block[8:], "little")
        ciphertext.extend(state[0].to_bytes(8, "little"))
        ciphertext.extend(state[1].to_bytes(8, "little"))
        state = permutation(state, 8)
        offset += 16

    partial = plaintext[offset:]
    xor_rate_bytes(state, partial)
    rate = state[0].to_bytes(8, "little") + state[1].to_bytes(8, "little")
    ciphertext.extend(rate[:len(partial)])
    add_padding(state, len(partial))

    state[2] ^= key0
    state[3] ^= key1
    state = permutation(state, 12)
    state[3] ^= key0
    state[4] ^= key1

    ciphertext.extend(state[3].to_bytes(8, "little"))
    ciphertext.extend(state[4].to_bytes(8, "little"))
    return bytes(ciphertext)


def check_vector(ad_hex: str, pt_hex: str, expected_hex: str) -> None:
    key = bytes(range(0x00, 0x10))
    nonce = bytes(range(0x10, 0x20))
    result = encrypt(key, nonce, bytes.fromhex(ad_hex), bytes.fromhex(pt_hex))
    expected = bytes.fromhex(expected_hex)
    if result != expected:
        raise SystemExit(
            f"Ascon reference mismatch\nresult  ={result.hex().upper()}\n"
            f"expected={expected.hex().upper()}"
        )


def main() -> None:
    check_vector("", "", "4F9C278211BEC9316BF68F46EE8B2EC6")
    check_vector("30", "", "CCCB674FE18A09A285D6AB11B35675C0")
    check_vector("", "2021", "E8C35A12D2A396E76224F6EE5418F6465197")
    check_vector("30", "2021", "9610D39E0CD43E61F7D01A1B636FD60FB19F")

    key = bytes(range(0x00, 0x10))
    nonce = bytes(range(0x10, 0x20))
    ad = bytes(range(0x30, 0x48))
    plaintext = bytes(range(0x20, 0x38))
    expected = bytes.fromhex(
        "9D29F9D52ADF9470AF4CBCE0A4481AC7FCB1B32976469892"
        "DFEBAF445205EC9B019D022C7042AE59"
    )
    result = encrypt(key, nonce, ad, plaintext)
    if result != expected:
        raise SystemExit("FPST 24/24 board vector is stale")

    print("PASS: Ascon-AEAD128 reference matches official KATs and FPST 24/24 vector")


if __name__ == "__main__":
    main()
