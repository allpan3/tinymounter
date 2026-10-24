#include "SMBRename.h"
#include <CoreFoundation/CoreFoundation.h>
#include <GSS/GSS.h>
#include <dispatch/dispatch.h>
#include <errno.h>
#include <poll.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <smb2/smb2.h>
#include <smb2/libsmb2.h>
#include <smb2/libsmb2-raw.h>

static pthread_mutex_t client_lock = PTHREAD_MUTEX_INITIALIZER;

struct credential_lookup {
    atomic_int references;
    dispatch_semaphore_t finished;
    char *server, *account, *domain, *principal;
    int ambiguous;
};

static void release_lookup(struct credential_lookup *lookup)
{
    if (atomic_fetch_sub(&lookup->references, 1) != 1) return;
    dispatch_release(lookup->finished);
    free(lookup->server);
    free(lookup->account);
    free(lookup->domain);
    free(lookup->principal);
    free(lookup);
}

static void credential(void *context, gss_iter_OID mechanism, gss_cred_id_t cred)
{
    struct credential_lookup *lookup = context;
    if (!cred) {
        dispatch_semaphore_signal(lookup->finished);
        release_lookup(lookup);
        return;
    }
    OM_uint32 minor;
    gss_name_t name = GSS_C_NO_NAME;
    gss_buffer_desc text = GSS_C_EMPTY_BUFFER;
    if (gss_inquire_cred(&minor, cred, &name, NULL, NULL, NULL) == GSS_S_COMPLETE &&
        gss_display_name(&minor, name, &text, NULL) == GSS_S_COMPLETE) {
        char *value = strndup(text.value, text.length);
        if (value) {
            size_t length = strlen(lookup->account);
            char *domain = strlen(value) > length && value[length] == '@' ? value + length : NULL;
            char *host = domain ? strrchr(domain, '\\') : NULL;
            int server_matches = host && strcasecmp(host + 1, lookup->server) == 0;
            if (host) *host = '\0';
            int domain_matches = !lookup->domain || (domain && !strcasecmp(domain + 1, lookup->domain));
            if (domain) *domain = '\0';
            if (server_matches && domain_matches && strcasecmp(value, lookup->account) == 0) {
                char *candidate = strndup(text.value, text.length);
                if (candidate) {
                    if (!lookup->principal) lookup->principal = candidate;
                    else {
                        if (strcasecmp(candidate, lookup->principal)) lookup->ambiguous = 1;
                        free(candidate);
                    }
                }
            }
            free(value);
        }
    }
    if (text.value) gss_release_buffer(&minor, &text);
    if (name) gss_release_name(&minor, &name);
    gss_release_cred(&minor, &cred);
}

static char *cached_principal(const char *server, const char *account)
{
    struct credential_lookup *lookup = calloc(1, sizeof(*lookup));
    if (!lookup) return NULL;
    atomic_init(&lookup->references, 2);
    lookup->server = strdup(server);
    lookup->account = strdup(account);
    char *separator = lookup->account ? strrchr(lookup->account, ';') : NULL;
    if (!separator && lookup->account) separator = strrchr(lookup->account, '\\');
    int explicit_domain = separator != NULL;
    if (separator) {
        lookup->domain = strndup(lookup->account, (size_t)(separator - lookup->account));
        char *user = strdup(separator + 1);
        free(lookup->account);
        lookup->account = user;
    }
    lookup->finished = dispatch_semaphore_create(0);
    if (!lookup->server || !lookup->account || !*lookup->account || !lookup->finished ||
        (explicit_domain && !lookup->domain)) {
        if (lookup->finished) dispatch_release(lookup->finished);
        free(lookup->server); free(lookup->account); free(lookup->domain); free(lookup);
        return NULL;
    }
    OM_uint32 minor;
    gss_iter_creds_f(&minor, 0, GSS_NTLM_MECHANISM, lookup, credential);
    char *principal = NULL;
    if (!dispatch_semaphore_wait(lookup->finished, dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC)) &&
        !lookup->ambiguous) {
        principal = lookup->principal;
        lookup->principal = NULL;
    }
    release_lookup(lookup);
    return principal;
}

struct reply {
    int done, error;
    smb2_file_id file;
    uint64_t identity;
    char name[256];
};

static void finished(struct smb2_context *smb, int status, void *data, void *context)
{
    struct reply *reply = context;
    reply->error = status ? nterror_to_errno((uint32_t)status) : 0;
    reply->done = 1;
}

