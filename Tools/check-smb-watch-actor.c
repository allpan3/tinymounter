// The second client for Tools/check-smb-watch.swift: changes the disposable fixture over its
// own libsmb2 connection. Paths are sent as given, without composing, so NFD names can be made.
#define __STDC_WANT_LIB_EXT1__ 1
#include "check-smb-watch.h"
#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <smb2/smb2.h>
#include <smb2/libsmb2.h>
#include <smb2/libsmb2-raw.h>
#include "libsmb2-private.h"

static struct smb2_context *actor;

int actor_connect(const char *server, const char *share, const char *account, const uint8_t *password,
                  size_t length)
{
    actor = smb2_init_context();
    char *secret = calloc(1, length + 1);
    if (!actor || !secret) return ENOMEM;
    memcpy(secret, password, length);
    smb2_set_timeout(actor, 30);
    smb2_set_version(actor, SMB2_VERSION_ANY3);
    smb2_set_authentication(actor, SMB2_SEC_NTLMSSP);
    smb2_set_user(actor, account);
    smb2_set_password(actor, secret);
    memset_s(secret, length + 1, 0, length + 1);
    free(secret);
    smb2_set_sign(actor, 1);
    smb2_set_seal(actor, 1);
    int result = smb2_connect_share(actor, server, share, NULL);
    memset_s(discard_const(actor->password), strlen(actor->password), 0, strlen(actor->password));
    smb2_set_password(actor, NULL);
    return result ? EIO : 0;
}

void actor_disconnect(void)
{
    smb2_disconnect_share(actor);
    smb2_destroy_context(actor);
}

const char *actor_error(void) { return smb2_get_error(actor); }
uint32_t actor_ntstatus(void) { return (uint32_t)smb2_get_nterror(actor); }

int actor_mkdir(const char *path) { return smb2_mkdir(actor, path); }
int actor_rmdir(const char *path) { return smb2_rmdir(actor, path); }
int actor_unlink(const char *path) { return smb2_unlink(actor, path); }
int actor_rename(const char *from, const char *to) { return smb2_rename(actor, from, to); }

int actor_write(const char *path, uint32_t size, int create, uint8_t fill)
{
    struct smb2fh *fh = smb2_open(actor, path, O_WRONLY | (create ? O_CREAT | O_EXCL : 0));
    if (!fh) return -EIO;
    uint8_t *data = malloc(size ? size : 1);
    memset(data, fill, size);
    int result = size ? smb2_pwrite(actor, fh, data, size, 0) : 0;
    free(data);
    smb2_close(actor, fh);
    return result < 0 ? result : 0;
}

struct actor_reply { int done; uint32_t status; };

static void replied(struct smb2_context *smb, int status, void *data, void *opaque)
{
    struct actor_reply *reply = opaque;
    reply->status = (uint32_t)status;
    reply->done = 1;
}

uint32_t actor_set_attributes(const char *path, uint32_t attributes)
{
    struct smb2fh *fh = smb2_open(actor, path, O_RDWR);
    if (!fh) return 0xffffffffu;
    struct smb2_file_basic_info info = {0};
    info.file_attributes = attributes;
    struct smb2_set_info_request request = {0};
    request.info_type = SMB2_0_INFO_FILE;
    request.file_info_class = SMB2_FILE_BASIC_INFORMATION;
    request.input_data = &info;
    memcpy(request.file_id, smb2_get_file_id(fh), SMB2_FD_SIZE);
    struct actor_reply reply = {0};
    struct smb2_pdu *pdu = smb2_cmd_set_info_async(actor, &request, replied, &reply);
    if (!pdu) { smb2_close(actor, fh); return 0xfffffffeu; }
    smb2_queue_pdu(actor, pdu);
    while (!reply.done) {
        struct pollfd fd = {.fd = smb2_get_fd(actor), .events = smb2_which_events(actor)};
        if (poll(&fd, 1, 100) < 0 && errno != EINTR) break;
        if (smb2_service(actor, fd.revents) < 0) break;
    }
    smb2_close(actor, fh);
    return reply.done ? reply.status : 0xfffffffdu;
}

// Calls `found` with each name in a folder as the server spells it, without "." and "..".
int actor_list(const char *path, void (*found)(void *context, const char *name), void *context)
{
    struct smb2dir *dir = smb2_opendir(actor, path);
    if (!dir) return -EIO;
    struct smb2dirent *entry;
    while ((entry = smb2_readdir(actor, dir))) {
        if (strcmp(entry->name, ".") && strcmp(entry->name, "..")) found(context, entry->name);
    }
    smb2_closedir(actor, dir);
    return 0;
}

int actor_is_directory(const char *path)
{
    struct smb2_stat_64 st;
    return !smb2_stat(actor, path, &st) && st.smb2_type == SMB2_TYPE_DIRECTORY;
}
