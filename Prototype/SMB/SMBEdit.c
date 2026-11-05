#include "SMBEdit.h"
#include <errno.h>
#include <poll.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <sys/socket.h>
#include <smb2/smb2.h>
#include <smb2/smb2-errors.h>
#include <smb2/libsmb2.h>
#include <smb2/libsmb2-raw.h>
#include "libsmb2-private.h"

struct tm_edit_reply {
    int done, error;
    uint32_t ntstatus;
    smb2_file_id file;
    uint64_t values[8];
    uint32_t count;
    uint8_t *buffer;
    uint32_t capacity;
};

struct edit_client {
    struct smb2_context *smb;
    uint32_t ntstatus;
};
extern void *tm_smb_begin_edit(const char *, const char *, const char *, int *);
extern void tm_smb_end_edit(void *);
extern void tm_smb_destroy_context(void *);
extern int tm_smb_compose(const char *, char *, size_t);

void *tm_edit_connect(const char *server, const char *share, const char *account, int *error)
{
    struct edit_client *client = calloc(1, sizeof(*client));
    if (!client) { *error = ENOMEM; return NULL; }
    client->smb = tm_smb_begin_edit(server, share, account, error);
    if (!client->smb) { free(client); return NULL; }
    *error = 0;
    return client;
}

void tm_edit_disconnect(void *opaque)
{
    struct edit_client *client = opaque;
    tm_smb_end_edit(client->smb);
    free(client);
}

uint32_t tm_edit_last_ntstatus(void *opaque)
{
    struct edit_client *client = opaque;
    return client->ntstatus;
}

static void done(struct smb2_context *smb, int status, void *data, void *context)
{
    struct tm_edit_reply *reply = context;
    reply->error = status ? nterror_to_errno((uint32_t)status) : 0;
    // Raw server replies have a payload; libsmb2's local timeout and shutdown callbacks do not.
    uint32_t raw = (uint32_t)status;
    int server_failure = data && (raw & SMB2_STATUS_SEVERITY_MASK) >= SMB2_STATUS_SEVERITY_WARNING
        && !(raw & 0x10000000);
    reply->ntstatus = server_failure ? raw : 0;
    reply->done = 1;
}

static int wait_reply(struct edit_client *client, struct smb2_pdu *pdu, struct tm_edit_reply *reply)
{
    if (!pdu || !client->smb) return EIO;
    smb2_queue_pdu(client->smb, pdu);
    struct timespec start, now;
    clock_gettime(CLOCK_MONOTONIC, &start);
    int error = 0;
    while (!reply->done) {
        struct pollfd fd = {.fd = smb2_get_fd(client->smb), .events = smb2_which_events(client->smb)};
        if (poll(&fd, 1, 100) < 0 && errno != EINTR) { error = errno; break; }
        if (smb2_service(client->smb, fd.revents) < 0) { error = ECONNRESET; break; }
        clock_gettime(CLOCK_MONOTONIC, &now);
        if (!reply->done && now.tv_sec - start.tv_sec >= 12) { error = ETIMEDOUT; break; }
    }
    if (error) {
        // An abortive close drops unsent requests; a graceful one can deliver a lost create later.
        struct linger reset = {.l_onoff = 1, .l_linger = 0};
        t_socket connection = smb2_get_fd(client->smb);
        if (connection >= 0) (void)setsockopt(connection, SOL_SOCKET, SO_LINGER, &reset, sizeof(reset));
        // Destroy queued callbacks while their reply storage is still alive.
        tm_smb_destroy_context(client->smb);
        client->smb = NULL;
        return error;
    }
    client->ntstatus = reply->error ? reply->ntstatus : 0;
    return reply->error;
}

static int valid_path(const char *path)
{
    if (!path || !*path || strlen(path) > 1023 || strchr(path, '\\') || strchr(path, ':')) return 0;
    for (const char *start = path, *end; ; start = end + 1) {
        end = strchr(start, '/');
        size_t length = end ? (size_t)(end - start) : strlen(start);
        if (!length || length > 255 || (length == 1 && *start == '.') ||
            (length == 2 && start[0] == '.' && start[1] == '.')) return 0;
        if (!end) return 1;
    }
}

// Every path reaches libsmb2 through this, spelled as SMB clients send it.
static int composed_path(const char *path, char composed[1024])
{
    return tm_smb_compose(path, composed, 1024) && valid_path(composed);
}

static void opened(struct smb2_context *smb, int status, void *data, void *context)
{
    struct tm_edit_reply *reply = context;
    done(smb, status, data, context);
    if (!status && data) memcpy(reply->file, ((struct smb2_create_reply *)data)->file_id, SMB2_FD_SIZE);
    else if (!status) reply->error = EIO;
}

