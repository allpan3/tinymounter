#include "SMBRename.h"
#include <CoreFoundation/CoreFoundation.h>
#include <GSS/GSS.h>
#include <dispatch/dispatch.h>
#include <errno.h>
#include <os/log.h>
#include <poll.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <smb2/smb2.h>
#include <smb2/libsmb2.h>
#include <smb2/libsmb2-raw.h>
#include <smb2/libsmb2-dcerpc.h>
#include <smb2/libsmb2-dcerpc-srvsvc.h>
#include "libsmb2-private.h"

// libsmb2 links contexts globally; payload I/O belongs to each independent context.
static pthread_mutex_t context_lock = PTHREAD_MUTEX_INITIALIZER;

static struct smb2_context *create_context(void)
{
    pthread_mutex_lock(&context_lock);
    struct smb2_context *smb = smb2_init_context();
    pthread_mutex_unlock(&context_lock);
    return smb;
}

void tm_smb_destroy_context(void *opaque)
{
    pthread_mutex_lock(&context_lock);
    smb2_destroy_context(opaque);
    pthread_mutex_unlock(&context_lock);
}

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
    int done, error, queued, queried;
    uint32_t status;
    smb2_file_id file;
    uint64_t identity, birth;
    char name[256];
};

// Set while a folder operation runs on a session's connection, which outlives the operation.
struct session_link {
    int failed;
    size_t count;
    smb2_file_id files[520];
};
static _Thread_local struct session_link *session_link;

static void finished(struct smb2_context *smb, int status, void *data, void *context)
{
    struct reply *reply = context;
    reply->status = (uint32_t)status;
    reply->error = status ? nterror_to_errno((uint32_t)status) : 0;
    reply->done = 1;
}

static void opened(struct smb2_context *smb, int status, void *data, void *context)
{
    struct reply *reply = context;
    if (!status && data) memcpy(reply->file, ((struct smb2_create_reply *)data)->file_id, SMB2_FD_SIZE);
    finished(smb, status, data, context);
    if (!status && !data) reply->error = EIO;
    struct session_link *link = session_link;
    if (!status && data && link) {
        if (link->count < sizeof(link->files) / sizeof(link->files[0]))
            memcpy(link->files[link->count++], reply->file, SMB2_FD_SIZE);
        else link->failed = 1;
    }
}

static void forget_handle(const smb2_file_id file)
{
    struct session_link *link = session_link;
    for (size_t i = 0; link && i < link->count; i++) {
        if (memcmp(link->files[i], file, SMB2_FD_SIZE)) continue;
        memmove(link->files[i], link->files[i + 1], (link->count - i - 1) * SMB2_FD_SIZE);
        link->count--;
        return;
    }
}

