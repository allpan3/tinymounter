#include <errno.h>
#include <poll.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <smb2/smb2.h>
#include <smb2/smb2-errors.h>
#include <smb2/libsmb2.h>
#include <smb2/libsmb2-raw.h>
#include "libsmb2-private.h"

enum delivery { reply_ready, poll_failure, service_failure, timeout, reply_then_service_failure };
static enum delivery delivery;
static struct smb2_pdu *queued;
static uint32_t response_status;
static void *response_data;
static int fail_create, clock_calls, destroyed, freed_data;
static int failures, cases;

static void fake_queue(struct smb2_context *smb, struct smb2_pdu *pdu);
static int fake_poll(struct pollfd *fds, nfds_t count, int milliseconds);
static int fake_service(struct smb2_context *smb, int revents);
static int fake_clock(clockid_t clock, struct timespec *value);
static void fake_destroy(void *opaque);
static void fake_free_data(struct smb2_context *smb, void *data);
static struct smb2_pdu *fake_create(struct smb2_context *smb, struct smb2_create_request *request,
                                    smb2_command_cb callback, void *context);
static struct smb2_pdu *fake_set_info(struct smb2_context *smb, struct smb2_set_info_request *request,
                                      smb2_command_cb callback, void *context);
static char sent_name[1100];
static uint32_t sent_disposition, sent_access, sent_sharing, sent_options;
static int inspect_write;
static uint8_t sent_write[48], sent_payload[1024 * 1024];
static uint32_t sent_length;
static struct smb2_file_basic_info sent_basic;
static uint16_t sent_charge;
static int batch_io, queued_requests;
static uint64_t short_at;

// Real request encoders feed deterministic callbacks; no request reaches a socket.
#define smb2_queue_pdu fake_queue
#define poll fake_poll
#define smb2_service fake_service
#define clock_gettime fake_clock
#define tm_smb_destroy_context fake_destroy
#define smb2_free_data fake_free_data
#define smb2_cmd_create_async fake_create
#define smb2_cmd_set_info_async fake_set_info
#include "../Prototype/SMB/SMBEdit.c"
#undef smb2_queue_pdu
#undef poll
#undef smb2_service
#undef clock_gettime
#undef tm_smb_destroy_context
#undef smb2_free_data
#undef smb2_cmd_create_async
#undef smb2_cmd_set_info_async

static void expect(int condition, const char *name, const char *detail)
{
    if (condition) return;
    fprintf(stderr, "%s: %s\n", name, detail);
    failures++;
}

static void fake_queue(struct smb2_context *smb, struct smb2_pdu *pdu)
{
    (void)smb;
    if (queued && !batch_io) abort();
    if (pdu->header.command == SMB2_READ || pdu->header.command == SMB2_WRITE) {
        memcpy(&sent_length, pdu->out.iov[1].buf + 4, sizeof(sent_length));
        sent_charge = pdu->header.credit_charge;
    }
    if (inspect_write) {
        if (pdu->out.niov < 3 || pdu->out.iov[1].len < sizeof(sent_write)
            || pdu->out.iov[2].len > sizeof(sent_payload)) abort();
        memcpy(sent_write, pdu->out.iov[1].buf, sizeof(sent_write));
        memcpy(sent_payload, pdu->out.iov[2].buf, pdu->out.iov[2].len);
    }
    if (batch_io) queued_requests++;
    pdu->next = queued;
    queued = pdu;
}

static int fake_poll(struct pollfd *fds, nfds_t count, int milliseconds)
{
    if (count != 1 || milliseconds != 100) abort();
    if (delivery == poll_failure) { errno = EBADF; return -1; }
    fds[0].revents = POLLIN;
    return 1;
}

