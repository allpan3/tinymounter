/* Modified for TinyMounter, 2026-10-31; see ../README.md. */
/* -*-  mode:c; tab-width:8; c-basic-offset:8; indent-tabs-mode:nil;  -*- */
/*
   Copyright (C) 2019 by Ronnie Sahlberg <ronniesahlberg@gmail.com>

   This program is free software; you can redistribute it and/or modify
   it under the terms of the GNU Lesser General Public License as published by
   the Free Software Foundation; either version 2.1 of the License, or
   (at your option) any later version.

   This program is distributed in the hope that it will be useful,
   but WITHOUT ANY WARRANTY; without even the implied warranty of
   MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
   GNU Lesser General Public License for more details.

   You should have received a copy of the GNU Lesser General Public License
   along with this program; if not, see <http://www.gnu.org/licenses/>.
*/
#ifdef HAVE_CONFIG_H
#include "config.h"
#endif

#ifdef HAVE_STDINT_H
#include <stdint.h>
#endif

#ifdef HAVE_ARPA_INET_H
#include <arpa/inet.h>
#endif 

#include <stdio.h>
#include <string.h>

#include "compat.h"

#include "portable-endian.h"
#include "aes128ccm.h"

#ifdef TINYMOUNTER_CCM_REFERENCE
#include "aes.h"

static void aes_ccm_generate_b0(unsigned char *nonce, size_t nlen,
                                size_t alen, size_t plen, size_t mlen,
                                unsigned char *buf)
{
        uint32_t len;

        memset(buf, 0, 16);
        if (alen) {
                buf[0] |= 0x40;                   /* Adata */
        }
        buf[0] |= (((mlen - 2) / 2) << 3) & 0x38; /* M' */
        buf[0] |= (15 - nlen - 1) & 0x07;         /* L' */

        len = htobe32((uint32_t)plen);
        memcpy(&buf[12], &len, 4);
        memcpy(&buf[1], nonce, nlen);
}

static inline void bxory(unsigned char *b, unsigned char *y, size_t num)
{
        int i;

        for(i = 0; i < (int)num; i++) {
                b[i] = b[i] ^ y[i];
        }
}

static void ccm_generate_T(unsigned char *key,
                           unsigned char *nonce, size_t nlen,
                           unsigned char *aad, size_t alen,
                           unsigned char *p, size_t plen,
                           unsigned char *m, size_t mlen)
{
        unsigned char b[16] _U_, y[16]_U_;
        uint16_t l;

        aes_ccm_generate_b0(nonce, nlen, alen, plen, mlen, &b[0]);
        AES128_ECB_encrypt(b, key, y);

        /* Create Aad */
        if (alen) {
                /* First block */
                memset(b, 0, 16);
                l = htobe16((uint16_t)alen);
                memcpy(b, &l, 2);

                l = (alen > 14) ? 14 : (uint16_t)alen;
                memcpy(&b[2], aad, l);
                aad  += l;
                alen -= l;

                bxory(b, y, 16);
                AES128_ECB_encrypt(b, key, y);

                while (alen) {
                        memset(b, 0, 16);
                        l = (alen > 16) ? 16 : (uint16_t)alen;
                        memcpy(b, aad, l);
                        aad  += l;
                        alen -= l;

                        bxory(b, y, 16);
                        AES128_ECB_encrypt(b, key, y);
                }
        }

        /* Create Payload */
        while (plen) {
                memset(b, 0, 16);
                l = (plen > 16) ? 16 : (uint16_t)plen;
                memcpy(b, p, l);
                p    += l;
                plen -= l;

                bxory(b, y, 16);
                AES128_ECB_encrypt(b, key, y);
        }

        memcpy(m, y, mlen);
}

static void ccm_generate_s(unsigned char *key, unsigned char *nonce, size_t nlen,
                           size_t plen, int i, unsigned char *s)
{
        uint32_t l;

        memset(s, 0, 16);
        s[0] |= (15 - nlen - 1) & 0x07;

        l = htobe32(i);
        memcpy(&s[12], &l, 4);

        memcpy(&s[1], nonce, nlen);

        AES128_ECB_encrypt(s, key, s);
}

