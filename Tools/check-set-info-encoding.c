#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <smb2/smb2.h>
#include <smb2/libsmb2.h>
#include <smb2/libsmb2-raw.h>
/* Encoded requests are read from the PDU's output vectors; nothing is queued or sent. */
#include "libsmb2-private.h"

/* Every 16-bit word is 0x002f, so a slash conversion that touches the FileId changes it. */
static const smb2_file_id slash_words = {
    0x2f, 0, 0x2f, 0, 0x2f, 0, 0x2f, 0, 0x2f, 0, 0x2f, 0, 0x2f, 0, 0x2f, 0,
};

static int failures, cases;

static void expect(int condition, const char *name, const char *detail)
{
    if (condition) return;
    fprintf(stderr, "%s: %s\n", name, detail);
    failures++;
}

static uint16_t le16(const uint8_t *p) { return (uint16_t)(p[0] | p[1] << 8); }
static uint32_t le32(const uint8_t *p) { return le16(p) | (uint32_t)le16(p + 2) << 16; }
static uint64_t le64(const uint8_t *p) { return le32(p) | (uint64_t)le32(p + 4) << 32; }

static struct smb2_pdu *encode(struct smb2_context *smb, uint8_t file_info_class, void *input)
{
    struct smb2_set_info_request request = {0};
    request.info_type = SMB2_0_INFO_FILE;
    request.file_info_class = file_info_class;
    request.input_data = input;
    memcpy(request.file_id, slash_words, SMB2_FD_SIZE);
    return smb2_cmd_set_info_async(smb, &request, NULL, NULL);
}

static int check_request(const char *name, struct smb2_pdu *pdu, uint8_t file_info_class, uint32_t length)
{
    const struct smb2_io_vectors *out = &pdu->out;
    if (out->niov < 3 || out->iov[0].len != 64 || out->iov[1].len != 32 || out->iov[2].len != length) {
        expect(0, name, "unexpected request vectors");
        return 0;
    }
    expect(out->total_size % 8 == 0, name, "request is not padded to 8 bytes");
    const uint8_t *fixed = out->iov[1].buf;
    expect(le16(fixed) == SMB2_SET_INFO_REQUEST_SIZE, name, "StructureSize changed");
    expect(fixed[2] == SMB2_0_INFO_FILE && fixed[3] == file_info_class, name, "InfoType or class changed");
    expect(le32(fixed + 4) == length, name, "BufferLength differs from the body");
    expect(le16(fixed + 8) == 64 + 32, name, "BufferOffset does not follow the fixed part");
    expect(le16(fixed + 10) == 0 && le32(fixed + 12) == 0, name, "Reserved or AdditionalInformation set");
    expect(!memcmp(fixed + 16, slash_words, SMB2_FD_SIZE), name, "FileId changed");
    return 1;
}

static void check_rename(struct smb2_context *smb, const char *name, const char *utf8,
                         const uint16_t *expected, uint32_t count)
{
    static const uint8_t zero[15];
    struct smb2_file_rename_info info = {.replace_if_exist = 0, .file_name = (const uint8_t *)utf8};
    struct smb2_pdu *pdu = encode(smb, SMB2_FILE_RENAME_INFORMATION, &info);
    cases++;
    expect(pdu != NULL, name, "encoding failed");
    if (!pdu) return;
    if (check_request(name, pdu, SMB2_FILE_RENAME_INFORMATION, 20 + count * 2)) {
        const uint8_t *body = pdu->out.iov[2].buf;
        expect(body[0] == 0, name, "ReplaceIfExists is not false");
        expect(!memcmp(body + 1, zero, sizeof(zero)), name, "Reserved or RootDirectory set");
        expect(le32(body + 16) == count * 2, name, "FileNameLength differs from the name");
        for (uint32_t i = 0; i < count; i++) {
            uint16_t unit = le16(body + 20 + i * 2);
            if (unit == expected[i]) continue;
            fprintf(stderr, "%s: FileName unit %u is 0x%04x, expected 0x%04x\n", name, i, unit, expected[i]);
            failures++;
            break;
        }
    }
    smb2_free_pdu(smb, pdu);
}

static void check_ascii_rename(struct smb2_context *smb, const char *name, const char *path)
{
    uint32_t count = (uint32_t)strlen(path);
    uint16_t *expected = malloc(count * sizeof(uint16_t));
    if (!expected) abort();
    for (uint32_t i = 0; i < count; i++) expected[i] = path[i] == '/' ? '\\' : (uint8_t)path[i];
    check_rename(smb, name, path, expected, count);
    free(expected);
}

static void check_end_of_file(struct smb2_context *smb)
{
    const char *name = "end of file";
    struct smb2_file_end_of_file_info info = {.end_of_file = 0x002f002f0123abcdull};
    struct smb2_pdu *pdu = encode(smb, SMB2_FILE_END_OF_FILE_INFORMATION, &info);
    cases++;
    expect(pdu != NULL, name, "encoding failed");
    if (!pdu) return;
    if (check_request(name, pdu, SMB2_FILE_END_OF_FILE_INFORMATION, 8))
        expect(le64(pdu->out.iov[2].buf) == info.end_of_file, name, "EndOfFile changed");
    smb2_free_pdu(smb, pdu);
}

int main(void)
{
    struct smb2_context *smb = smb2_init_context();
    if (!smb) {
        fputs("could not create an SMB context\n", stderr);
        return 1;
    }

    check_ascii_rename(smb, "short name", "a/b");
    check_ascii_rename(smb, "name covering FileId", "Projects/2026/report final.txt");
    check_ascii_rename(smb, "preconverted name", "Projects\\2026\\report final.txt");

    /* U+012F and U+2F00 hold a 0x2f byte; U+FF0F is a fullwidth solidus. None is '/'. */
    static const uint16_t unicode[] = {
        'R', 0x00e9, 's', 'u', 'm', 0x00e9, '\\', 0x012f, 0x2f00, 0xff0f, '\\',
        0xd83d, 0xde00, ' ', 'x', '\\', 'y', '.', 't', 'x', 't',
    };
    check_rename(smb, "Unicode name", "R\u00e9sum\u00e9/\u012f\u2f00\uff0f/\U0001F600 x\\y.txt",
                 unicode, sizeof(unicode) / sizeof(unicode[0]));

    char long_name[601];
    for (int i = 0; i < 600; i++) long_name[i] = i % 16 == 15 ? '/' : (char)('a' + i % 26);
    long_name[600] = 0;
    check_ascii_rename(smb, "long name", long_name);

    check_end_of_file(smb);

    smb2_destroy_context(smb);
    if (failures) {
        fprintf(stderr, "SET_INFO encoding: %d failures\n", failures);
        return 1;
    }
    printf("SET_INFO encoding: %d cases passed\n", cases);
    return 0;
}