static int fake_service(struct smb2_context *smb, int revents)
{
    (void)revents;
    if (delivery == service_failure) return -1;
    if (delivery == timeout) return 0;
    if (!queued) abort();
    struct smb2_pdu *pdu = queued;
    queued = pdu->next;
    pdu->next = NULL;
    if (batch_io) {
        uint64_t offset;
        uint32_t length;
        memcpy(&offset, pdu->out.iov[1].buf + 8, sizeof(offset));
        memcpy(&length, pdu->out.iov[1].buf + 4, sizeof(length));
        length -= offset == short_at;
        if (pdu->header.command == SMB2_WRITE) {
            const uint8_t *bytes = pdu->out.iov[2].buf;
            uint8_t expected = (uint8_t)(1 + offset / TM_SMB_IO_SIZE);
            expect(bytes[0] == expected && bytes[length - 1] == expected, "write batch", "wrong slice");
            struct smb2_write_reply reply = {.count = length};
            pdu->cb(smb, (int)response_status, &reply, pdu->cb_data);
        } else {
            struct smb2_read_reply reply = {.data_length = length};
            memset(pdu->in.iov[0].buf, (int)(1 + offset / TM_SMB_IO_SIZE), length);
            pdu->cb(smb, 0, &reply, pdu->cb_data);
        }
    } else {
        pdu->cb(smb, (int)response_status, response_data, pdu->cb_data);
    }
    smb2_free_pdu(smb, pdu);
    return delivery == reply_then_service_failure ? -1 : 0;
}

static int fake_clock(clockid_t clock, struct timespec *value)
{
    if (clock != CLOCK_MONOTONIC) abort();
    *value = (struct timespec){.tv_sec = delivery == timeout ? clock_calls++ * 12 : 0};
    return 0;
}

static void fake_destroy(void *opaque)
{
    struct smb2_context *smb = opaque;
    destroyed++;
    while (queued) {
        struct smb2_pdu *pdu = queued;
        queued = pdu->next;
        pdu->next = NULL;
        pdu->cb(smb, SMB2_STATUS_SHUTDOWN, NULL, pdu->cb_data);
        smb2_free_pdu(smb, pdu);
    }
    smb2_destroy_context(smb);
}

static void fake_free_data(struct smb2_context *smb, void *data)
{
    (void)smb;
    (void)data;
    freed_data++;
}

static struct smb2_pdu *fake_create(struct smb2_context *smb, struct smb2_create_request *request,
                                    smb2_command_cb callback, void *context)
{
    snprintf(sent_name, sizeof(sent_name), "%s", request->name);
    sent_disposition = request->create_disposition;
    sent_access = request->desired_access;
    sent_sharing = request->share_access;
    sent_options = request->create_options;
    return fail_create ? NULL : smb2_cmd_create_async(smb, request, callback, context);
}

static struct smb2_pdu *fake_set_info(struct smb2_context *smb, struct smb2_set_info_request *request,
                                      smb2_command_cb callback, void *context)
{
    if (request->file_info_class == SMB2_FILE_RENAME_INFORMATION) {
        const struct smb2_file_rename_info *info = request->input_data;
        snprintf(sent_name, sizeof(sent_name), "%s", (const char *)info->file_name);
    }
    if (request->file_info_class == SMB2_FILE_BASIC_INFORMATION)
        memcpy(&sent_basic, request->input_data, sizeof(sent_basic));
    return smb2_cmd_set_info_async(smb, request, callback, context);
}

void tm_smb_end_edit(void *smb)
{
    (void)smb;
    abort();
}

static struct edit_client client;
static uint8_t file[SMB2_FD_SIZE], buffer[4096];
static uint64_t values[8];
static uint32_t count;
static int finished;