static void aes_ccm_crypt(unsigned char *key,
                          unsigned char *nonce, size_t nlen,
                          unsigned char *p, size_t plen)
{
        int j;
        size_t l;
        unsigned char s[16] _U_;

        j = 0;
        while (plen) {
                l = (plen > 16) ? 16 : plen;
                ccm_generate_s(key, nonce, nlen, plen, j + 1, &s[0]);
                bxory(&p[j * 16], &s[0], l);

                j++;
                plen -= l;
        }
}

int aes128ccm_encrypt(unsigned char *key,
                       unsigned char *nonce, size_t nlen,
                       unsigned char *aad, size_t alen,
                       unsigned char *p, size_t plen,
                       unsigned char *m, size_t mlen)
{
        unsigned char s[16] _U_;

        ccm_generate_T(key, nonce, nlen, aad, alen, p, plen, m, mlen);
        ccm_generate_s(key, nonce, nlen, plen, 0, &s[0]);
        bxory(m, &s[0], mlen);

        aes_ccm_crypt(key, nonce, nlen, p, plen);
        return 0;
}

int aes128ccm_decrypt(unsigned char *key,
                      unsigned char *nonce, size_t nlen,
                      unsigned char *aad, size_t alen,
                      unsigned char *p, size_t plen,
                      unsigned char *m, size_t mlen)
{
        unsigned char s[16] _U_;
        unsigned char tmp[16];

        aes_ccm_crypt(key, nonce, nlen, p, plen);

        ccm_generate_T(key, nonce, nlen, aad, alen, p, plen, tmp, mlen);
        ccm_generate_s(key, nonce, nlen, plen, 0, &s[0]);
        bxory(tmp, &s[0], mlen);

        return memcmp(tmp, m, mlen);
}

#else

#include <CommonCrypto/CommonCryptor.h>

static int ccm_valid(unsigned char *key, unsigned char *nonce, size_t nlen,
                     unsigned char *aad, size_t alen, unsigned char *p, size_t plen,
                     unsigned char *m, size_t mlen)
{
        if (!key || !nonce || !m || (alen && !aad) || (plen && !p) ||
            nlen < 7 || nlen > 13 || mlen < 4 || mlen > 16 || (mlen & 1) ||
            alen >= 0xff00 || plen > UINT32_MAX) {
                return 0;
        }
        return nlen <= 11 || plen < ((size_t)1 << (8 * (15 - nlen)));
}

static int ccm_update(CCCryptorRef cryptor, const unsigned char *input, size_t length,
                       unsigned char *output)
{
        size_t moved = 0;

        return CCCryptorUpdate(cryptor, input, length, output, length, &moved) == kCCSuccess &&
               moved == length ? 0 : -1;
}

static int ccm_mac_bytes(CCCryptorRef cryptor, const unsigned char *input, size_t length,
                          unsigned char *tag)
{
        unsigned char output[16384], tail[16] = {0};
        size_t count;

        while (length >= 16) {
                count = length & ~(size_t)15;
                if (count > sizeof(output)) {
                        count = sizeof(output);
                }
                if (ccm_update(cryptor, input, count, output)) {
                        return -1;
                }
                memcpy(tag, output + count - 16, 16);
                input += count;
                length -= count;
        }
        if (length) {
                memcpy(tail, input, length);
                if (ccm_update(cryptor, tail, sizeof(tail), output)) {
                        return -1;
                }
                memcpy(tag, output, 16);
        }
        return 0;
}

