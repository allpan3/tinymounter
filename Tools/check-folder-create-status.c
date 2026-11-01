#include <errno.h>
#include <poll.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <time.h>
#include <GSS/GSS.h>
#include <smb2/smb2.h>
#include <smb2/smb2-errors.h>
#include <smb2/libsmb2.h>
#include <smb2/libsmb2-raw.h>
#include "libsmb2-private.h"

struct step { uint16_t command; uint32_t status; };

static struct smb2_pdu *queued;
static const struct step *script;
static size_t script_length, script_next;
static int fail_encoding;
static int requests;

static void fake_queue(struct smb2_context *smb, struct smb2_pdu *pdu);
static int fake_poll(struct pollfd *fds, nfds_t count, int milliseconds);
static int fake_service(struct smb2_context *smb, int revents);
static struct smb2_pdu *fake_create(struct smb2_context *smb, struct smb2_create_request *request,
                                   smb2_command_cb callback, void *context);
static int fake_connect(struct smb2_context *smb, const char *server, const char *share, const char *user);
static OM_uint32 fake_credentials(OM_uint32 *minor, OM_uint32 flags, gss_const_OID mechanism, void *context,
                                  void (*next)(void *, gss_iter_OID, gss_cred_id_t));

// Exercise the production response classification without sending a request to a server.
#define smb2_queue_pdu fake_queue
#define poll fake_poll
#define smb2_service fake_service
#define smb2_cmd_create_async fake_create
#define smb2_connect_share fake_connect
#define gss_iter_creds_f fake_credentials
#include "../Prototype/SMB/SMBRename.c"
#undef smb2_queue_pdu
#undef poll
#undef smb2_service
#undef smb2_cmd_create_async
#undef smb2_connect_share
#undef gss_iter_creds_f

static const uint64_t identity = 42, birth_seconds = 1800000000, birth_micros = 5;

static void fake_queue(struct smb2_context *smb, struct smb2_pdu *pdu)
{
    (void)smb;
    if (queued) abort();
    queued = pdu;
    requests++;
}

static int fake_poll(struct pollfd *fds, nfds_t count, int milliseconds)
{
    if (count != 1 || milliseconds != 100) abort();
    fds[0].revents = POLLIN;
    return 1;
}

// Replies carry the payloads libsmb2 delivers: an error reply whenever the status is an error.
static int fake_service(struct smb2_context *smb, int revents)
{
    (void)revents;
    if (!queued || script_next >= script_length) abort();
    struct smb2_pdu *pdu = queued;
    const struct step *step = &script[script_next++];
    queued = NULL;
    if (pdu->header.command != step->command) abort();
    uint8_t error_data[8] = {0};
    struct smb2_error_reply failed = { .byte_count = sizeof(error_data), .error_data = error_data };
    struct smb2_create_reply created = { .file_id = {1} };
    struct smb2_query_info_reply inspected_reply = {0};
    void *data = &failed;
    if (!step->status && step->command == SMB2_CREATE) data = &created;
    else if (!step->status) {
        struct smb2_file_all_info *info = smb2_alloc_init(smb, sizeof(*info));
        if (!info) abort();
        info->basic.file_attributes = SMB2_FILE_ATTRIBUTE_DIRECTORY;
        info->basic.creation_time.tv_sec = (time_t)birth_seconds;
        info->basic.creation_time.tv_usec = (long)birth_micros;
        info->index_number = identity;
        inspected_reply.output_buffer = info;
        data = &inspected_reply;
    }
    pdu->cb(smb, (int)step->status, data, pdu->cb_data);
    smb2_free_pdu(smb, pdu);
    return 0;
}

static struct smb2_pdu *fake_create(struct smb2_context *smb, struct smb2_create_request *request,
                                   smb2_command_cb callback, void *context)
{
    return fail_encoding ? NULL : smb2_cmd_create_async(smb, request, callback, context);
}

static int fake_connect(struct smb2_context *smb, const char *server, const char *share, const char *user)
{
    return 0;
}

static OM_uint32 fake_credentials(OM_uint32 *minor, OM_uint32 flags, gss_const_OID mechanism, void *context,
                                  void (*next)(void *, gss_iter_OID, gss_cred_id_t))
{
    *minor = 0;
    next(context, NULL, NULL);
    return GSS_S_COMPLETE;
}

static void run(const struct step *steps, size_t count)
{
    script = steps;
    script_length = count;
    script_next = 0;
}

static int receipts, receipt_result;

static int receive(void *context, uint64_t file_id, uint64_t birth_us)
{
    receipts++;
    return file_id == identity && birth_us == birth_seconds * 1000000 + birth_micros ? receipt_result : ESTALE;
}

// The share root and one parent each take an open and a query before the target CREATE.
#define PARENTS {SMB2_CREATE, 0}, {SMB2_QUERY_INFO, 0}, {SMB2_CREATE, 0}, {SMB2_QUERY_INFO, 0}