static void prepare(void)
{
    if (queued) abort();
    if (client.smb) smb2_destroy_context(client.smb);
    client = (struct edit_client){.smb = smb2_init_context(),
                                .ntstatus = SMB2_STATUS_OBJECT_NAME_NOT_FOUND};
    if (!client.smb) abort();
    client.smb->dialect = SMB2_VERSION_0302;
    client.smb->credits = 32;
    client.smb->max_read_size = client.smb->max_write_size = 1024 * 1024;
    client.smb->supports_multi_credit = 1;
    delivery = reply_ready;
    response_status = 0;
    response_data = NULL;
    fail_create = clock_calls = destroyed = freed_data = 0;
    inspect_write = 0;
    batch_io = queued_requests = 0;
    short_at = UINT64_MAX;
}

static void result(const char *name, int actual, int expected, uint32_t status)
{
    cases++;
    expect(actual == expected, name, "errno changed");
    expect(tm_edit_last_ntstatus(&client) == status, name, "incorrect server status");
    expect(queued == NULL, name, "request still queued");
}

static void server_failures(void)
{
    static const uint32_t statuses[] = {
        SMB2_STATUS_OBJECT_NAME_NOT_FOUND, SMB2_STATUS_OBJECT_PATH_NOT_FOUND,
        SMB2_STATUS_DELETE_PENDING, SMB2_STATUS_SHARING_VIOLATION, SMB2_STATUS_IO_TIMEOUT,
    };
    struct smb2_error_reply error_reply = {.byte_count = 1, .error_data = buffer};
    for (size_t i = 0; i < sizeof(statuses) / sizeof(statuses[0]); i++) {
        prepare();
        response_status = statuses[i];
        response_data = &error_reply;
        result("server failure", tm_edit_open(&client, "file", 0, 0, file),
               nterror_to_errno(statuses[i]), statuses[i]);
        uint32_t copied = tm_edit_last_ntstatus(&client);
        response_status = 0;
        response_data = NULL;
        result("cleanup close", tm_edit_close(&client, file), 0, 0);
        expect(copied == statuses[i], "cleanup close", "copied failure changed");
    }
    prepare();
    response_status = SMB2_STATUS_ACCESS_DENIED;
    response_data = &error_reply;
    result("query failure", tm_edit_info(&client, file, values), EACCES, response_status);
    expect(freed_data == 0, "query failure", "decoded error payload as success data");
}

static void local_failures(void)
{
    prepare();
    result("invalid open", tm_edit_open(&client, "../file", 0, 0, file), EINVAL, 0);
    client.ntstatus = SMB2_STATUS_DELETE_PENDING;
    result("invalid directory", tm_edit_open_directory(&client, NULL, 0, 0, file), EINVAL, 0);
    client.ntstatus = SMB2_STATUS_DELETE_PENDING;
    result("invalid list", tm_edit_list(&client, file, 1, buffer, 0, &count, &finished), EINVAL, 0);
    client.ntstatus = SMB2_STATUS_DELETE_PENDING;
    result("invalid size", tm_edit_set_size(&client, file, UINT64_MAX), EINVAL, 0);
    client.ntstatus = SMB2_STATUS_DELETE_PENDING;
    result("invalid rename", tm_edit_rename(&client, file, "/file"), EINVAL, 0);
    client.ntstatus = SMB2_STATUS_DELETE_PENDING;
    result("unset write time", tm_edit_set_write_time(&client, file, 0), EINVAL, 0);
    client.ntstatus = SMB2_STATUS_DELETE_PENDING;
    result("write time past FILETIME", tm_edit_set_write_time(&client, file, UINT64_MAX / 10), EINVAL, 0);
    prepare();
    fail_create = 1;
    result("request allocation failure", tm_edit_open(&client, "file", 0, 0, file), EIO, 0);

    static const uint32_t local[] = {
        SMB2_STATUS_SHUTDOWN, SMB2_STATUS_IO_TIMEOUT, (uint32_t)-EIO,
        SMB2_STATUS_OBJECT_NAME_NOT_FOUND,
    };
    for (size_t i = 0; i < sizeof(local) / sizeof(local[0]); i++) {
        prepare();
        response_status = local[i];
        result("local callback", tm_edit_delete(&client, file), nterror_to_errno(local[i]), 0);
    }
    prepare();
    struct smb2_error_reply error_reply = {0};
    response_data = &error_reply;
    response_status = (uint32_t)-EINVAL;
    result("errno with data", tm_edit_delete(&client, file), nterror_to_errno(response_status), 0);
}

