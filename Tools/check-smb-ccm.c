#include <CommonCrypto/CommonCryptor.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <smb2/smb2.h>
#include <smb2/libsmb2.h>
#include <smb2/libsmb2-raw.h>
#include "libsmb2-private.h"
#include "../Vendor/libsmb2/lib/aes128ccm.h"

int reference_encrypt(unsigned char *, unsigned char *, size_t, unsigned char *, size_t,
                      unsigned char *, size_t, unsigned char *, size_t);
int reference_decrypt(unsigned char *, unsigned char *, size_t, unsigned char *, size_t,
                      unsigned char *, size_t, unsigned char *, size_t);

static int failures, cases, api_calls, fail_call, short_call, shortened, live_cryptors;

static CCCryptorStatus checked_create(CCOperation op, CCMode mode, CCAlgorithm algorithm,
    CCPadding padding, const void *iv, const void *key, size_t key_length, const void *tweak,
    size_t tweak_length, int rounds, CCModeOptions options, CCCryptorRef *cryptor)
{
    if (++api_calls == fail_call) return kCCMemoryFailure;
    CCCryptorStatus status = CCCryptorCreateWithMode(op, mode, algorithm, padding, iv, key,
        key_length, tweak, tweak_length, rounds, options, cryptor);
    if (status == kCCSuccess) live_cryptors++;
    return status;
}

static CCCryptorStatus checked_update(CCCryptorRef cryptor, const void *input, size_t length,
                                     void *output, size_t capacity, size_t *moved)
{
    if (++api_calls == fail_call) return kCCDecodeError;
    CCCryptorStatus status = CCCryptorUpdate(cryptor, input, length, output, capacity, moved);
    if (api_calls == short_call && status == kCCSuccess && *moved) {
        --*moved;
        shortened = 1;
    }
    return status;
}

static CCCryptorStatus checked_release(CCCryptorRef cryptor)
{
    CCCryptorStatus status = CCCryptorRelease(cryptor);
    live_cryptors--;
    return ++api_calls == fail_call ? kCCParamError : status;
}

// The built library is the subject; this second copy permits deterministic API failures.
#define CCCryptorCreateWithMode checked_create
#define CCCryptorUpdate checked_update
#define CCCryptorRelease checked_release
#define aes128ccm_encrypt injected_encrypt
#define aes128ccm_decrypt injected_decrypt
#include "../Vendor/libsmb2/lib/aes128ccm.c"
#undef CCCryptorCreateWithMode
#undef CCCryptorUpdate
#undef CCCryptorRelease
#undef aes128ccm_encrypt
#undef aes128ccm_decrypt

static void expect(int condition, const char *detail)
{
    if (condition) return;
    fprintf(stderr, "CCM: %s\n", detail);
    failures++;
}

static int all_zero(const unsigned char *bytes, size_t length)
{
    for (size_t i = 0; i < length; i++) if (bytes[i]) return 0;
    return 1;
}

static void fill(unsigned char *bytes, size_t length, uint32_t seed)
{
    for (size_t i = 0; i < length; i++) {
        seed = seed * 1664525 + 1013904223;
        bytes[i] = (unsigned char)(seed >> 24);
    }
}

