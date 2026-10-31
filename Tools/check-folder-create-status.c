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

static struct smb2_pdu *queued;
static uint32_t response_status;
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

static int fake_service(struct smb2_context *smb, int revents)
{
    (void)revents;
    if (!queued) abort();
    struct smb2_pdu *pdu = queued;
    queued = NULL;
    pdu->cb(smb, (int)response_status, NULL, pdu->cb_data);
    smb2_free_pdu(smb, pdu);
    return 0;
}

static struct smb2_pdu *fake_create(struct smb2_context *smb, struct smb2_create_request *request,
                                   smb2_command_cb callback, void *context)
{
    return fail_encoding ? NULL : smb2_cmd_create_async(smb, request, callback, context);
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
        response_status = cases[i].status;
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
    smb2_destroy_context(smb);
    puts("6 folder-create status cases passed");
    return 0;
}