static void sent(const char *name, int actual, const char *expected)
{
    cases++;
    expect(actual == 0 || actual == EIO, name, "request not sent");
    expect(!strcmp(sent_name, expected), name, "sent another spelling");
    expect(queued == NULL, name, "request still queued");
    sent_name[0] = '\0';
}

// Catalog paths are decomposed; the server must receive the composed spelling, as from macOS.
static void composed_names(void)
{
    static const char decomposed[] = "Cafe\xcc\x81/Re\xcc\x81sume\xcc\x81.txt";
    static const char composed[] = "Caf\xc3\xa9/R\xc3\xa9sum\xc3\xa9.txt";
    prepare();
    sent("composed open", tm_edit_open(&client, decomposed, 0, 0, file), composed);
    sent("composed directory", tm_edit_open_directory(&client, "Cafe\xcc\x81", 0, 0, file), "Caf\xc3\xa9");
    sent("share root directory", tm_edit_open_directory(&client, "", 0, 0, file), "");
    sent("composed rename", tm_edit_rename(&client, file, decomposed), "Caf\xc3\xa9\\R\xc3\xa9sum\xc3\xa9.txt");
    // U+2126, U+F900 and U+2F800 stay as they are, as from macOS; the accents around them compose.
    sent("kept singletons", tm_edit_open(&client, "e\xcc\x81\xe2\x84\xa6\xef\xa4\x80\xf0\xaf\xa0\x80" "e\xcc\x81", 0, 0, file),
         "\xc3\xa9\xe2\x84\xa6\xef\xa4\x80\xf0\xaf\xa0\x80\xc3\xa9");
    result("invalid UTF-8 open", tm_edit_open(&client, "Caf\xff", 0, 0, file), EINVAL, 0);
    expect(!sent_name[0], "invalid UTF-8 open", "request sent");
}

#define DISCONNECTED(name, call) do { \
    client.ntstatus = SMB2_STATUS_DELETE_PENDING; \
    result(name, (call), EIO, 0); \
} while (0)

static void disconnected(void)
{
    prepare();
    smb2_destroy_context(client.smb);
    client.smb = NULL;
    DISCONNECTED("disconnected open", tm_edit_open(&client, "file", 0, 0, file));
    DISCONNECTED("disconnected close", tm_edit_close(&client, file));
    DISCONNECTED("disconnected close info", tm_edit_close_info(&client, file, values));
    DISCONNECTED("disconnected directory", tm_edit_open_directory(&client, "", 0, 0, file));
    DISCONNECTED("disconnected list", tm_edit_list(&client, file, 1, buffer, 80, &count, &finished));
    DISCONNECTED("disconnected size", tm_edit_set_size(&client, file, 1));
    DISCONNECTED("disconnected write time", tm_edit_set_write_time(&client, file, 1));
    DISCONNECTED("disconnected info", tm_edit_info(&client, file, values));
    DISCONNECTED("disconnected read", tm_edit_read(&client, file, 0, buffer, 1, &count));
    DISCONNECTED("disconnected write", tm_edit_write(&client, file, 0, buffer, 1, &count));
    DISCONNECTED("disconnected rename", tm_edit_rename(&client, file, "target"));
    DISCONNECTED("disconnected delete", tm_edit_delete(&client, file));
    DISCONNECTED("disconnected flush", tm_edit_flush(&client, file));
}