static void known_vector(void)
{
    unsigned char key[16], plain[23], data[23], tag[8];
    unsigned char nonce[] = {0, 0, 0, 3, 2, 1, 0, 0xa0, 0xa1, 0xa2, 0xa3, 0xa4, 0xa5};
    unsigned char aad[] = {0, 1, 2, 3, 4, 5, 6, 7};
    // RFC 3610 section 8, packet vector 1, including the independently published tag.
    const unsigned char expected[] = {
        0x58, 0x8c, 0x97, 0x9a, 0x61, 0xc6, 0x63, 0xd2, 0xf0, 0x66, 0xd0, 0xc2,
        0xc0, 0xf9, 0x89, 0x80, 0x6d, 0x5f, 0x6b, 0x61, 0xda, 0xc3, 0x84,
        0x17, 0xe8, 0xd1, 0x2c, 0xfd, 0xf9, 0x26, 0xe0,
    };
    for (size_t i = 0; i < sizeof(key); i++) key[i] = (unsigned char)(0xc0 + i);
    for (size_t i = 0; i < sizeof(plain); i++) plain[i] = (unsigned char)(8 + i);
    memcpy(data, plain, sizeof(data));
    expect(aes128ccm_encrypt(key, nonce, sizeof(nonce), aad, sizeof(aad), data,
                            sizeof(data), tag, sizeof(tag)) == 0, "RFC encrypt failed");
    expect(!memcmp(data, expected, sizeof(data)), "RFC ciphertext differs");
    expect(!memcmp(tag, expected + sizeof(data), sizeof(tag)), "RFC tag differs");
    expect(aes128ccm_decrypt(key, nonce, sizeof(nonce), aad, sizeof(aad), data,
                            sizeof(data), tag, sizeof(tag)) == 0, "RFC decrypt failed");
    expect(!memcmp(data, plain, sizeof(data)), "RFC plaintext differs");
    memcpy(data, plain, sizeof(data));
    reference_encrypt(key, nonce, sizeof(nonce), aad, sizeof(aad), data, sizeof(data), tag,
                      sizeof(tag));
    expect(!memcmp(data, expected, sizeof(data)) &&
           !memcmp(tag, expected + sizeof(data), sizeof(tag)), "portable reference differs from RFC");
    cases++;
}

static void equivalence(size_t plen, size_t alen, size_t nlen, size_t mlen, uint32_t seed)
{
    unsigned char key[16], nonce[13], tag[16], portable_tag[16];
    unsigned char *plain = malloc(plen + 2), *data = malloc(plen + 2);
    unsigned char *portable = malloc(plen + 2), *aad = malloc(alen + 1);
    if (!plain || !data || !portable || !aad) abort();
    fill(key, sizeof(key), seed);
    fill(nonce, sizeof(nonce), seed + 1);
    fill(aad, alen, seed + 2);
    fill(plain, plen + 2, seed + 3);
    memcpy(data, plain, plen + 2);
    memcpy(portable, plain, plen + 2);
    reference_encrypt(key, nonce, nlen, aad, alen, portable + 1, plen, portable_tag, mlen);
    expect(aes128ccm_encrypt(key, nonce, nlen, aad, alen, data + 1, plen, tag, mlen) == 0,
           "equivalence encrypt failed");
    expect(!memcmp(data, portable, plen + 2), "portable ciphertext or boundary differs");
    expect(!memcmp(tag, portable_tag, mlen), "portable tag differs");
    expect(aes128ccm_decrypt(key, nonce, nlen, aad, alen, data + 1, plen, portable_tag, mlen) == 0,
           "portable ciphertext rejected");
    expect(!memcmp(data, plain, plen + 2), "in-place plaintext or boundary differs");
    expect(reference_decrypt(key, nonce, nlen, aad, alen, portable + 1, plen, tag, mlen) == 0,
           "new tag rejected by portable reference");
    expect(!memcmp(portable, plain, plen + 2), "portable plaintext differs");
    free(plain);
    free(data);
    free(portable);
    free(aad);
    cases++;
}

static void equivalence_matrix(void)
{
    const size_t payloads[] = {0, 1, 15, 16, 17, 31, 32, 33, 255, 256, 16383, 16384, 16385};
    const size_t aads[] = {0, 1, 13, 14, 15, 16, 17, 30, 31, 32, 33};
    uint32_t seed = 1;
    for (size_t nlen = 7; nlen <= 13; nlen++) {
        for (size_t mlen = 4; mlen <= 16; mlen += 2) {
            for (size_t p = 0; p < sizeof(payloads) / sizeof(payloads[0]); p++) {
                for (size_t a = 0; a < sizeof(aads) / sizeof(aads[0]); a++) {
                    equivalence(payloads[p], aads[a], nlen, mlen, seed++);
                }
            }
        }
    }
    equivalence(65535, 0xfeff, 13, 16, seed++);
    equivalence(65536, 256, 12, 8, seed++);
    equivalence(1024 * 1024 + 113, 32, 11, 16, seed);
}