static int check_entry_cases(void)
{
    const uint64_t birth = birth_seconds * 1000000 + birth_micros;
    const struct {
        struct step steps[6];
        size_t count;
        uint64_t expected_id;
        int receipt_result, error, stage, parents, sent_queued, sent, receipts;
        uint32_t status;
    } cases[] = {
        {{{SMB2_CREATE, 0}, {SMB2_QUERY_INFO, 0}, {SMB2_CREATE, SMB2_STATUS_ACCESS_DENIED}}, 3,
         0, 0, EACCES, TM_FOLDER_PARENT, 1, 0, 0, 0, SMB2_STATUS_ACCESS_DENIED},
        {{PARENTS, {SMB2_CREATE, SMB2_STATUS_ACCESS_DENIED}}, 5,
         0, 0, EACCES, TM_FOLDER_TARGET, 2, 1, 1, 0, SMB2_STATUS_ACCESS_DENIED},
        {{PARENTS, {SMB2_CREATE, SMB2_STATUS_OBJECT_NAME_COLLISION}}, 5,
         0, 0, EEXIST, TM_FOLDER_TARGET, 2, 1, 0, 0, SMB2_STATUS_OBJECT_NAME_COLLISION},
        {{PARENTS, {SMB2_CREATE, 0}, {SMB2_QUERY_INFO, SMB2_STATUS_ACCESS_DENIED}}, 6,
         0, 0, EACCES, TM_FOLDER_QUERY, 2, 1, 1, 0, SMB2_STATUS_ACCESS_DENIED},
        {{PARENTS, {SMB2_CREATE, 0}, {SMB2_QUERY_INFO, 0}}, 6,
         0, EIO, EIO, TM_FOLDER_RECEIPT, 2, 1, 1, 1, 0},
        {{PARENTS, {SMB2_CREATE, 0}, {SMB2_QUERY_INFO, 0}}, 6,
         identity + 1, 0, ESTALE, TM_FOLDER_IDENTITY, 2, 0, 0, 0, 0},
        {{PARENTS, {SMB2_CREATE, 0}, {SMB2_QUERY_INFO, 0}}, 6,
         0, 0, 0, TM_FOLDER_DONE, 2, 1, 1, 1, 0},
    };
    for (size_t i = 0; i < sizeof(cases) / sizeof(cases[0]); i++) {
        struct tm_smb_folder_trace trace;
        int sent = -1;
        run(cases[i].steps, cases[i].count);
        receipts = 0;
        receipt_result = cases[i].receipt_result;
        int error = tm_smb_create_folder("fixture", "share", "guest", "parent/folder", cases[i].expected_id,
                                         cases[i].expected_id ? birth : 0, receive, NULL, &sent, &trace);
        if (error != cases[i].error || trace.error != error || trace.stage != cases[i].stage ||
            trace.parents != cases[i].parents || trace.status != cases[i].status ||
            trace.sent_queued != cases[i].sent_queued || trace.sent != cases[i].sent || sent != trace.sent ||
            receipts != cases[i].receipts || script_next != cases[i].count || queued) {
            fprintf(stderr, "folder create entry case %zu failed at %s\n", i, tm_smb_folder_stage_name(trace.stage));
            return 1;
        }
    }
    struct tm_smb_folder_trace trace;
    int sent = -1;
    if (tm_smb_create_folder("fixture", "share", "guest", "parent/../folder", 0, 0, receive, NULL, &sent, &trace)
            != EINVAL || trace.stage != TM_FOLDER_ARGUMENTS || sent || trace.sent) {
        fprintf(stderr, "folder create argument case failed\n");
        return 1;
    }
    return 0;
}

int main(void)
{
    const struct { uint32_t status; int error, changed; } cases[] = {
        {SMB2_STATUS_ACCESS_DENIED, EACCES, 1},
        {SMB2_STATUS_CANNOT_DELETE, EPERM, 1},
        {SMB2_STATUS_OBJECT_NAME_COLLISION, EEXIST, 0},
        {SMB2_STATUS_OBJECT_PATH_NOT_FOUND, ENOENT, 0},
        {SMB2_STATUS_IO_TIMEOUT, ETIMEDOUT, 1},
    };
    struct smb2_context *smb = smb2_init_context();
    if (!smb) abort();
    for (size_t i = 0; i < sizeof(cases) / sizeof(cases[0]); i++) {
        struct reply reply = {0};
        int sent = 0;
        struct step step = {SMB2_CREATE, cases[i].status};
        run(&step, 1);
        int error = open_folder(smb, "fixture", 0, 1, &sent, &reply);
        if (error != cases[i].error || sent != cases[i].changed || !reply.done || queued) {
            fprintf(stderr, "folder create response case %zu failed\n", i);
            return 1;
        }
    }
    struct reply reply = {0};
    int sent = 0;
    fail_encoding = 1;
    if (open_folder(smb, "fixture", 0, 1, &sent, &reply) != EIO || sent || requests != 5) {
        fprintf(stderr, "unsent folder create case failed\n");
        return 1;
    }
    fail_encoding = 0;

    const struct step denied_query[] = {{SMB2_CREATE, 0}, {SMB2_QUERY_INFO, SMB2_STATUS_ACCESS_DENIED}};
    run(denied_query, 2);
    reply = (struct reply){0};
    sent = 0;
    if (open_folder(smb, "fixture", 0, 1, &sent, &reply) != EACCES || sent != 1 || script_next != 2 ||
        queued || reply.identity) {
        fprintf(stderr, "denied query after create case failed\n");
        return 1;
    }
    smb2_destroy_context(smb);
    if (check_entry_cases()) return 1;
    puts("15 folder-create status cases passed");
    return 0;
}