static void decoded_success(void)
{
    prepare();
    struct smb2_error_reply error_reply = {0};
    response_status = SMB2_STATUS_NO_MORE_FILES;
    response_data = &error_reply;
    result("listing finished", tm_edit_list(&client, file, 0, buffer, 80, &count, &finished), 0, 0);
    expect(finished && count == 0, "listing finished", "end of listing changed");
    prepare();
    result("malformed open", tm_edit_open(&client, "file", 0, 0, file), EIO, 0);
    result("malformed close info", tm_edit_close_info(&client, file, values), EIO, 0);
    result("malformed info", tm_edit_info(&client, file, values), EIO, 0);
    result("malformed read", tm_edit_read(&client, file, 0, buffer, 1, &count), EIO, 0);
    result("malformed list", tm_edit_list(&client, file, 1, buffer, 80, &count, &finished),
           EOVERFLOW, 0);
}

static void transport_failures(void)
{
    static const enum delivery modes[] = {
        poll_failure, service_failure, timeout, reply_then_service_failure,
    };
    static const int errors[] = {EBADF, ECONNRESET, ETIMEDOUT, ECONNRESET};
    struct smb2_error_reply error_reply = {0};
    for (size_t i = 0; i < sizeof(modes) / sizeof(modes[0]); i++) {
        prepare();
        delivery = modes[i];
        response_status = SMB2_STATUS_OBJECT_NAME_NOT_FOUND;
        response_data = &error_reply;
        client.smb->session_id = 0x1000 + i;
        result("transport failure", tm_edit_delete(&client, file), errors[i], 0);
        expect(destroyed == 1 && !client.smb, "transport failure", "context survived");
        expect(tm_edit_dropped_session(&client) == 0x1000 + i, "transport failure", "session ID lost");
    }
    prepare();
    client.smb->session_id = 0x2000;
    response_status = SMB2_STATUS_SHARING_VIOLATION;
    response_data = &error_reply;
    result("server failure keeps the session", tm_edit_delete(&client, file), ETXTBSY,
           SMB2_STATUS_SHARING_VIOLATION);
    expect(tm_edit_dropped_session(&client) == 0, "server failure keeps the session", "session dropped");
}

static void close_attributes(void)
{
    prepare();
    const uint64_t epoch = 116444736000000000ULL;
    struct smb2_close_reply reply = {
        .flags = SMB2_CLOSE_FLAG_POSTQUERY_ATTRIB,
        .creation_time = epoch + 123456789,
        .last_write_time = epoch + 234567891,
        .change_time = epoch + 345678912,
        .end_of_file = 4294967297ULL,
        .file_attributes = SMB2_FILE_ATTRIBUTE_ARCHIVE,
    };
    response_data = &reply;
    result("close attributes", tm_edit_close_info(&client, file, values), 0, 0);
    expect(values[0] == 12345678 && values[1] == 23456789 && values[2] == 34567891
           && values[3] == 4294967297ULL && values[4] == SMB2_FILE_ATTRIBUTE_ARCHIVE,
           "close attributes", "metadata or timestamp conversion changed");
    reply.flags = 0;
    values[0] = 99;
    result("missing close attributes", tm_edit_close_info(&client, file, values), EIO, 0);
    expect(values[0] == 99, "missing close attributes", "failure published metadata");
    reply.flags = SMB2_CLOSE_FLAG_POSTQUERY_ATTRIB;
    reply.last_write_time = epoch - 1;
    result("invalid close timestamp", tm_edit_close_info(&client, file, values), EIO, 0);
}

static uint64_t decode_little(const uint8_t *bytes, size_t length)
{
    uint64_t value = 0;
    for (size_t i = 0; i < length; i++) value |= (uint64_t)bytes[i] << (8 * i);
    return value;
}

