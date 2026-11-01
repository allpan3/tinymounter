#include <errno.h>
#include <poll.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <time.h>
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

// Exercise the production response classification without sending a request to a server.
#define smb2_queue_pdu fake_queue
#define poll fake_poll
#define smb2_service fake_service
#define smb2_cmd_create_async fake_create
#include "../Prototype/SMB/SMBRename.c"
#undef smb2_queue_pdu
#undef poll
#undef smb2_service
#undef smb2_cmd_create_async

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

static void run(const struct step *steps, size_t count)
{
    script = steps;
    script_length = count;
    script_next = 0;
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
    puts("7 folder-create status cases passed");
    return 0;
}
