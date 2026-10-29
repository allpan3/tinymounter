#include <errno.h>
#include <poll.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <smb2/smb2.h>
#include <smb2/libsmb2.h>
#include <smb2/libsmb2-raw.h>

struct probe_reply {
    int done, error;
    smb2_file_id file;
    uint64_t values[8];
    uint32_t count;
    uint8_t *buffer;
    uint32_t capacity;
};

static _Thread_local uint32_t last_status;
uint32_t probe_status(void) { return last_status; }

static void done(struct smb2_context *smb, int status, void *data, void *context)
{
    struct probe_reply *reply = context;
    last_status = (uint32_t)status;
    reply->error = status ? nterror_to_errno((uint32_t)status) : 0;
    reply->done = 1;
}

static int wait_reply(struct smb2_context *smb, struct smb2_pdu *pdu, struct probe_reply *reply)
{
    if (!pdu) return EIO;
    smb2_queue_pdu(smb, pdu);
    struct timespec start, now;
    clock_gettime(CLOCK_MONOTONIC, &start);
    while (!reply->done) {
        struct pollfd fd = {.fd = smb2_get_fd(smb), .events = smb2_which_events(smb)};
        /* Queued callbacks retain stack storage; an uncertain connection cannot be reused. */
        if (poll(&fd, 1, 100) < 0 && errno != EINTR) {
            fputs("fixture transport poll failed\n", stderr);
            _Exit(70);
        }
        if (smb2_service(smb, fd.revents) < 0) {
            fputs("fixture transport connection failed\n", stderr);
            _Exit(70);
        }
        clock_gettime(CLOCK_MONOTONIC, &now);
        if (now.tv_sec - start.tv_sec > 12) {
            fputs("fixture transport request timed out\n", stderr);
            _Exit(70);
        }
    }
    return reply->error;
}

static void *connect_fixture(const char *password, int observer, int *error)
{
    struct smb2_context *smb = smb2_init_context();
    *error = ENOMEM;
    if (!smb) return NULL;
    smb2_set_timeout(smb, 45);
    smb2_set_authentication(smb, 1);
    smb2_set_user(smb, observer ? "_tinymounter_m19_observer" : password ? "_tinymounter_m19" : "guest");
    smb2_set_password(smb, password ? password : "");
    if (password) {
        smb2_set_sign(smb, 1);
        smb2_set_seal(smb, 1);
    }
    int result = smb2_connect_share(smb, "127.0.0.1", "tinymounter-m19-edit-test", NULL);
    if (result) {
        *error = result < 0 ? -result : EIO;
        smb2_destroy_context(smb);
        return NULL;
    }
    *error = 0;
    return smb;
}

void *probe_connect(const char *password, int *error) { return connect_fixture(password, 0, error); }
void *probe_connect_observer(const char *password, int *error) { return connect_fixture(password, 1, error); }

void probe_disconnect(void *smb) { smb2_destroy_context(smb); }

static int fixture_path(const char *path)
{
    if (!path || !*path || strlen(path) >= 480 || strchr(path, '\\') || strchr(path, ':')) return 0;
    for (const char *part = path; part; ) {
        if (strncmp(part, "probe-", 6)) return 0;
        const char *end = strchr(part, '/');
        size_t length = end ? (size_t)(end - part) : strlen(part);
        if (length < 7 || length >= 240) return 0;
        for (size_t i = 6; i < length; ++i) {
            unsigned char c = (unsigned char)part[i];
            if ((c < 'a' || c > 'z') && (c < 'A' || c > 'Z') &&
                (c < '0' || c > '9') && c != '-' && c < 0x80) return 0;
        }
        part = end ? end + 1 : NULL;
    }
    return 1;
}

static void opened(struct smb2_context *smb, int status, void *data, void *context)
{
    struct probe_reply *reply = context;
    done(smb, status, data, context);
    if (!status && data) memcpy(reply->file, ((struct smb2_create_reply *)data)->file_id, SMB2_FD_SIZE);
    else if (!status) reply->error = EIO;
}

int probe_open(void *smb, const char *path, uint32_t access, uint32_t sharing,
               int create_new, uint8_t *file)
{
    if (!fixture_path(path)) return EINVAL;
    struct smb2_create_request request = {0};
    request.impersonation_level = SMB2_IMPERSONATION_IMPERSONATION;
    request.desired_access = access;
    request.share_access = sharing;
    request.create_disposition = create_new ? SMB2_FILE_CREATE : SMB2_FILE_OPEN;
    request.create_options = SMB2_FILE_NON_DIRECTORY_FILE | SMB2_FILE_OPEN_REPARSE_POINT;
    request.name = path;
    struct probe_reply reply = {0};
    int error = wait_reply(smb, smb2_cmd_create_async(smb, &request, opened, &reply), &reply);
    if (!error) memcpy(file, reply.file, SMB2_FD_SIZE);
    return error;
}