static void file_writes(void)
{
    prepare();
    for (size_t i = 0; i < sizeof(file); i++) file[i] = (uint8_t)(i + 1);
    for (size_t i = 0; i < sizeof(buffer); i++) buffer[i] = (uint8_t)i;
    struct smb2_write_reply reply = {.count = sizeof(buffer)};
    response_data = &reply;
    inspect_write = 1;
    result("file write", tm_edit_write(&client, file, 4294967297ULL, buffer, sizeof(buffer), &count), 0, 0);
    expect(count == sizeof(buffer), "file write", "lost successful count");
    expect(decode_little(sent_write + 4, 4) == sizeof(buffer)
           && decode_little(sent_write + 8, 8) == 4294967297ULL
           && !memcmp(sent_write + 16, file, sizeof(file))
           && !memcmp(sent_payload, buffer, sizeof(buffer)), "file write", "encoded write changed");
    reply.count = 7;
    result("short file write", tm_edit_write(&client, file, INT64_MAX - 9, buffer, 9, &count), 0, 0);
    expect(count == 7, "short file write", "lost partial acknowledgement");
    reply.count = 0;
    count = 99;
    result("zero file write", tm_edit_write(&client, file, 0, buffer, 9, &count), EIO, 0);
    expect(count == 99, "zero file write", "failure published count");
    reply.count = 10;
    result("oversized write reply", tm_edit_write(&client, file, 0, buffer, 9, &count), EIO, 0);
    response_data = NULL;
    result("missing write reply", tm_edit_write(&client, file, 0, buffer, 9, &count), EIO, 0);
    result("empty write request", tm_edit_write(&client, file, 0, buffer, 0, &count), EINVAL, 0);
    result("large write batch", tm_edit_write(&client, file, 0, buffer, TM_SMB_IO_BATCH_SIZE + 1, &count), EINVAL, 0);
    result("overflowing write offset", tm_edit_write(&client, file, INT64_MAX, buffer, 1, &count), EINVAL, 0);
    result("invalid write offset", tm_edit_write(&client, file, UINT64_MAX, buffer, 1, &count), EINVAL, 0);
    result("missing write buffer", tm_edit_write(&client, file, 0, NULL, 1, &count), EINVAL, 0);
    struct smb2_error_reply error_reply = {0};
    response_status = SMB2_STATUS_DISK_FULL;
    response_data = &error_reply;
    result("write space failure", tm_edit_write(&client, file, 0, buffer, 9, &count),
           nterror_to_errno(response_status), response_status);
    expect(count == 99, "write space failure", "failure published count");
    const enum delivery modes[] = {service_failure, timeout, reply_then_service_failure};
    const int errors[] = {ECONNRESET, ETIMEDOUT, ECONNRESET};
    for (size_t i = 0; i < sizeof(modes) / sizeof(modes[0]); i++) {
        prepare();
        delivery = modes[i];
        reply.count = 9;
        response_data = &reply;
        count = 99;
        result("lost write reply", tm_edit_write(&client, file, 0, buffer, 9, &count), errors[i], 0);
        expect(count == 99 && destroyed == 1 && !client.smb,
               "lost write reply", "uncertain write acknowledged or context retained");
    }
}

static void payload_limits(void)
{
    static uint8_t payload[1024 * 1024];
    const struct { int credits, multi; uint32_t maximum, length, charge; } limits[] = {
        {32, 1, 1048576, 1048576, 16}, {1, 1, 1048576, 65536, 1},
        {32, 0, 1048576, 65536, 1}, {32, 1, 100000, 100000, 2},
    };
    for (size_t i = 0; i < sizeof(limits) / sizeof(limits[0]); i++) {
        prepare();
        client.smb->credits = limits[i].credits;
        client.smb->supports_multi_credit = limits[i].multi;
        client.smb->max_write_size = client.smb->max_read_size = limits[i].maximum;
        struct smb2_write_reply written = {.count = limits[i].length};
        response_data = &written;
        result("bounded write", tm_edit_write(&client, file, 0, payload, sizeof(payload), &count), 0, 0);
        expect(sent_length == limits[i].length && sent_charge == limits[i].charge && count == sent_length,
               "bounded write", "negotiated size or credits exceeded");
        struct smb2_read_reply read = {.data_length = limits[i].length};
        response_data = &read;
        result("bounded read", tm_edit_read(&client, file, 0, payload, sizeof(payload), &count), 0, 0);
        expect(sent_length == limits[i].length && sent_charge == limits[i].charge && count == sent_length,
               "bounded read", "negotiated size or credits exceeded");
        read.data_length++;
        count = 99;
        result("oversized read reply", tm_edit_read(&client, file, 0, payload, sizeof(payload), &count), EIO, 0);
        expect(count == 99, "oversized read reply", "failure published count");
    }
    prepare();
    client.smb->credits = 0;
    result("no write credits", tm_edit_write(&client, file, 0, payload, 1, &count), EIO, 0);
    result("no read credits", tm_edit_read(&client, file, 0, payload, 1, &count), EIO, 0);
}