static int ccm_mac(unsigned char *key, unsigned char *nonce, size_t nlen,
                    unsigned char *aad, size_t alen, unsigned char *p, size_t plen,
                    unsigned char *tag, size_t mlen)
{
        CCCryptorRef cryptor = NULL;
        unsigned char block[16] = {0};
        size_t length = plen, first;
        int result = -1;

        block[0] = (alen ? 0x40 : 0) | (((mlen - 2) / 2) << 3) | (14 - nlen);
        memcpy(block + 1, nonce, nlen);
        for (size_t i = 15; length; i--, length >>= 8) {
                block[i] = (unsigned char)length;
        }
        if (CCCryptorCreateWithMode(kCCEncrypt, kCCModeCBC, kCCAlgorithmAES,
                                   ccNoPadding, NULL, key, 16, NULL, 0, 0, 0,
                                   &cryptor) != kCCSuccess) {
                return -1;
        }
        if (ccm_mac_bytes(cryptor, block, sizeof(block), tag)) {
                goto out;
        }
        if (alen) {
                memset(block, 0, sizeof(block));
                block[0] = (unsigned char)(alen >> 8);
                block[1] = (unsigned char)alen;
                first = alen < 14 ? alen : 14;
                memcpy(block + 2, aad, first);
                if (ccm_mac_bytes(cryptor, block, sizeof(block), tag) ||
                    ccm_mac_bytes(cryptor, aad + first, alen - first, tag)) {
                        goto out;
                }
        }
        result = ccm_mac_bytes(cryptor, p, plen, tag);
out:
        /* Whole CBC blocks without padding leave no buffered output to finalize. */
        if (CCCryptorRelease(cryptor) != kCCSuccess) {
                result = -1;
        }
        return result;
}

static int ccm_crypt(unsigned char *key, unsigned char *nonce, size_t nlen,
                      unsigned char *p, size_t plen, unsigned char *mask)
{
        CCCryptorRef cryptor = NULL;
        unsigned char counter[16] = {0}, zero[16] = {0};
        int result = -1;

        counter[0] = (unsigned char)(14 - nlen);
        memcpy(counter + 1, nonce, nlen);
        if (CCCryptorCreateWithMode(kCCEncrypt, kCCModeCTR, kCCAlgorithmAES,
                                   ccNoPadding, counter, key, 16, NULL, 0, 0,
                                   kCCModeOptionCTR_BE, &cryptor) != kCCSuccess) {
                return -1;
        }
        /* S0 masks the tag; bounded payload lengths cannot carry into the nonce. */
        if (ccm_update(cryptor, zero, sizeof(zero), mask) == 0 &&
            (!plen || ccm_update(cryptor, p, plen, p) == 0)) {
                result = 0;
        }
        if (CCCryptorRelease(cryptor) != kCCSuccess) {
                result = -1;
        }
        return result;
}

int aes128ccm_encrypt(unsigned char *key, unsigned char *nonce, size_t nlen,
                      unsigned char *aad, size_t alen, unsigned char *p, size_t plen,
                      unsigned char *m, size_t mlen)
{
        unsigned char tag[16], mask[16];

        if (!ccm_valid(key, nonce, nlen, aad, alen, p, plen, m, mlen)) {
                return -1;
        }
        if (ccm_mac(key, nonce, nlen, aad, alen, p, plen, tag, mlen) ||
            ccm_crypt(key, nonce, nlen, p, plen, mask)) {
                if (plen) memset(p, 0, plen);
                memset(m, 0, mlen);
                return -1;
        }
        for (size_t i = 0; i < mlen; i++) {
                m[i] = tag[i] ^ mask[i];
        }
        return 0;
}

int aes128ccm_decrypt(unsigned char *key, unsigned char *nonce, size_t nlen,
                      unsigned char *aad, size_t alen, unsigned char *p, size_t plen,
                      unsigned char *m, size_t mlen)
{
        unsigned char tag[16], mask[16];
        volatile unsigned char difference = 0;

        if (!ccm_valid(key, nonce, nlen, aad, alen, p, plen, m, mlen)) {
                return -1;
        }
        if (ccm_crypt(key, nonce, nlen, p, plen, mask) ||
            ccm_mac(key, nonce, nlen, aad, alen, p, plen, tag, mlen)) {
                goto fail;
        }
        for (size_t i = 0; i < mlen; i++) {
                difference |= tag[i] ^ mask[i] ^ m[i];
        }
        if (difference == 0) {
                return 0;
        }
fail:
        if (plen) memset(p, 0, plen);
        return -1;
}

#endif