static void corruption(void)
{
    unsigned char key[16], nonce[11], aad[32], cipher[65], data[65], tag[16], bad_tag[16];
    fill(key, sizeof(key), 1);
    fill(nonce, sizeof(nonce), 2);
    fill(aad, sizeof(aad), 3);
    fill(cipher, sizeof(cipher), 4);
    expect(aes128ccm_encrypt(key, nonce, 11, aad, 32, cipher, 65, tag, 16) == 0,
           "corruption setup failed");
    for (size_t i = 0; i < sizeof(tag) + sizeof(cipher) + sizeof(aad) + sizeof(nonce); i++) {
        memcpy(data, cipher, sizeof(data));
        memcpy(bad_tag, tag, sizeof(tag));
        size_t j = i;
        unsigned char *changed;
        if (j < sizeof(tag)) changed = bad_tag + j;
        else if ((j -= sizeof(tag)) < sizeof(cipher)) changed = data + j;
        else if ((j -= sizeof(cipher)) < sizeof(aad)) changed = aad + j;
        else changed = nonce + j - sizeof(aad);
        *changed ^= 0x80;
        expect(aes128ccm_decrypt(key, nonce, 11, aad, 32, data, 65, bad_tag, 16) != 0,
               "tampered packet accepted");
        expect(all_zero(data, sizeof(data)), "unauthenticated plaintext retained");
        if (i >= sizeof(tag) + sizeof(cipher)) *changed ^= 0x80;
        cases++;
    }
}

static void invalid_inputs(void)
{
    unsigned char key[16] = {0}, nonce[13] = {0}, aad[32] = {0};
    unsigned char data[16], tag[16];
    struct lengths { size_t nonce, aad, payload, tag; } invalid[] = {
        {6, 32, 16, 16}, {14, 32, 16, 16}, {11, 32, 16, 0}, {11, 32, 16, 3},
        {11, 32, 16, 5}, {11, 32, 16, 18}, {11, 0xff00, 16, 16},
        {13, 32, 65536, 16}, {12, 32, 16777216, 16},
        {11, 32, (size_t)UINT32_MAX + 1, 16}, {SIZE_MAX, SIZE_MAX, SIZE_MAX, SIZE_MAX},
    };
    for (size_t i = 0; i < sizeof(invalid) / sizeof(invalid[0]); i++) {
        struct lengths v = invalid[i];
        memset(data, 0x55, sizeof(data));
        memset(tag, 0x77, sizeof(tag));
        expect(aes128ccm_encrypt(key, nonce, v.nonce, aad, v.aad, data, v.payload, tag, v.tag) != 0,
               "invalid encryption length accepted");
        expect(aes128ccm_decrypt(key, nonce, v.nonce, aad, v.aad, data, v.payload, tag, v.tag) != 0,
               "invalid decryption length accepted");
        expect(data[0] == 0x55 && tag[0] == 0x77, "invalid input modified output");
        cases++;
    }
    for (int i = 0; i < 5; i++) {
        expect(aes128ccm_encrypt(i == 0 ? NULL : key, i == 1 ? NULL : nonce, 11,
               i == 2 ? NULL : aad, 32, i == 3 ? NULL : data, 16, i == 4 ? NULL : tag, 16) != 0,
               "missing encryption buffer accepted");
        expect(aes128ccm_decrypt(i == 0 ? NULL : key, i == 1 ? NULL : nonce, 11,
               i == 2 ? NULL : aad, 32, i == 3 ? NULL : data, 16, i == 4 ? NULL : tag, 16) != 0,
               "missing decryption buffer accepted");
        cases++;
    }
    expect(aes128ccm_encrypt(key, nonce, 11, NULL, 0, NULL, 0, tag, 16) == 0 &&
           aes128ccm_decrypt(key, nonce, 11, NULL, 0, NULL, 0, tag, 16) == 0,
           "empty packet rejected");
    cases++;
}