static void pipelined_reads(void)
{
    static uint8_t payload[TM_SMB_IO_BATCH_SIZE];
    prepare();
    batch_io = 1;
    client.smb->credits = 64;
    result("out-of-order reads", tm_edit_read(&client, file, 0, payload, sizeof(payload), &count), 0, 0);
    expect(queued_requests == 4 && count == sizeof(payload), "out-of-order reads", "incomplete batch");
    for (size_t i = 0; i < 4; i++) {
        expect(payload[i * TM_SMB_IO_SIZE] == i + 1 && payload[(i + 1) * TM_SMB_IO_SIZE - 1] == i + 1,
               "out-of-order reads", "reply in wrong range");
    }
    prepare();
    batch_io = 1;
    client.smb->credits = 18;
    result("shared credit budget", tm_edit_read(&client, file, 0, payload, sizeof(payload), &count), 0, 0);
    expect(queued_requests == 2 && count == 18 * 65536, "shared credit budget", "incorrect credit charge");
    prepare();
    batch_io = 1;
    client.smb->credits = 64;
    short_at = TM_SMB_IO_SIZE;
    result("short middle read", tm_edit_read(&client, file, 0, payload, sizeof(payload), &count), 0, 0);
    expect(count == 2 * TM_SMB_IO_SIZE - 1, "short middle read", "published across a gap");
    prepare();
    batch_io = 1;
    delivery = service_failure;
    count = 99;
    result("lost read batch", tm_edit_read(&client, file, 0, payload, sizeof(payload), &count), ECONNRESET, 0);
    expect(count == 99 && destroyed == 1 && !client.smb, "lost read batch", "live requests or partial success");
}

static void pipelined_writes(void)
{
    static uint8_t payload[TM_SMB_IO_BATCH_SIZE];
    for (size_t i = 0; i < TM_SMB_IO_DEPTH; i++)
        memset(payload + i * TM_SMB_IO_SIZE, (int)(i + 1), TM_SMB_IO_SIZE);
    prepare();
    batch_io = 1;
    client.smb->credits = 64;
    result("out-of-order writes", tm_edit_write(&client, file, 0, payload, sizeof(payload), &count), 0, 0);
    expect(queued_requests == 4 && count == sizeof(payload), "out-of-order writes", "incomplete batch");
    prepare();
    batch_io = 1;
    client.smb->credits = 18;
    result("write batch credits", tm_edit_write(&client, file, 0, payload, sizeof(payload), &count), 0, 0);
    expect(queued_requests == 2 && count == 18 * 65536, "write batch credits", "incorrect credit charge");
    prepare();
    batch_io = 1;
    client.smb->credits = 64;
    short_at = TM_SMB_IO_SIZE;
    result("short middle write", tm_edit_write(&client, file, 0, payload, sizeof(payload), &count), 0, 0);
    expect(count == 2 * TM_SMB_IO_SIZE - 1, "short middle write", "acknowledged across a gap");
    prepare();
    batch_io = 1;
    response_status = SMB2_STATUS_DISK_FULL;
    count = 99;
    result("refused write batch", tm_edit_write(&client, file, 0, payload, sizeof(payload), &count),
           ENOSPC, SMB2_STATUS_DISK_FULL);
    expect(count == 99, "refused write batch", "acknowledged failed batch");
    prepare();
    batch_io = 1;
    delivery = service_failure;
    count = 99;
    result("lost write batch", tm_edit_write(&client, file, 0, payload, sizeof(payload), &count), ECONNRESET, 0);
    expect(count == 99 && destroyed == 1 && !client.smb, "lost write batch", "live requests or partial success");
}