static int open_file(void *opaque, const char *path, uint32_t access, uint32_t sharing,
                     uint32_t disposition, uint8_t *file)
{
    struct edit_client *client = opaque;
    client->ntstatus = 0;
    struct smb2_context *smb = client->smb;
    if (!smb) return EIO;
    char name[1024];
    if (!composed_path(path, name)) return EINVAL;
    struct smb2_create_request request = {0};
    request.impersonation_level = SMB2_IMPERSONATION_IMPERSONATION;
    request.desired_access = access;
    request.share_access = sharing;
    request.create_disposition = disposition;
    request.create_options = SMB2_FILE_NON_DIRECTORY_FILE | SMB2_FILE_OPEN_REPARSE_POINT;
    request.name = name;
    struct tm_edit_reply reply = {0};
    int error = wait_reply(client, smb2_cmd_create_async(smb, &request, opened, &reply), &reply);
    if (!error) memcpy(file, reply.file, SMB2_FD_SIZE);
    return error;
}

int tm_edit_open(void *opaque, const char *path, uint32_t access, uint32_t sharing, uint8_t *file)
{
    return open_file(opaque, path, access, sharing, SMB2_FILE_OPEN, file);
}

int tm_edit_create(void *opaque, const char *path, uint32_t access, uint8_t *file)
{
    return open_file(opaque, path, access, 0, SMB2_FILE_CREATE, file);
}

int tm_edit_close(void *opaque, uint8_t *file)
{
    struct edit_client *client = opaque;
    client->ntstatus = 0;
    struct smb2_context *smb = client->smb;
    if (!smb) return EIO;
    struct smb2_close_request request = {0};
    memcpy(request.file_id, file, SMB2_FD_SIZE);
    struct tm_edit_reply reply = {0};
    return wait_reply(client, smb2_cmd_close_async(smb, &request, done, &reply), &reply);
}

static void closed_info(struct smb2_context *smb, int status, void *data, void *context)
{
    struct tm_edit_reply *reply = context;
    done(smb, status, data, context);
    const struct smb2_close_reply *info = data;
    if (status) return;
    const uint64_t epoch = 116444736000000000ULL;
    if (!info || !(info->flags & SMB2_CLOSE_FLAG_POSTQUERY_ATTRIB)
        || info->creation_time <= epoch || info->last_write_time < epoch || info->change_time < epoch) {
        reply->error = EIO;
        return;
    }
    reply->values[0] = (info->creation_time - epoch) / 10;
    reply->values[1] = (info->last_write_time - epoch) / 10;
    reply->values[2] = (info->change_time - epoch) / 10;
    reply->values[3] = info->end_of_file;
    reply->values[4] = info->file_attributes;
}

int tm_edit_close_info(void *opaque, uint8_t *file, uint64_t *values)
{
    struct edit_client *client = opaque;
    client->ntstatus = 0;
    if (!client->smb) return EIO;
    struct smb2_close_request request = {.flags = SMB2_CLOSE_FLAG_POSTQUERY_ATTRIB};
    memcpy(request.file_id, file, SMB2_FD_SIZE);
    struct tm_edit_reply reply = {0};
    int error = wait_reply(client, smb2_cmd_close_async(client->smb, &request, closed_info, &reply), &reply);
    if (!error) memcpy(values, reply.values, 5 * sizeof(uint64_t));
    return error;
}

int tm_edit_open_directory(void *opaque, const char *path, uint32_t access, uint32_t sharing,
                         uint8_t *file)
{
    struct edit_client *client = opaque;
    client->ntstatus = 0;
    struct smb2_context *smb = client->smb;
    if (!smb) return EIO;
    char name[1024] = "";
    if (!path || (*path && !composed_path(path, name))) return EINVAL;
    struct smb2_create_request request = {0};
    request.impersonation_level = SMB2_IMPERSONATION_IMPERSONATION;
    request.desired_access = access;
    request.share_access = sharing;
    request.create_disposition = SMB2_FILE_OPEN;
    request.create_options = SMB2_FILE_DIRECTORY_FILE | SMB2_FILE_OPEN_REPARSE_POINT;
    request.name = name;
    struct tm_edit_reply reply = {0};
    int error = wait_reply(client, smb2_cmd_create_async(smb, &request, opened, &reply), &reply);
    if (!error) memcpy(file, reply.file, SMB2_FD_SIZE);
    return error;
}