static void inspected(struct smb2_context *smb, int status, void *data, void *context)
{
    struct reply *reply = context;
    // An error reply's payload is a struct smb2_error_reply, not a query reply.
    struct smb2_file_all_info *info = !status && data
        ? ((struct smb2_query_info_reply *)data)->output_buffer : NULL;
    finished(smb, status, data, context);
    if (!status) {
        if (!info || !(info->basic.file_attributes & SMB2_FILE_ATTRIBUTE_DIRECTORY) ||
            (info->basic.file_attributes & SMB2_FILE_ATTRIBUTE_REPARSE_POINT)) reply->error = ESTALE;
        else {
            reply->identity = info->index_number;
            reply->birth = info->basic.creation_time.tv_sec > 0
                ? (uint64_t)info->basic.creation_time.tv_sec * 1000000 + info->basic.creation_time.tv_usec : 0;
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
    reply->status = 0;
    smb2_queue_pdu(smb, pdu);
    struct timespec start, now;
    clock_gettime(CLOCK_MONOTONIC, &start);
    int error = 0;
    while (!reply->done) {
        struct pollfd fd = { .fd = smb2_get_fd(smb), .events = smb2_which_events(smb) };
        if (poll(&fd, 1, 100) < 0 && errno != EINTR) { error = errno; break; }
        if (smb2_service(smb, fd.revents) < 0) { error = EIO; break; }
        clock_gettime(CLOCK_MONOTONIC, &now);
        if (now.tv_sec - start.tv_sec >= 12 && !reply->done) { error = ETIMEDOUT; break; }
    }
    // A request without a reply can still complete later, so its connection is unusable.
    if (error && session_link) session_link->failed = 1;
    return error ? error : reply->error;
}

static int open_folder(struct smb2_context *smb, const char *path, int writable,
                       int exclusive, int *sent, struct reply *reply)
{
    struct smb2_create_request create = {0};
    create.impersonation_level = SMB2_IMPERSONATION_IMPERSONATION;
    create.desired_access = SMB2_FILE_LIST_DIRECTORY | SMB2_FILE_READ_ATTRIBUTES | (writable ? SMB2_DELETE : 0);
    create.share_access = SMB2_FILE_SHARE_READ | SMB2_FILE_SHARE_WRITE;
    create.create_disposition = exclusive ? SMB2_FILE_CREATE : SMB2_FILE_OPEN;
    create.create_options = SMB2_FILE_DIRECTORY_FILE | SMB2_FILE_OPEN_REPARSE_POINT;
    create.name = path;
    reply->queried = 0;
    struct smb2_pdu *pdu = smb2_cmd_create_async(smb, &create, opened, reply);
    if (pdu && exclusive && sent) *sent = 1;
    reply->queued = sent ? *sent : 0;
    int error = perform(smb, pdu, reply);
    if (error && reply->done && sent) {
        switch (error) {
        case EEXIST: case ENOENT: case ENOTDIR: case EINVAL: case EROFS: case ENOTSUP:
            *sent = 0;
            break;
        default: break;
        }
    }
    if (error) return error;
    reply->queried = 1;
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

// The macOS client, like HFS+ (TN1150), never decomposes these ranges. NFC would turn singletons
// such as U+2126 OHM SIGN or U+F900 into other characters, which name other files.
static int kept_as_is(UTF32Char c)
{
    return (c >= 0x2000 && c <= 0x2FFF) || (c >= 0xF900 && c <= 0xFAFF) || (c >= 0x2F800 && c <= 0x2FAFF);
}

static int append_composed(CFMutableStringRef result, const UniChar *characters, CFIndex count)
{
    CFMutableStringRef run = CFStringCreateMutable(NULL, 0);
    if (!run) return 0;
    CFStringAppendCharacters(run, characters, count);
    CFStringNormalize(run, kCFStringNormalizationFormC);
    CFStringAppend(result, run);
    CFRelease(run);
    return 1;
}

// SMB clients send names composed (NFC), as the macOS and Windows clients do; the macOS client
// shows them decomposed. Returns 1 when `composed` holds the whole result.
int tm_smb_compose(const char *path, char *composed, size_t capacity)
{
    CFStringRef text = path ? CFStringCreateWithCString(NULL, path, kCFStringEncodingUTF8) : NULL;
    CFIndex length = text ? CFStringGetLength(text) : 0, start = 0;
    UniChar *characters = text ? malloc(sizeof(UniChar) * (size_t)(length ? length : 1)) : NULL;
    CFMutableStringRef result = characters ? CFStringCreateMutable(NULL, 0) : NULL;
    int fits = result != NULL;
    if (fits) CFStringGetCharacters(text, CFRangeMake(0, length), characters);
    for (CFIndex i = 0; fits && i < length; ) {
        UTF32Char c = characters[i];
        CFIndex width = 1;
        if (CFStringIsSurrogateHighCharacter(characters[i]) && i + 1 < length &&
            CFStringIsSurrogateLowCharacter(characters[i + 1])) {
            c = CFStringGetLongCharacterForSurrogatePair(characters[i], characters[i + 1]);
            width = 2;
        }
        if (kept_as_is(c)) {
            fits = append_composed(result, characters + start, i - start);
            CFStringAppendCharacters(result, characters + i, width);
            start = i + width;
        }
        i += width;
    }
    fits = fits && append_composed(result, characters + start, length - start) &&
        CFStringGetCString(result, composed, (CFIndex)capacity, kCFStringEncodingUTF8);
    if (result) CFRelease(result);
    free(characters);
    if (text) CFRelease(text);
    return fits;
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

// libsmb2's wait loop returns -1, not -EPERM, when it fails without a connection.
static int connect_error(int connected)
{
    return connected == -1 ? ENOTCONN : connected < 0 ? -connected : EIO;
}

static struct smb2_context *connect_folder_share(const char *server, const char *share,
                                                 const char *account, int *error)
{
    struct smb2_context *smb = create_context();
    char *principal = cached_principal(server, account);
    os_log_t log = os_log_create("dev.tinymounter.prototype", "smb");
    os_log_info(log, "smb_connect cached_credential=%d", principal != NULL);
    os_release(log);
    *error = EAUTH;
    if (!smb) { free(principal); *error = ENOMEM; return NULL; }
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
    log = os_log_create("dev.tinymounter.prototype", "smb");
    os_log_info(log, "smb_connect result=%d", connected);
    os_release(log);
    if (connected) { *error = connect_error(connected); goto done; }
    free(principal);
    return smb;
done:
    tm_smb_destroy_context(smb);
    free(principal);
    return NULL;
}

struct smb2_context *tm_smb_connect_password(const struct tm_smb_login *login, const char *share,
                                             int *error, uint32_t *status)
{
    *status = 0;
    *error = EINVAL;
    if (!login || !login->server || !*login->server || !share || !*share || !login->account ||
        !login->password || memchr(login->password, 0, login->password_length)) return NULL;
    char *account = strdup(login->account), *user = account, *domain = NULL;
    if (!account) { *error = ENOMEM; return NULL; }
    char *separator = strchr(account, '\\');
    if (!separator) separator = strchr(account, ';');
    if (separator) {
        *separator = '\0';
        domain = account;
        user = separator + 1;
    } else if ((separator = strrchr(account, '@'))) {
        // Samba refuses the UPN as an NTLM user name with an empty domain, so split it.
        *separator = '\0';
        domain = separator + 1;
    }
    // The vendored library still accepts a guest session for this name, which isn't a password login.
    if (!*user || (domain && !*domain) || !strcasecmp(user, "guest")) {
        free(account);
        *error = EACCES;
        return NULL;
    }
    char *secret = calloc(1, login->password_length + 1);
    struct smb2_context *smb = secret ? create_context() : NULL;
    if (!smb) {
        free(secret);
        free(account);
        *error = ENOMEM;
        return NULL;
    }
    memcpy(secret, login->password, login->password_length);
    smb2_set_timeout(smb, 10);
    smb2_set_version(smb, SMB2_VERSION_ANY3);
    smb2_set_authentication(smb, SMB2_SEC_NTLMSSP);
    smb2_set_user(smb, user);
    if (domain) smb2_set_domain(smb, domain);
    smb2_set_password(smb, secret);
    smb2_secure_zero(secret, login->password_length);
    free(secret);
    free(account);
    smb2_set_sign(smb, 1);
    smb2_set_seal(smb, 1);
    smb2_set_security_mode(smb, SMB2_NEGOTIATE_SIGNING_ENABLED | SMB2_NEGOTIATE_SIGNING_REQUIRED);
    int connected = smb2_connect_share(smb, login->server, share, NULL);
    smb2_clear_password(smb);
    if (connected) {
        *error = connect_error(connected);
        *status = (uint32_t)smb2_get_nterror(smb);
    } else if (smb2_get_dialect(smb) < SMB2_VERSION_0300 || !smb->seal) {
        *error = ENOTSUP;
    } else {
        *error = 0;
        return smb;
    }
    tm_smb_destroy_context(smb);
    return NULL;
}

struct share_listing {
    int done, error;
    uint32_t status;
    tm_smb_share_callback each;
    void *context;
};

static void shares_listed(struct smb2_context *smb, int status, void *data, void *context)
{
    struct share_listing *listing = context;
    struct srvsvc_NetrShareEnum_rep *reply = data;
    listing->done = 1;
    if (status || !reply) {
        listing->status = (uint32_t)status;
        listing->error = status ? nterror_to_errno((uint32_t)status) : EIO;
    } else if (reply->ses.ShareInfo.Level != SHARE_INFO_1) {
        listing->error = EIO;
    } else {
        struct srvsvc_SHARE_INFO_1_CONTAINER *shares = &reply->ses.ShareInfo.Level1;
        for (uint32_t i = 0; !listing->error && i < shares->EntriesRead; i++) {
            if (!shares->Buffer) { listing->error = EIO; break; }
            const struct srvsvc_SHARE_INFO_1 *share = &shares->Buffer->share_info_1[i];
            if (!share->netname.utf8) continue;
            listing->error = listing->each(listing->context, share->netname.utf8, share->type);
        }
    }
    if (reply) smb2_free_data(smb, reply);
}

int tm_smb_share_names(const struct tm_smb_login *login, tm_smb_share_callback each, void *context,
                       uint32_t *status)
{
    int error;
    if (!each) return EINVAL;
    struct smb2_context *smb = tm_smb_connect_password(login, "IPC$", &error, status);
    if (!smb) return error;
    struct share_listing listing = { .each = each, .context = context };
    error = smb2_share_enum_async(smb, SHARE_INFO_1, shares_listed, &listing);
    if (error) error = -error;
    struct timespec start, now;
    clock_gettime(CLOCK_MONOTONIC, &start);
    while (!error && !listing.done) {
        struct pollfd fd = { .fd = smb2_get_fd(smb), .events = smb2_which_events(smb) };
        if (poll(&fd, 1, 100) < 0 && errno != EINTR) { error = errno; break; }
        if (smb2_service(smb, fd.revents) < 0) { error = ECONNRESET; break; }
        clock_gettime(CLOCK_MONOTONIC, &now);
        if (now.tv_sec - start.tv_sec >= 12 && !listing.done) error = ETIMEDOUT;
    }
    if (!error) {
        error = listing.error;
        *status = listing.status;
    }
    tm_smb_destroy_context(smb);
    return error;
}

static int hold_parents(struct smb2_context *smb, const char *source, size_t parent_length,
                         struct reply *reply, int *opened)
{
    char path[1024] = {0};
    int error = open_folder(smb, "", 0, 0, NULL, reply);
    if (error) return error;
    (*opened)++;
    memcpy(path, source, strlen(source) + 1);
    for (size_t i = 0; i < parent_length; i++) {
        if (path[i] != '/') continue;
        path[i] = '\0';
        error = open_folder(smb, path, 0, 0, NULL, reply);
        path[i] = '/';
        if (error) return error;
        (*opened)++;
    }
    return 0;
}

const char *tm_smb_folder_stage_name(int stage)
{
    static const char *const names[] = {
        "none", "arguments", "connect", "parent", "target", "query", "identity", "receipt", "done"
    };
    return stage >= 0 && stage < (int)(sizeof(names) / sizeof(names[0])) ? names[stage] : "unknown";
}

// Stages after the connection; `path` is composed and valid.
static int create_folder_in(struct smb2_context *smb, const char *path, uint64_t expected_id,
                            uint64_t expected_birth, tm_smb_folder_callback receipt, void *context,
                            int *create_sent, struct tm_smb_folder_trace *trace)
{
    struct reply reply = {0};
    trace->stage = TM_FOLDER_PARENT;
    const char *leaf = strrchr(path, '/');
    int error = hold_parents(smb, path, leaf ? (size_t)(leaf - path + 1) : 0, &reply, &trace->parents);
    if (error) goto done;
    error = open_folder(smb, path, 0, !expected_id, create_sent, &reply);
    trace->stage = reply.queried ? TM_FOLDER_QUERY : TM_FOLDER_TARGET;
    trace->sent_queued = reply.queued;
    if (error && *create_sent && reply.done && !reply.queried) {
        // Samba can refuse a CREATE and still leave the directory, so a refused create stays
        // uncertain unless a lookup on this connection finds nothing at the name.
        struct reply lookup = {0};
        if (open_folder(smb, path, 0, 0, NULL, &lookup) == ENOENT) *create_sent = 0;
    }
    if (error) goto done;
    trace->stage = TM_FOLDER_IDENTITY;
    if (!reply.identity || !reply.birth) { error = ENOTSUP; goto done; }
    if (expected_id && (reply.identity != expected_id || reply.birth != expected_birth)) {
        error = ESTALE;
        goto done;
    }
    trace->stage = TM_FOLDER_RECEIPT;
    error = receipt(context, reply.identity, reply.birth);
    if (!error) trace->stage = TM_FOLDER_DONE;
done:
    trace->status = reply.status;
    return error;
}

static int create_arguments(const char *path, char composed[1024], uint64_t expected_id,
                            uint64_t expected_birth, tm_smb_folder_callback receipt)
{
    return receipt && tm_smb_compose(path, composed, 1024) && valid_path(composed) &&
        !!expected_id == !!expected_birth;
}

int tm_smb_create_folder(const char *server, const char *share, const char *account,
                         const char *path, uint64_t expected_id, uint64_t expected_birth,
                         tm_smb_folder_callback receipt, void *context, int *create_sent,
                         struct tm_smb_folder_trace *trace)
{
    struct tm_smb_folder_trace unused;
    int unsent;
    if (!trace) trace = &unused;
    if (!create_sent) create_sent = &unsent;
    *trace = (struct tm_smb_folder_trace){ .stage = TM_FOLDER_ARGUMENTS, .error = EINVAL };
    *create_sent = 0;
    char composed[1024];
    if (!server || !*server || !share || !*share || !account || !*account ||
        !create_arguments(path, composed, expected_id, expected_birth, receipt)) return EINVAL;
    int error;
    trace->stage = TM_FOLDER_CONNECT;
    struct smb2_context *smb = connect_folder_share(server, share, account, &error);
    if (smb) {
        error = create_folder_in(smb, composed, expected_id, expected_birth, receipt, context,
                                 create_sent, trace);
        tm_smb_destroy_context(smb);
    }
    trace->error = error;
    trace->sent = *create_sent;
    return error;
}

static int name_arguments(const char *source, const char *destination, char composed_source[1024],
                          char composed_destination[1024], uint64_t expected_id, uint64_t expected_birth,
                          tm_smb_folder_callback receipt, size_t *parent_length)
{
    if (!expected_id || !expected_birth || !receipt || !tm_smb_compose(source, composed_source, 1024) ||
        !tm_smb_compose(destination, composed_destination, 1024)) return 0;
    source = composed_source;
    destination = composed_destination;
    if (!valid_path(source) || !valid_path(destination) || !strcmp(source, destination)) return 0;
    const char *source_leaf = strrchr(source, '/'), *destination_leaf = strrchr(destination, '/');
    *parent_length = source_leaf ? (size_t)(source_leaf - source + 1) : 0;
    return *parent_length == (destination_leaf ? (size_t)(destination_leaf - destination + 1) : 0) &&
        !strncmp(source, destination, *parent_length);
}

// After the connection; both paths are composed, valid and share `parent_length`.
static int name_folder_in(struct smb2_context *smb, const char *source, const char *destination,
                          size_t parent_length, uint64_t expected_id, uint64_t expected_birth,
                          int recovery_only, tm_smb_folder_callback receipt, void *context,
                          int *rename_sent)
{
    struct reply reply = {0};
    int parents = 0;
    const char *destination_leaf = strrchr(destination, '/');
    int error = hold_parents(smb, source, parent_length, &reply, &parents);
    if (error) return error;
    error = open_folder(smb, destination, 0, 0, NULL, &reply);
    if (!error) {
        if (reply.identity != expected_id || reply.birth != expected_birth) return EEXIST;
        const char *name = destination_leaf ? destination_leaf + 1 : destination;
        int case_only = same_name(source, destination, kCFCompareNonliteral | kCFCompareCaseInsensitive);
        if (!case_only && same_name(reply.name, name, kCFCompareNonliteral))
            return receipt(context, reply.identity, reply.birth);
        if (!recovery_only) {
            struct smb2_close_request close = {0};
            memcpy(close.file_id, reply.file, SMB2_FD_SIZE);
            error = perform(smb, smb2_cmd_close_async(smb, &close, finished, &reply), &reply);
            if (error) return error;
            forget_handle(close.file_id);
        }
    } else if (error != ENOENT) {
        return error == ENOTDIR ? EEXIST : error;
    }
    if (recovery_only) return EAGAIN;
    error = open_folder(smb, source, 1, 0, NULL, &reply);
    if (error) return error;
    if (reply.identity != expected_id || reply.birth != expected_birth) return ESTALE;
    char *target = strdup(destination);
    if (!target) return ENOMEM;
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
    if (!error) error = receipt(context, reply.identity, reply.birth);
    return error;
}

int tm_smb_name_folder(const char *server, const char *share, const char *account,
                       const char *source, const char *destination, uint64_t expected_id,
                       uint64_t expected_birth, int recovery_only,
                       tm_smb_folder_callback receipt, void *context, int *rename_sent)
{
    if (rename_sent) *rename_sent = 0;
    char composed_source[1024], composed_destination[1024];
    size_t parent_length;
    if (!server || !*server || !share || !*share || !account || !*account ||
        !name_arguments(source, destination, composed_source, composed_destination, expected_id,
                        expected_birth, receipt, &parent_length)) return EINVAL;
    int error;
    struct smb2_context *smb = connect_folder_share(server, share, account, &error);
    if (!smb) return error;
    error = name_folder_in(smb, composed_source, composed_destination, parent_length, expected_id,
                           expected_birth, recovery_only, receipt, context, rename_sent);
    tm_smb_destroy_context(smb);
    return error;
}

// Closes what the operation opened. Returns 1 when the connection must be dropped.
static int end_session_link(struct smb2_context *smb, struct session_link *link)
{
    session_link = NULL;
    for (size_t i = 0; !link->failed && i < link->count; i++) {
        struct reply reply = {0};
        struct smb2_close_request close = {0};
        memcpy(close.file_id, link->files[i], SMB2_FD_SIZE);
        session_link = link;
        (void)perform(smb, smb2_cmd_close_async(smb, &close, finished, &reply), &reply);
        session_link = NULL;
    }
    return link->failed;
}

int tm_smb_session_create_folder(struct smb2_context *smb, const char *path, uint64_t expected_id,
                                 uint64_t expected_birth, tm_smb_folder_callback receipt, void *context,
                                 int *create_sent, struct tm_smb_folder_trace *trace, int *broken)
{
    *broken = 0;
    *create_sent = 0;
    *trace = (struct tm_smb_folder_trace){ .stage = TM_FOLDER_ARGUMENTS, .error = EINVAL };
    char composed[1024];
    if (!smb || !create_arguments(path, composed, expected_id, expected_birth, receipt)) return EINVAL;
    struct session_link *link = calloc(1, sizeof(*link));
    if (!link) return trace->error = ENOMEM;
    session_link = link;
    int error = create_folder_in(smb, composed, expected_id, expected_birth, receipt, context,
                                 create_sent, trace);
    *broken = end_session_link(smb, link);
    free(link);
    trace->error = error;
    trace->sent = *create_sent;
    return error;
}

int tm_smb_session_name_folder(struct smb2_context *smb, const char *source, const char *destination,
                               uint64_t expected_id, uint64_t expected_birth, int recovery_only,
                               tm_smb_folder_callback receipt, void *context, int *rename_sent,
                               int *broken)
{
    *broken = 0;
    *rename_sent = 0;
    char composed_source[1024], composed_destination[1024];
    size_t parent_length;
    if (!smb || !name_arguments(source, destination, composed_source, composed_destination, expected_id,
                                expected_birth, receipt, &parent_length)) return EINVAL;
    struct session_link *link = calloc(1, sizeof(*link));
    if (!link) return ENOMEM;
    session_link = link;
    int error = name_folder_in(smb, composed_source, composed_destination, parent_length, expected_id,
                               expected_birth, recovery_only, receipt, context, rename_sent);
    *broken = end_session_link(smb, link);
    free(link);
    return error;
}

void *tm_smb_begin_edit(const char *server, const char *share, const char *account, int *error)
{
    if (!server || !*server || !share || !*share || !account || !*account || !strcasecmp(account, "guest")) {
        *error = EACCES;
        return NULL;
    }
    struct smb2_context *smb = connect_folder_share(server, share, account, error);
    return smb;
}

void tm_smb_end_edit(void *smb)
{
    if (smb) tm_smb_destroy_context(smb);
}