static void exclusive_uploads(void)
{
    prepare();
    struct smb2_create_reply reply = {0};
    memset(reply.file_id, 0x5a, sizeof(reply.file_id));
    response_data = &reply;
    uint32_t access = SMB2_FILE_READ_DATA | SMB2_FILE_WRITE_DATA | SMB2_FILE_READ_ATTRIBUTES;
    result("exclusive upload", tm_edit_create(&client, "folder/new.txt", access, file), 0, 0);
    expect(sent_disposition == SMB2_FILE_CREATE && sent_access == access && sent_sharing == 0,
           "exclusive upload", "create could replace or share an existing file");
    expect(sent_options == (SMB2_FILE_NON_DIRECTORY_FILE | SMB2_FILE_OPEN_REPARSE_POINT)
           && !memcmp(file, reply.file_id, sizeof(file)), "exclusive upload", "unsafe type or lost handle");
    result("invalid upload path", tm_edit_create(&client, "../new.txt", access, file), EINVAL, 0);
    struct smb2_error_reply error_reply = {0};
    response_status = SMB2_STATUS_OBJECT_NAME_COLLISION;
    response_data = &error_reply;
    result("upload collision", tm_edit_create(&client, "folder/new.txt", access, file),
           nterror_to_errno(response_status), response_status);
    const enum delivery modes[] = {service_failure, timeout, reply_then_service_failure};
    const int errors[] = {ECONNRESET, ETIMEDOUT, ECONNRESET};
    for (size_t i = 0; i < sizeof(modes) / sizeof(modes[0]); i++) {
        prepare();
        delivery = modes[i];
        response_data = &reply;
        memset(file, 0x33, sizeof(file));
        result("lost upload create", tm_edit_create(&client, "folder/new.txt", access, file), errors[i], 0);
        expect(file[0] == 0x33 && destroyed == 1 && !client.smb,
               "lost upload create", "uncertain handle published or connection retained");
    }
}

// Only LastWriteTime goes to the server; the save time is microseconds since 1970.
static void write_time(void)
{
    prepare();
    memset(&sent_basic, 0xff, sizeof(sent_basic));
    result("write time", tm_edit_set_write_time(&client, file, 1762600000123457ULL), 0, 0);
    expect(sent_basic.last_write_time.tv_sec == 1762600000 && sent_basic.last_write_time.tv_usec == 123457,
           "write time", "LastWriteTime changed");
    expect(!sent_basic.creation_time.tv_sec && !sent_basic.creation_time.tv_usec
           && !sent_basic.last_access_time.tv_sec && !sent_basic.last_access_time.tv_usec
           && !sent_basic.change_time.tv_sec && !sent_basic.change_time.tv_usec && !sent_basic.file_attributes,
           "write time", "another field set");
}

int main(void)
{
    server_failures();
    local_failures();
    disconnected();
    decoded_success();
    transport_failures();
    close_attributes();
    file_writes();
    payload_limits();
    pipelined_reads();
    pipelined_writes();
    composed_names();
    write_time();
    exclusive_uploads();
    if (client.smb) smb2_destroy_context(client.smb);
    if (failures) {
        fprintf(stderr, "SMB edit status: %d failures\n", failures);
        return 1;
    }
    printf("SMB edit status: %d cases passed\n", cases);
    return 0;
}