static void opened(struct smb2_context *smb, int status, void *data, void *context)
{
    struct reply *reply = context;
    if (!status && data) memcpy(reply->file, ((struct smb2_create_reply *)data)->file_id, SMB2_FD_SIZE);
    finished(smb, status, data, context);
    if (!status && !data) reply->error = EIO;
}

static void inspected(struct smb2_context *smb, int status, void *data, void *context)
{
    struct reply *reply = context;
    struct smb2_file_all_info *info = data ? ((struct smb2_query_info_reply *)data)->output_buffer : NULL;
    finished(smb, status, data, context);
    if (!status) {
        if (!info || !(info->basic.file_attributes & SMB2_FILE_ATTRIBUTE_DIRECTORY) ||
            (info->basic.file_attributes & SMB2_FILE_ATTRIBUTE_REPARSE_POINT)) reply->error = ESTALE;
        else {
            reply->identity = info->index_number;
            const char *name = (const char *)info->name;
            const char *leaf = name ? strrchr(name, '\\') : NULL;
            if (!leaf && name) leaf = strrchr(name, '/');
            name = leaf ? leaf + 1 : name;
            if (name && strlen(name) < sizeof(reply->name)) strcpy(reply->name, name);
            else reply->name[0] = '\0';
        }
    }
    if (info) smb2_free_data(smb, info);
}

static int perform(struct smb2_context *smb, struct smb2_pdu *pdu, struct reply *reply)
{
    if (!pdu) return EIO;
    reply->done = 0;
    reply->error = 0;
    smb2_queue_pdu(smb, pdu);
    struct timespec start, now;
    clock_gettime(CLOCK_MONOTONIC, &start);
    while (!reply->done) {
        struct pollfd fd = { .fd = smb2_get_fd(smb), .events = smb2_which_events(smb) };
        if (poll(&fd, 1, 100) < 0 && errno != EINTR) return errno;
        if (smb2_service(smb, fd.revents) < 0) return EIO;
        clock_gettime(CLOCK_MONOTONIC, &now);
        if (now.tv_sec - start.tv_sec >= 12 && !reply->done) return ETIMEDOUT;
    }
    return reply->error;
}

static int open_folder(struct smb2_context *smb, const char *path, int writable, struct reply *reply)
{
    struct smb2_create_request create = {0};
    create.impersonation_level = SMB2_IMPERSONATION_IMPERSONATION;
    create.desired_access = SMB2_FILE_READ_ATTRIBUTES | (writable ? SMB2_DELETE : 0);
    create.share_access = SMB2_FILE_SHARE_READ | SMB2_FILE_SHARE_WRITE;
    create.create_disposition = SMB2_FILE_OPEN;
    create.create_options = SMB2_FILE_DIRECTORY_FILE | SMB2_FILE_OPEN_REPARSE_POINT;
    create.name = path;
    int error = perform(smb, smb2_cmd_create_async(smb, &create, opened, reply), reply);
    if (error) return error;
    struct smb2_query_info_request query = {0};
    query.info_type = SMB2_0_INFO_FILE;
    query.file_info_class = SMB2_FILE_ALL_INFORMATION;
    query.output_buffer_length = 4096;
    memcpy(query.file_id, reply->file, SMB2_FD_SIZE);
    return perform(smb, smb2_cmd_query_info_async(smb, &query, inspected, reply), reply);
}

static int valid_path(const char *path)
{
    if (!path || !*path || strlen(path) > 1023 || strchr(path, '\\')) return 0;
    for (const char *start = path, *end; ; start = end + 1) {
        end = strchr(start, '/');
        size_t length = end ? (size_t)(end - start) : strlen(start);
        if (!length || length > 255 || (length == 1 && start[0] == '.') ||
            (length == 2 && start[0] == '.' && start[1] == '.')) return 0;
        if (!end) return 1;
    }
}

static int same_name(const char *left, const char *right, CFStringCompareFlags flags)
{
    CFStringRef a = CFStringCreateWithCString(NULL, left, kCFStringEncodingUTF8);
    CFStringRef b = CFStringCreateWithCString(NULL, right, kCFStringEncodingUTF8);
    int equal = a && b && CFStringCompare(a, b, flags) == kCFCompareEqualTo;
    if (a) CFRelease(a);
    if (b) CFRelease(b);
    return equal;
}

