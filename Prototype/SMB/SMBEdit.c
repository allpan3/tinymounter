#include "SMBEdit.h"
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

struct tm_edit_reply {
    int done, error;
    smb2_file_id file;
    uint64_t values[8];
    uint32_t count;
    uint8_t *buffer;
    uint32_t capacity;
};

struct edit_client { struct smb2_context *smb; };
extern void *tm_smb_begin_edit(const char *, const char *, const char *, int *);
extern void tm_smb_end_edit(void *);

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

static void done(struct smb2_context *smb, int status, void *data, void *context)
{
    struct tm_edit_reply *reply = context;
    reply->error = status ? nterror_to_errno((uint32_t)status) : 0;
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
        if (smb2_service(client->smb, fd.revents) < 0) { error = EIO; break; }
        clock_gettime(CLOCK_MONOTONIC, &now);
        if (!reply->done && now.tv_sec - start.tv_sec >= 12) { error = ETIMEDOUT; break; }
    }
    if (error) {
        // Destroy queued callbacks while their reply storage is still alive.
        smb2_destroy_context(client->smb);
        client->smb = NULL;
        return error;
    }
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

static void opened(struct smb2_context *smb, int status, void *data, void *context)
{
    struct tm_edit_reply *reply = context;
    done(smb, status, data, context);
    if (!status && data) memcpy(reply->file, ((struct smb2_create_reply *)data)->file_id, SMB2_FD_SIZE);
    else if (!status) reply->error = EIO;
}

int tm_edit_open(void *opaque, const char *path, uint32_t access, uint32_t sharing,
               uint8_t *file)
{
    struct edit_client *client = opaque;
    struct smb2_context *smb = client->smb;
    if (!smb) return EIO;
    if (!valid_path(path)) return EINVAL;
    struct smb2_create_request request = {0};
    request.impersonation_level = SMB2_IMPERSONATION_IMPERSONATION;
    request.desired_access = access;
    request.share_access = sharing;
    request.create_disposition = SMB2_FILE_OPEN;
    request.create_options = SMB2_FILE_NON_DIRECTORY_FILE | SMB2_FILE_OPEN_REPARSE_POINT;
    request.name = path;
    struct tm_edit_reply reply = {0};
    int error = wait_reply(client, smb2_cmd_create_async(smb, &request, opened, &reply), &reply);
    if (!error) memcpy(file, reply.file, SMB2_FD_SIZE);
    return error;
}

int tm_edit_open_quarantine(void *opaque, const char *path, uint8_t *file)
{
    struct edit_client *client = opaque;
    struct smb2_context *smb = client->smb;
    if (!smb) return EIO;
    if (!valid_path(path)) return EINVAL;
    char name[1088];
    snprintf(name, sizeof(name), "%s:com.apple.quarantine:$DATA", path);
    struct smb2_create_request request = {0};
    request.impersonation_level = SMB2_IMPERSONATION_IMPERSONATION;
    request.desired_access = SMB2_FILE_READ_DATA | SMB2_FILE_READ_ATTRIBUTES;
    request.share_access = SMB2_FILE_SHARE_READ | SMB2_FILE_SHARE_DELETE;
    request.create_disposition = SMB2_FILE_OPEN;
    request.create_options = SMB2_FILE_NON_DIRECTORY_FILE | SMB2_FILE_OPEN_REPARSE_POINT;
    request.name = name;
    struct tm_edit_reply reply = {0};
    int error = wait_reply(client, smb2_cmd_create_async(smb, &request, opened, &reply), &reply);
    if (!error) memcpy(file, reply.file, SMB2_FD_SIZE);
    return error;
}

int tm_edit_close(void *opaque, uint8_t *file)
{
    struct edit_client *client = opaque;
    struct smb2_context *smb = client->smb;
    if (!smb) return EIO;
    struct smb2_close_request request = {0};
    memcpy(request.file_id, file, SMB2_FD_SIZE);
    struct tm_edit_reply reply = {0};
    return wait_reply(client, smb2_cmd_close_async(smb, &request, done, &reply), &reply);
}

