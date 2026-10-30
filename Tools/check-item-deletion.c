/* Includes the M19 helper so this probe keeps its fixture endpoint, path guard and transport. */
#include "check-edit-publication.c"

void probe_clear_status(void) { last_status = 0; }

static void listed_page(struct smb2_context *smb, int status, void *data, void *context)
{
    struct probe_reply *reply = context;
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

int probe_list(void *smb, uint8_t *directory, int restart, uint8_t *buffer,
               uint32_t capacity, uint32_t *count, int *finished)
{
    if (!buffer || capacity < 80 || capacity > 65536) return EINVAL;
    struct smb2_query_directory_request request = {0};
    request.file_information_class = SMB2_FILE_ID_FULL_DIRECTORY_INFORMATION;
    request.flags = restart ? SMB2_RESTART_SCANS | SMB2_REOPEN : 0;
    request.name = "*";
    request.output_buffer_length = capacity;
    memcpy(request.file_id, directory, SMB2_FD_SIZE);
    struct probe_reply reply = {.buffer = buffer, .capacity = capacity};
    int error = wait_reply(smb, smb2_cmd_query_directory_async(smb, &request, listed_page, &reply), &reply);
    *count = reply.count;
    *finished = reply.values[0] != 0;
    return error;
}