static void listed(struct smb2_context *smb, int status, void *data, void *context)
{
    struct tm_edit_reply *reply = context;
    struct smb2_query_directory_reply *info = data;
    done(smb, status, data, context);
    if ((uint32_t)status == SMB2_STATUS_NO_MORE_FILES) {
        reply->error = 0;
        reply->values[0] = 1;
    } else if (!status && info && info->output_buffer && info->output_buffer_length <= reply->capacity) {
        memcpy(reply->buffer, info->output_buffer, info->output_buffer_length);
        reply->count = info->output_buffer_length;
    } else if (!status) reply->error = EOVERFLOW;
}

int tm_edit_list(void *opaque, uint8_t *directory, int restart, uint8_t *buffer,
                 uint32_t capacity, uint32_t *count, int *finished)
{
    struct edit_client *client = opaque;
    client->ntstatus = 0;
    if (!client->smb) return EIO;
    if (!buffer || capacity < 80 || capacity > 65536) return EINVAL;
    struct smb2_query_directory_request request = {0};
    request.file_information_class = SMB2_FILE_ID_FULL_DIRECTORY_INFORMATION;
    request.flags = restart ? SMB2_RESTART_SCANS | SMB2_REOPEN : 0;
    request.name = "*";
    request.output_buffer_length = capacity;
    memcpy(request.file_id, directory, SMB2_FD_SIZE);
    struct tm_edit_reply reply = {.buffer = buffer, .capacity = capacity};
    int error = wait_reply(client, smb2_cmd_query_directory_async(client->smb, &request, listed, &reply), &reply);
    *count = reply.count;
    *finished = reply.values[0] != 0;
    return error;
}

int tm_edit_set_size(void *opaque, uint8_t *file, uint64_t size)
{
    struct edit_client *client = opaque;
    client->ntstatus = 0;
    struct smb2_context *smb = client->smb;
    if (!smb) return EIO;
    if (size > INT64_MAX) return EINVAL;
    struct smb2_file_end_of_file_info length = {.end_of_file = size};
    struct smb2_set_info_request request = {0};
    request.info_type = SMB2_0_INFO_FILE;
    request.file_info_class = SMB2_FILE_END_OF_FILE_INFORMATION;
    request.input_data = &length;
    memcpy(request.file_id, file, SMB2_FD_SIZE);
    struct tm_edit_reply reply = {0};
    return wait_reply(client, smb2_cmd_set_info_async(smb, &request, done, &reply), &reply);
}

static uint64_t microseconds(struct smb2_timeval value)
{
    return value.tv_sec > 0 && value.tv_usec < 1000000
        ? (uint64_t)value.tv_sec * 1000000 + value.tv_usec : 0;
}

static void inspected(struct smb2_context *smb, int status, void *data, void *context)
{
    struct tm_edit_reply *reply = context;
    struct smb2_file_all_info *info = !status && data
        ? ((struct smb2_query_info_reply *)data)->output_buffer : NULL;
    done(smb, status, data, context);
    if (!status && info) {
        reply->values[0] = info->index_number;
        reply->values[1] = microseconds(info->basic.creation_time);
        reply->values[2] = info->standard.end_of_file;
        reply->values[3] = info->standard.number_of_links;
        reply->values[4] = info->basic.file_attributes;
        reply->values[5] = microseconds(info->basic.last_write_time);
        reply->values[6] = microseconds(info->basic.change_time);
        reply->values[7] = info->ea_size;
    } else if (!status) reply->error = EIO;
    if (info) smb2_free_data(smb, info);
}

int tm_edit_info(void *opaque, uint8_t *file, uint64_t *values)
{
    struct edit_client *client = opaque;
    client->ntstatus = 0;
    struct smb2_context *smb = client->smb;
    if (!smb) return EIO;
    struct smb2_query_info_request request = {0};
    request.info_type = SMB2_0_INFO_FILE;
    request.file_info_class = SMB2_FILE_ALL_INFORMATION;
    request.output_buffer_length = 4096;
    memcpy(request.file_id, file, SMB2_FD_SIZE);
    struct tm_edit_reply reply = {0};
    int error = wait_reply(client, smb2_cmd_query_info_async(smb, &request, inspected, &reply), &reply);
    if (!error) memcpy(values, reply.values, sizeof(reply.values));
    return error;
}

static void read_done(struct smb2_context *smb, int status, void *data, void *context)
{
    struct tm_edit_reply *reply = context;
    done(smb, status, data, context);
    if (status) return;
    const struct smb2_read_reply *read = data;
    if (!read || !read->data_length || read->data_length > reply->capacity) reply->error = EIO;
    else reply->count = read->data_length;
}