int tm_edit_open_directory(void *opaque, const char *path, uint32_t access, uint32_t sharing,
                         uint8_t *file)
{
    struct edit_client *client = opaque;
    struct smb2_context *smb = client->smb;
    if (!smb) return EIO;
    if (!path || (*path && !valid_path(path))) return EINVAL;
    struct smb2_create_request request = {0};
    request.impersonation_level = SMB2_IMPERSONATION_IMPERSONATION;
    request.desired_access = access;
    request.share_access = sharing;
    request.create_disposition = SMB2_FILE_OPEN;
    request.create_options = SMB2_FILE_DIRECTORY_FILE | SMB2_FILE_OPEN_REPARSE_POINT;
    request.name = path;
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

static void little16(uint8_t *out, uint16_t value)
{
    for (int i = 0; i < 2; ++i) out[i] = (uint8_t)(value >> (8 * i));
}

static void little32(uint8_t *out, uint32_t value)
{
    for (int i = 0; i < 4; ++i) out[i] = (uint8_t)(value >> (8 * i));
}

static void little64(uint8_t *out, uint64_t value)
{
    for (int i = 0; i < 8; ++i) out[i] = (uint8_t)(value >> (8 * i));
}

int tm_edit_open_private(void *opaque, const char *path, uint32_t access, uint32_t sharing,
                       const uint8_t *security, uint32_t length, uint8_t *file)
{
    struct edit_client *client = opaque;
    struct smb2_context *smb = client->smb;
    if (!smb) return EIO;
    if (!valid_path(path) || !security || length < 20 || length > 4096) return EINVAL;
    uint32_t context_length = (24 + length + 7) & ~7;
    uint8_t *context = calloc(1, context_length);
    if (!context) return ENOMEM;
    little16(context + 4, 16);
    little16(context + 6, 4);
    little16(context + 10, 24);
    little32(context + 12, length);
    memcpy(context + 16, "SecD", 4);
    memcpy(context + 24, security, length);
    struct smb2_create_request request = {0};
    request.impersonation_level = SMB2_IMPERSONATION_IMPERSONATION;
    request.desired_access = access;
    request.share_access = sharing;
    request.create_disposition = SMB2_FILE_CREATE;
    request.create_options = SMB2_FILE_NON_DIRECTORY_FILE | SMB2_FILE_OPEN_REPARSE_POINT;
    request.name = path;
    request.create_context_length = context_length;
    request.create_context = context;
    struct tm_edit_reply reply = {0};
    int error = wait_reply(client, smb2_cmd_create_async(smb, &request, opened, &reply), &reply);
    free(context);
    if (!error) memcpy(file, reply.file, SMB2_FD_SIZE);
    return error;
}

static void ioctl_done(struct smb2_context *smb, int status, void *data, void *context)
{
    struct tm_edit_reply *reply = context;
    struct smb2_ioctl_reply *info = data;
    done(smb, status, data, context);
    if (!status && info && info->output && info->output_count <= reply->capacity) {
        memcpy(reply->buffer, info->output, info->output_count);
        reply->count = info->output_count;
    } else if (!status) reply->error = EOVERFLOW;
    if (!status && info && info->output) smb2_free_data(smb, info->output);
}

int tm_edit_resume_key(void *opaque, uint8_t *file, uint8_t *key)
{
    struct edit_client *client = opaque;
    struct smb2_context *smb = client->smb;
    if (!smb) return EIO;
    uint8_t buffer[64];
    struct smb2_ioctl_request request = {.ctl_code = SMB2_FSCTL_SRV_REQUEST_RESUME_KEY, .flags = 1};
    memcpy(request.file_id, file, SMB2_FD_SIZE);
    struct tm_edit_reply reply = {.buffer = buffer, .capacity = sizeof(buffer)};
    int error = wait_reply(client, smb2_cmd_ioctl_async(smb, &request, ioctl_done, &reply), &reply);
    if (!error && reply.count < 28) return EIO;
    if (!error) memcpy(key, buffer, 24);
    return error;
}

int tm_edit_copy_chunk(void *opaque, uint8_t *target, const uint8_t *key, uint64_t source_offset,
                     uint64_t target_offset, uint32_t length, uint8_t *result)
{
    struct edit_client *client = opaque;
    struct smb2_context *smb = client->smb;
    if (!smb) return EIO;
    const uint64_t limit = INT64_MAX;
    if (!length || length > 1024 * 1024 || source_offset > limit || target_offset > limit ||
        length > limit - source_offset || length > limit - target_offset) return EINVAL;
    uint8_t input[56] = {0};
    memcpy(input, key, 24);
    little32(input + 24, 1);
    little64(input + 32, source_offset);
    little64(input + 40, target_offset);
    little32(input + 48, length);
    struct smb2_ioctl_request request = {.ctl_code = SMB2_FSCTL_SRV_COPYCHUNK, .flags = 1,
                                         .input = input, .input_count = sizeof(input)};
    memcpy(request.file_id, target, SMB2_FD_SIZE);
    struct tm_edit_reply reply = {.buffer = result, .capacity = 12};
    int error = wait_reply(client, smb2_cmd_ioctl_async(smb, &request, ioctl_done, &reply), &reply);
    return !error && reply.count != 12 ? EIO : error;
}

int tm_edit_set_size(void *opaque, uint8_t *file, uint64_t size)
{
    struct edit_client *client = opaque;
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
    struct smb2_file_all_info *info = data ? ((struct smb2_query_info_reply *)data)->output_buffer : NULL;
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
    if (!status && data) reply->count = ((struct smb2_read_reply *)data)->data_length;
    else if (!status) reply->error = EIO;
}

int tm_edit_read(void *opaque, uint8_t *file, uint64_t offset, uint8_t *buffer, uint32_t length,
               uint32_t *count)
{
    struct edit_client *client = opaque;
    struct smb2_context *smb = client->smb;
    if (!smb) return EIO;
    struct smb2_read_request request = {0};
    request.offset = offset;
    request.length = length;
    request.buf = buffer;
    memcpy(request.file_id, file, SMB2_FD_SIZE);
    struct tm_edit_reply reply = {0};
    int error = wait_reply(client, smb2_cmd_read_async(smb, &request, read_done, &reply), &reply);
    *count = reply.count;
    return error;
}

int tm_edit_rename(void *opaque, uint8_t *file, const char *destination)
{
    struct edit_client *client = opaque;
    struct smb2_context *smb = client->smb;
    if (!smb) return EIO;
    if (!valid_path(destination)) return EINVAL;
    char target[1024];
    strcpy(target, destination);
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
    struct smb2_context *smb = client->smb;
    if (!smb) return EIO;
    struct smb2_flush_request request = {0};
    memcpy(request.file_id, file, SMB2_FD_SIZE);
    struct tm_edit_reply reply = {0};
    return wait_reply(client, smb2_cmd_flush_async(smb, &request, done, &reply), &reply);
}

static void queried(struct smb2_context *smb, int status, void *data, void *context)
{
    struct tm_edit_reply *reply = context;
    struct smb2_query_info_reply *info = data;
    done(smb, status, data, context);
    if (!status && info && info->output_buffer && info->output_buffer_length <= reply->capacity) {
        memcpy(reply->buffer, info->output_buffer, info->output_buffer_length);
        reply->count = info->output_buffer_length;
    } else if (!status) reply->error = EOVERFLOW;
    if (info && info->output_buffer) smb2_free_data(smb, info->output_buffer);
}

int tm_edit_metadata(void *opaque, uint8_t *file, int security, uint8_t *buffer,
                   uint32_t capacity, uint32_t *count)
{
    struct edit_client *client = opaque;
    struct smb2_context *smb = client->smb;
    if (!smb) return EIO;
    struct smb2_query_info_request request = {0};
    request.info_type = security ? SMB2_0_INFO_SECURITY : SMB2_0_INFO_FILE;
    request.file_info_class = security ? 0 : SMB2_FILE_STREAM_INFORMATION;
    request.additional_information = (uint32_t)security;
    request.output_buffer_length = capacity;
    memcpy(request.file_id, file, SMB2_FD_SIZE);
    struct tm_edit_reply reply = {.buffer = buffer, .capacity = capacity};
    smb2_set_passthrough(smb, 1);
    int error = wait_reply(client, smb2_cmd_query_info_async(smb, &request, queried, &reply), &reply);
    if (client->smb) smb2_set_passthrough(client->smb, 0);
    *count = reply.count;
    return error;
}

int tm_edit_set_metadata(void *opaque, uint8_t *file, int security,
                       uint8_t *buffer, uint32_t length)
{
    struct edit_client *client = opaque;
    struct smb2_context *smb = client->smb;
    if (!smb) return EIO;
    if (!security || !buffer || length > 4096 || length < 20) return EINVAL;
    struct smb2_set_info_request request = {0};
    request.info_type = security ? SMB2_0_INFO_SECURITY : SMB2_0_INFO_FILE;
    request.file_info_class = security ? 0 : SMB2_FILE_BASIC_INFORMATION;
    request.additional_information = security ? SMB2_DACL_SECURITY_INFORMATION : 0;
    request.input_data = buffer;
    request.buffer_length = length;
    request.buffer_offset = 96;
    memcpy(request.file_id, file, SMB2_FD_SIZE);
    struct tm_edit_reply reply = {0};
    smb2_set_passthrough(smb, 1);
    int error = wait_reply(client, smb2_cmd_set_info_async(smb, &request, done, &reply), &reply);
    if (client->smb) smb2_set_passthrough(client->smb, 0);
    return error;
}