int tm_smb_name_folder(const char *server, const char *share, const char *account,
                       const char *source, const char *destination, uint64_t expected_id,
                       int recovery_only, int *rename_sent)
{
    if (rename_sent) *rename_sent = 0;
    if (!server || !*server || !share || !*share || !account || !*account || !expected_id ||
        !valid_path(source) || !valid_path(destination) || !strcmp(source, destination)) return EINVAL;
    const char *source_leaf = strrchr(source, '/'), *destination_leaf = strrchr(destination, '/');
    size_t parent_length = source_leaf ? (size_t)(source_leaf - source + 1) : 0;
    if (parent_length != (destination_leaf ? (size_t)(destination_leaf - destination + 1) : 0) ||
        strncmp(source, destination, parent_length)) return EINVAL;
    pthread_mutex_lock(&client_lock);
    int error = EAUTH;
    struct reply reply = {0};
    struct smb2_context *smb = smb2_init_context();
    char *principal = cached_principal(server, account);
    if (!smb) { free(principal); pthread_mutex_unlock(&client_lock); return ENOMEM; }
    smb2_set_timeout(smb, 10);
    if (principal) {
        smb2_set_user(smb, principal);
        smb2_set_sign(smb, 1);
        smb2_set_seal(smb, 1);
        smb2_set_security_mode(smb, SMB2_NEGOTIATE_SIGNING_ENABLED | SMB2_NEGOTIATE_SIGNING_REQUIRED);
    } else if (!strcasecmp(account, "guest")) {
        smb2_set_authentication(smb, 1);
        smb2_set_user(smb, "guest");
        smb2_set_password(smb, "");
    } else goto done;
    int connected = smb2_connect_share(smb, server, share, NULL);
    if (connected) { error = connected < 0 ? -connected : EIO; goto done; }
    char path[1024] = {0};
    error = open_folder(smb, "", 0, &reply);
    if (error) goto done;
    memcpy(path, source, strlen(source) + 1);
    for (size_t i = 0; i < parent_length; i++) {
        if (path[i] != '/') continue;
        path[i] = '\0';
        error = open_folder(smb, path, 0, &reply);
        path[i] = '/';
        if (error) goto done;
    }
    error = open_folder(smb, destination, 0, &reply);
    if (!error) {
        if (reply.identity != expected_id) { error = EEXIST; goto done; }
        const char *name = destination_leaf ? destination_leaf + 1 : destination;
        int case_only = same_name(source, destination, kCFCompareNonliteral | kCFCompareCaseInsensitive);
        if (!case_only && same_name(reply.name, name, kCFCompareNonliteral)) goto done;
        if (!recovery_only) {
            struct smb2_close_request close = {0};
            memcpy(close.file_id, reply.file, SMB2_FD_SIZE);
            error = perform(smb, smb2_cmd_close_async(smb, &close, finished, &reply), &reply);
            if (error) goto done;
        }
    } else if (error != ENOENT) {
        if (error == ENOTDIR) error = EEXIST;
        goto done;
    }
    if (recovery_only) { error = EAGAIN; goto done; }
    error = open_folder(smb, source, 1, &reply);
    if (error) goto done;
    if (reply.identity != expected_id) { error = ESTALE; goto done; }
    char *target = strdup(destination);
    if (!target) { error = ENOMEM; goto done; }
    for (char *p = target; *p; p++) if (*p == '/') *p = '\\';
    struct smb2_file_rename_info name = { .replace_if_exist = 0, .file_name = (const uint8_t *)target };
    struct smb2_set_info_request set = {0};
    set.info_type = SMB2_0_INFO_FILE;
    set.file_info_class = SMB2_FILE_RENAME_INFORMATION;
    memcpy(set.file_id, reply.file, SMB2_FD_SIZE);
    set.input_data = &name;
    struct smb2_pdu *pdu = smb2_cmd_set_info_async(smb, &set, finished, &reply);
    if (pdu && rename_sent) *rename_sent = 1;
    error = perform(smb, pdu, &reply);
    if (reply.done && rename_sent) {
        switch (error) {
        case EEXIST: case EACCES: case EPERM: case ENOENT: case ENOTDIR: case EINVAL: case EROFS: case ENOTSUP:
            *rename_sent = 0;
            break;
        default: break;
        }
    }
    free(target);
done:
    smb2_destroy_context(smb);
    free(principal);
    pthread_mutex_unlock(&client_lock);
    return error;
}