static uint32_t payload_length(struct smb2_context *smb, uint32_t length, uint32_t maximum)
{
    // Raw requests need the same credit bound as libsmb2's high-level pread/pwrite.
    if (smb->credits <= 0) return 0;
    uint64_t available = smb->supports_multi_credit ? (uint64_t)smb->credits * 65536 : 65536;
    if (length > maximum) length = maximum;
    return length > available ? (uint32_t)available : length;
}

int tm_edit_read(void *opaque, uint8_t *file, uint64_t offset, uint8_t *buffer, uint32_t length,
               uint32_t *count)
{
    struct edit_client *client = opaque;
    client->ntstatus = 0;
    struct smb2_context *smb = client->smb;
    if (!smb) return EIO;
    if (!file || !buffer || !count || !length || length > 1024 * 1024 || offset > INT64_MAX
        || length > INT64_MAX - offset) return EINVAL;
    length = payload_length(smb, length, smb2_get_max_read_size(smb));
    if (!length) return EIO;
    struct smb2_read_request request = {0};
    request.offset = offset;
    request.length = length;
    request.buf = buffer;
    memcpy(request.file_id, file, SMB2_FD_SIZE);
    struct tm_edit_reply reply = {.capacity = length};
    int error = wait_reply(client, smb2_cmd_read_async(smb, &request, read_done, &reply), &reply);
    if (!error) *count = reply.count;
    return error;
}

static void write_done(struct smb2_context *smb, int status, void *data, void *context)
{
    struct tm_edit_reply *reply = context;
    done(smb, status, data, context);
    if (status) return;
    const struct smb2_write_reply *written = data;
    if (!written || !written->count || written->count > reply->capacity) reply->error = EIO;
    else reply->count = written->count;
}

int tm_edit_write(void *opaque, uint8_t *file, uint64_t offset, const uint8_t *buffer, uint32_t length,
                  uint32_t *count)
{
    struct edit_client *client = opaque;
    client->ntstatus = 0;
    if (!client->smb) return EIO;
    if (!file || !buffer || !count || !length || length > 1024 * 1024 || offset > INT64_MAX
        || length > INT64_MAX - offset) return EINVAL;
    length = payload_length(client->smb, length, smb2_get_max_write_size(client->smb));
    if (!length) return EIO;
    struct smb2_write_request request = {.offset = offset, .length = length, .buf = buffer};
    memcpy(request.file_id, file, SMB2_FD_SIZE);
    struct tm_edit_reply reply = {.capacity = length};
    int error = wait_reply(client,
        smb2_cmd_write_async(client->smb, &request, 0, write_done, &reply), &reply);
    if (!error) *count = reply.count;
    return error;
}

int tm_edit_rename(void *opaque, uint8_t *file, const char *destination)
{
    struct edit_client *client = opaque;
    client->ntstatus = 0;
    struct smb2_context *smb = client->smb;
    if (!smb) return EIO;
    char target[1024];
    if (!composed_path(destination, target)) return EINVAL;
    for (char *p = target; *p; ++p) if (*p == '/') *p = '\\';
    struct smb2_file_rename_info name = {.replace_if_exist = 0, .file_name = (const uint8_t *)target};
    struct smb2_set_info_request request = {0};
    request.info_type = SMB2_0_INFO_FILE;
    request.file_info_class = SMB2_FILE_RENAME_INFORMATION;
    request.input_data = &name;
    memcpy(request.file_id, file, SMB2_FD_SIZE);
    struct tm_edit_reply reply = {0};
    return wait_reply(client, smb2_cmd_set_info_async(smb, &request, done, &reply), &reply);
}

int tm_edit_delete(void *opaque, uint8_t *file)
{
    struct edit_client *client = opaque;
    client->ntstatus = 0;
    struct smb2_context *smb = client->smb;
    if (!smb) return EIO;
    struct smb2_file_disposition_info disposition = {.delete_pending = 1};
    struct smb2_set_info_request request = {0};
    request.info_type = SMB2_0_INFO_FILE;
    request.file_info_class = SMB2_FILE_DISPOSITION_INFORMATION;
    request.input_data = &disposition;
    memcpy(request.file_id, file, SMB2_FD_SIZE);
    struct tm_edit_reply reply = {0};
    return wait_reply(client, smb2_cmd_set_info_async(smb, &request, done, &reply), &reply);
}

int tm_edit_flush(void *opaque, uint8_t *file)
{
    struct edit_client *client = opaque;
    client->ntstatus = 0;
    struct smb2_context *smb = client->smb;
    if (!smb) return EIO;
    struct smb2_flush_request request = {0};
    memcpy(request.file_id, file, SMB2_FD_SIZE);
    struct tm_edit_reply reply = {0};
    return wait_reply(client, smb2_cmd_flush_async(smb, &request, done, &reply), &reply);
}