int probe_close(void *smb, uint8_t *file)
{
    struct smb2_close_request request = {0};
    memcpy(request.file_id, file, SMB2_FD_SIZE);
    struct probe_reply reply = {0};
    return wait_reply(smb, smb2_cmd_close_async(smb, &request, done, &reply), &reply);
}

int probe_open_directory(void *smb, const char *path, uint32_t access, uint32_t sharing,
                         int create_new, uint8_t *file)
{
    if (!path || (*path && !fixture_path(path))) return EINVAL;
    struct smb2_create_request request = {0};
    request.impersonation_level = SMB2_IMPERSONATION_IMPERSONATION;
    request.desired_access = access;
    request.share_access = sharing;
    request.create_disposition = create_new ? SMB2_FILE_CREATE : SMB2_FILE_OPEN;
    request.create_options = SMB2_FILE_DIRECTORY_FILE | SMB2_FILE_OPEN_REPARSE_POINT;
    request.name = path;
    struct probe_reply reply = {0};
    int error = wait_reply(smb, smb2_cmd_create_async(smb, &request, opened, &reply), &reply);
    if (!error) memcpy(file, reply.file, SMB2_FD_SIZE);
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

int probe_open_private(void *smb, const char *path, uint32_t access, uint32_t sharing,
                       const uint8_t *security, uint32_t length, uint8_t *file)
{
    if (!fixture_path(path) || !security || length < 20 || length > 4096) return EINVAL;
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
    struct probe_reply reply = {0};
    int error = wait_reply(smb, smb2_cmd_create_async(smb, &request, opened, &reply), &reply);
    free(context);
    if (!error) memcpy(file, reply.file, SMB2_FD_SIZE);
    return error;
}

static void ioctl_done(struct smb2_context *smb, int status, void *data, void *context)
{
    struct probe_reply *reply = context;
    struct smb2_ioctl_reply *info = data;
    done(smb, status, data, context);
    if (!status && info && info->output && info->output_count <= reply->capacity) {
        memcpy(reply->buffer, info->output, info->output_count);
        reply->count = info->output_count;
    } else if (!status) reply->error = EOVERFLOW;
    if (!status && info && info->output) smb2_free_data(smb, info->output);
}

int probe_resume_key(void *smb, uint8_t *file, uint8_t *key)
{
    uint8_t buffer[64];
    struct smb2_ioctl_request request = {.ctl_code = SMB2_FSCTL_SRV_REQUEST_RESUME_KEY, .flags = 1};
    memcpy(request.file_id, file, SMB2_FD_SIZE);
    struct probe_reply reply = {.buffer = buffer, .capacity = sizeof(buffer)};
    int error = wait_reply(smb, smb2_cmd_ioctl_async(smb, &request, ioctl_done, &reply), &reply);
    if (!error && reply.count < 28) return EIO;
    if (!error) memcpy(key, buffer, 24);
    return error;
}

int probe_copy_chunk(void *smb, uint8_t *target, const uint8_t *key, uint64_t source_offset,
                     uint64_t target_offset, uint32_t length, uint8_t *result)
{
    const uint64_t limit = 16 * 1024 * 1024;
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
    struct probe_reply reply = {.buffer = result, .capacity = 12};
    int error = wait_reply(smb, smb2_cmd_ioctl_async(smb, &request, ioctl_done, &reply), &reply);
    return !error && reply.count != 12 ? EIO : error;
}

int probe_set_size(void *smb, uint8_t *file, uint64_t size)
{
    if (size > 16 * 1024 * 1024) return EINVAL;
    struct smb2_file_end_of_file_info length = {.end_of_file = size};
    struct smb2_set_info_request request = {0};
    request.info_type = SMB2_0_INFO_FILE;
    request.file_info_class = SMB2_FILE_END_OF_FILE_INFORMATION;
    request.input_data = &length;
    memcpy(request.file_id, file, SMB2_FD_SIZE);
    struct probe_reply reply = {0};
    return wait_reply(smb, smb2_cmd_set_info_async(smb, &request, done, &reply), &reply);
}

static uint64_t microseconds(struct smb2_timeval value)
{
    return (uint64_t)value.tv_sec * 1000000 + value.tv_usec;
}

static void inspected(struct smb2_context *smb, int status, void *data, void *context)
{
    struct probe_reply *reply = context;
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

int probe_info(void *smb, uint8_t *file, uint64_t *values)
{
    struct smb2_query_info_request request = {0};
    request.info_type = SMB2_0_INFO_FILE;
    request.file_info_class = SMB2_FILE_ALL_INFORMATION;
    request.output_buffer_length = 4096;
    memcpy(request.file_id, file, SMB2_FD_SIZE);
    struct probe_reply reply = {0};
    int error = wait_reply(smb, smb2_cmd_query_info_async(smb, &request, inspected, &reply), &reply);
    if (!error) memcpy(values, reply.values, sizeof(reply.values));
    return error;
}

static void named(struct smb2_context *smb, int status, void *data, void *context)
{
    struct probe_reply *reply = context;
    struct smb2_file_all_info *info = data ? ((struct smb2_query_info_reply *)data)->output_buffer : NULL;
    done(smb, status, data, context);
    if (!status && info && info->name) {
        size_t length = strlen((const char *)info->name);
        if (length >= reply->capacity) reply->error = ENAMETOOLONG;
        else { memcpy(reply->buffer, info->name, length + 1); reply->count = (uint32_t)length; }
    } else if (!status) reply->error = EIO;
    if (info) smb2_free_data(smb, info);
}

int probe_name(void *smb, uint8_t *file, uint8_t *buffer, uint32_t capacity, uint32_t *count)
{
    struct smb2_query_info_request request = {0};
    request.info_type = SMB2_0_INFO_FILE;
    request.file_info_class = SMB2_FILE_ALL_INFORMATION;
    request.output_buffer_length = 4096;
    memcpy(request.file_id, file, SMB2_FD_SIZE);
    struct probe_reply reply = {.buffer = buffer, .capacity = capacity};
    int error = wait_reply(smb, smb2_cmd_query_info_async(smb, &request, named, &reply), &reply);
    *count = reply.count;
    return error;
}

static void listed(struct smb2_context *smb, int status, void *data, void *context)
{
    struct probe_reply *reply = context;
    struct smb2_query_directory_reply *info = data;
    done(smb, status, data, context);
    if (!status && info && info->output_buffer && info->output_buffer_length <= reply->capacity) {
        memcpy(reply->buffer, info->output_buffer, info->output_buffer_length);
        reply->count = info->output_buffer_length;
    } else if (!status) reply->error = EOVERFLOW;
}

int probe_entry(void *smb, uint8_t *directory, const char *name,
                uint8_t *buffer, uint32_t capacity, uint32_t *count)
{
    if (!fixture_path(name) || strchr(name, '/')) return EINVAL;
    struct smb2_query_directory_request request = {0};
    request.file_information_class = SMB2_FILE_ID_FULL_DIRECTORY_INFORMATION;
    request.flags = SMB2_RESTART_SCANS | SMB2_REOPEN;
    request.name = "*";
    request.output_buffer_length = capacity;
    memcpy(request.file_id, directory, SMB2_FD_SIZE);
    struct probe_reply reply = {.buffer = buffer, .capacity = capacity};
    int error = wait_reply(smb, smb2_cmd_query_directory_async(smb, &request, listed, &reply), &reply);
    *count = reply.count;
    return error;
}

static void read_done(struct smb2_context *smb, int status, void *data, void *context)
{
    struct probe_reply *reply = context;
    done(smb, status, data, context);
    if (!status && data) reply->count = ((struct smb2_read_reply *)data)->data_length;
    else if (!status) reply->error = EIO;
}

int probe_read(void *smb, uint8_t *file, uint64_t offset, uint8_t *buffer, uint32_t length,
               uint32_t *count)
{
    struct smb2_read_request request = {0};
    request.offset = offset;
    request.length = length;
    request.buf = buffer;
    memcpy(request.file_id, file, SMB2_FD_SIZE);
    struct probe_reply reply = {0};
    int error = wait_reply(smb, smb2_cmd_read_async(smb, &request, read_done, &reply), &reply);
    *count = reply.count;
    return error;
}

int probe_rename(void *smb, uint8_t *file, const char *destination)
{
    if (!fixture_path(destination)) return EINVAL;
    struct smb2_file_rename_info name = {.replace_if_exist = 0, .file_name = (const uint8_t *)destination};
    struct smb2_set_info_request request = {0};
    request.info_type = SMB2_0_INFO_FILE;
    request.file_info_class = SMB2_FILE_RENAME_INFORMATION;
    request.input_data = &name;
    memcpy(request.file_id, file, SMB2_FD_SIZE);
    struct probe_reply reply = {0};
    return wait_reply(smb, smb2_cmd_set_info_async(smb, &request, done, &reply), &reply);
}

int probe_delete(void *smb, uint8_t *file)
{
    struct smb2_file_disposition_info disposition = {.delete_pending = 1};
    struct smb2_set_info_request request = {0};
    request.info_type = SMB2_0_INFO_FILE;
    request.file_info_class = SMB2_FILE_DISPOSITION_INFORMATION;
    request.input_data = &disposition;
    memcpy(request.file_id, file, SMB2_FD_SIZE);
    struct probe_reply reply = {0};
    return wait_reply(smb, smb2_cmd_set_info_async(smb, &request, done, &reply), &reply);
}

int probe_flush(void *smb, uint8_t *file)
{
    struct smb2_flush_request request = {0};
    memcpy(request.file_id, file, SMB2_FD_SIZE);
    struct probe_reply reply = {0};
    return wait_reply(smb, smb2_cmd_flush_async(smb, &request, done, &reply), &reply);
}

static void queried(struct smb2_context *smb, int status, void *data, void *context)
{
    struct probe_reply *reply = context;
    struct smb2_query_info_reply *info = data;
    done(smb, status, data, context);
    if (!status && info && info->output_buffer && info->output_buffer_length <= reply->capacity) {
        memcpy(reply->buffer, info->output_buffer, info->output_buffer_length);
        reply->count = info->output_buffer_length;
    } else if (!status) reply->error = EOVERFLOW;
    if (info && info->output_buffer) smb2_free_data(smb, info->output_buffer);
}

int probe_metadata(void *smb, uint8_t *file, int security, uint8_t *buffer,
                   uint32_t capacity, uint32_t *count)
{
    struct smb2_query_info_request request = {0};
    request.info_type = security ? SMB2_0_INFO_SECURITY : SMB2_0_INFO_FILE;
    request.file_info_class = security ? 0 : SMB2_FILE_STREAM_INFORMATION;
    request.additional_information = (uint32_t)security;
    request.output_buffer_length = capacity;
    memcpy(request.file_id, file, SMB2_FD_SIZE);
    struct probe_reply reply = {.buffer = buffer, .capacity = capacity};
    smb2_set_passthrough(smb, 1);
    int error = wait_reply(smb, smb2_cmd_query_info_async(smb, &request, queried, &reply), &reply);
    smb2_set_passthrough(smb, 0);
    *count = reply.count;
    return error;
}

int probe_set_metadata(void *smb, uint8_t *file, int security,
                       uint8_t *buffer, uint32_t length)
{
    if (!buffer || length > 65536 || (security ? length < 20 : length != 40)) return EINVAL;
    struct smb2_set_info_request request = {0};
    request.info_type = security ? SMB2_0_INFO_SECURITY : SMB2_0_INFO_FILE;
    request.file_info_class = security ? 0 : SMB2_FILE_BASIC_INFORMATION;
    request.additional_information = security ? SMB2_DACL_SECURITY_INFORMATION : 0;
    request.input_data = buffer;
    request.buffer_length = length;
    request.buffer_offset = 96;
    memcpy(request.file_id, file, SMB2_FD_SIZE);
    struct probe_reply reply = {0};
    smb2_set_passthrough(smb, 1);
    int error = wait_reply(smb, smb2_cmd_set_info_async(smb, &request, done, &reply), &reply);
    smb2_set_passthrough(smb, 0);
    return error;
}

static int open_stream(void *smb, const char *path, int create, uint8_t *file)
{
    if (!fixture_path(path)) return EINVAL;
    char name[512];
    size_t length = strlen(path);
    memcpy(name, path, length);
    strcpy(name + length, ":m19-probe:$DATA");
    struct smb2_create_request request = {0};
    request.impersonation_level = SMB2_IMPERSONATION_IMPERSONATION;
    request.desired_access = (create ? SMB2_FILE_WRITE_DATA : SMB2_FILE_READ_DATA) | SMB2_FILE_READ_ATTRIBUTES;
    request.share_access = SMB2_FILE_SHARE_READ | SMB2_FILE_SHARE_WRITE | SMB2_FILE_SHARE_DELETE;
    request.create_disposition = create ? SMB2_FILE_CREATE : SMB2_FILE_OPEN;
    request.create_options = SMB2_FILE_NON_DIRECTORY_FILE | SMB2_FILE_OPEN_REPARSE_POINT;
    request.name = name;
    struct probe_reply reply = {0};
    int error = wait_reply(smb, smb2_cmd_create_async(smb, &request, opened, &reply), &reply);
    if (!error) memcpy(file, reply.file, SMB2_FD_SIZE);
    return error;
}

int probe_open_stream(void *smb, const char *path, uint8_t *file) { return open_stream(smb, path, 1, file); }
int probe_open_read_stream(void *smb, const char *path, uint8_t *file) { return open_stream(smb, path, 0, file); }

int probe_write_stream(void *smb, uint8_t *file)
{
    static const char contents[] = "competing synthetic stream\n";
    struct smb2_write_request request = {0};
    request.length = sizeof(contents) - 1;
    request.buf = (const uint8_t *)contents;
    request.flags = SMB2_WRITEFLAG_WRITE_THROUGH;
    memcpy(request.file_id, file, SMB2_FD_SIZE);
    struct probe_reply reply = {0};
    return wait_reply(smb, smb2_cmd_write_async(smb, &request, 0, done, &reply), &reply);
}