static void api_failures(void)
{
    unsigned char key[16] = {0}, nonce[11] = {0}, aad[32] = {0};
    unsigned char plain[16401], cipher[16401], data[16401], tag[16], output_tag[16];
    fill(plain, sizeof(plain), 1);
    memcpy(cipher, plain, sizeof(cipher));
    expect(aes128ccm_encrypt(key, nonce, 11, aad, 32, cipher, sizeof(cipher), tag, 16) == 0,
           "API failure setup failed");
    for (int decrypt = 0; decrypt <= 1; decrypt++) {
        api_calls = fail_call = short_call = 0;
        memcpy(data, decrypt ? cipher : plain, sizeof(data));
        int result = decrypt ? injected_decrypt(key, nonce, 11, aad, 32, data, sizeof(data), tag, 16)
                             : injected_encrypt(key, nonce, 11, aad, 32, data, sizeof(data), output_tag, 16);
        int total_calls = api_calls;
        expect(result == 0 && live_cryptors == 0, "injected backend control failed");
        expect(!memcmp(data, decrypt ? plain : cipher, sizeof(data)), "injected control differs");
        for (int call = 1; call <= total_calls; call++) {
            api_calls = 0;
            fail_call = call;
            memcpy(data, decrypt ? cipher : plain, sizeof(data));
            memset(output_tag, 0x77, sizeof(output_tag));
            result = decrypt ? injected_decrypt(key, nonce, 11, aad, 32, data, sizeof(data), tag, 16)
                             : injected_encrypt(key, nonce, 11, aad, 32, data, sizeof(data), output_tag, 16);
            expect(result != 0, "CommonCrypto error accepted");
            expect(all_zero(data, sizeof(data)), "API failure retained payload");
            expect(decrypt || all_zero(output_tag, sizeof(output_tag)), "API failure retained tag");
            expect(live_cryptors == 0, "API failure leaked cryptor");
            cases++;
        }
        fail_call = 0;
        for (int call = 1; call <= total_calls; call++) {
            api_calls = 0;
            short_call = call;
            shortened = 0;
            memcpy(data, decrypt ? cipher : plain, sizeof(data));
            result = decrypt ? injected_decrypt(key, nonce, 11, aad, 32, data, sizeof(data), tag, 16)
                             : injected_encrypt(key, nonce, 11, aad, 32, data, sizeof(data), output_tag, 16);
            expect(live_cryptors == 0, "short output leaked cryptor");
            expect(!shortened || result != 0, "short output accepted");
            if (shortened) {
                expect(all_zero(data, sizeof(data)), "short output retained payload");
                expect(decrypt || all_zero(output_tag, sizeof(output_tag)),
                       "short output retained tag");
            }
            cases++;
        }
        short_call = 0;
    }
}

static void rejected_pdu(struct smb2_context *smb, int status, void *reply, void *context)
{
    expect(status == (int)SMB2_STATUS_INTERNAL_ERROR && reply == NULL, "queue failure not reported");
    expect(smb->outqueue == NULL, "failed encryption entered output queue");
    expect(smb->message_id == 17, "message IDs were not restored before callbacks");
    ++*(int *)context;
}

static void queue_failure(void)
{
    struct smb2_context *smb = smb2_init_context();
    if (!smb) abort();
    smb->seal = 1;
    smb->message_id = 17;
    int callbacks = 0;
    struct smb2_pdu *pdu = smb2_cmd_echo_async(smb, rejected_pdu, &callbacks);
    struct smb2_pdu *next = smb2_cmd_echo_async(smb, rejected_pdu, &callbacks);
    if (!pdu || !next) abort();
    pdu->seal = next->seal = 1;
    pdu->header.credit_charge = 3;
    next->header.credit_charge = 4;
    pdu->next_compound = next;
    // An unrepresentable vector must fail before either the copy or socket queue.
    next->out.iov[1].len = SIZE_MAX;
    smb2_queue_pdu(smb, pdu);
    expect(callbacks == 2, "compound failure did not complete every callback");
    expect(smb->outqueue == NULL && smb->waitqueue == NULL && smb->seal,
           "queue failure changed encryption policy or retained request");
    pdu = smb2_cmd_echo_async(smb, NULL, NULL);
    if (!pdu) abort();
    pdu->seal = 1;
    smb2_queue_pdu(smb, pdu);
    expect(smb->outqueue == pdu && pdu->header.message_id == 17,
           "next request skipped unsent message IDs");
    smb2_destroy_context(smb);
    cases++;
}

int main(void)
{
    known_vector();
    equivalence_matrix();
    corruption();
    invalid_inputs();
    api_failures();
    queue_failure();
    if (failures) {
        fprintf(stderr, "SMB CCM: %d failures in %d cases\n", failures, cases);
        return 1;
    }
    printf("SMB CCM: %d cases passed\n", cases);
    return 0;
}
