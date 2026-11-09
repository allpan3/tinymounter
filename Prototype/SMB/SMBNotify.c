#define __STDC_WANT_LIB_EXT1__ 1
#include "SMBNotify.h"
#include "SMBEdit.h"
#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>
#include <smb2/smb2.h>
#include <smb2/smb2-errors.h>
#include <smb2/libsmb2.h>
#include <smb2/libsmb2-raw.h>
#include "libsmb2-private.h"

// Names, attributes, size, last write, creation, security and streams; not last access.
#define NOTIFY_FILTER 0xF5Fu
// The largest output buffer that libsmb2's fixed credit charge of 1 allows.
#define NOTIFY_BUFFER 65536u
#define STATUS_NOTIFY_ENUM_DIR 0x0000010Cu

extern int tm_smb_compose(const char *path, char *composed, size_t capacity);
extern struct smb2_context *tm_smb_connect_password(const struct tm_smb_login *login, const char *share,
                                                    uint64_t previous_session, int *error, uint32_t *status);

struct watch {
    struct watch *next;
    struct tm_notify *notify;
    uint64_t token;
    smb2_file_id file;
    int opening, open, armed, closing, removed;
};

struct command {
    struct command *next;
    uint64_t token;
    char *path; // NULL for unwatch
};

struct tm_notify {
    struct smb2_context *smb;
    tm_notify_callback callback;
    void *context;
    pthread_t thread;
    int wake[2];
    int echo_seconds;
    // Owned by the notify thread.
    struct watch *watches;
    int echo_pending;
    time_t next_echo;
    // Shared, under `lock`.
    pthread_mutex_t lock;
    pthread_cond_t changed;
    struct command *commands, **last_command;
    int closes; // closes sent or due whose replies have not arrived
    int busy;   // the thread took commands and has not finished them
    int ended, finished, settle_expired, detached;
    atomic_int stopping, echoes;
};

// MARK: Connection

// The sessions' password connect, so the watcher signs in, seals and refuses as every session does.
static struct smb2_context *connect_share(const char *server, const char *share, const char *account,
                                          const uint8_t *password, size_t length, int *error,
                                          uint32_t *ntstatus)
{
    struct tm_smb_login login = { .server = server, .account = account, .password = password,
                                  .password_length = length };
    return tm_smb_connect_password(&login, share, 0, error, ntstatus);
}

static void deliver(struct tm_notify *n, int event, uint64_t token, uint32_t status,
                    const uint8_t *buffer, uint32_t length)
{
    if (!atomic_load(&n->stopping)) n->callback(n->context, event, token, status, buffer, length);
}

static void end_connection(struct tm_notify *n, uint32_t status)
{
    pthread_mutex_lock(&n->lock);
    int ended = n->ended;
    n->ended = 1;
    pthread_cond_broadcast(&n->changed);
    pthread_mutex_unlock(&n->lock);
    if (!ended) deliver(n, TM_NOTIFY_ENDED, 0, status, NULL, 0);
}

static void close_settled(struct tm_notify *n)
{
    pthread_mutex_lock(&n->lock);
    n->closes--;
    pthread_cond_broadcast(&n->changed);
    pthread_mutex_unlock(&n->lock);
}

// MARK: Watches, on the notify thread

static void release_if_done(struct watch *w)
{
    if (w->opening || w->armed || w->closing || w->open || !w->removed) return;
    struct tm_notify *n = w->notify;
    for (struct watch **link = &n->watches; *link; link = &(*link)->next) {
        if (*link == w) { *link = w->next; break; }
    }
    free(w);
}

static void closed(struct smb2_context *smb, int status, void *data, void *opaque)
{
    struct watch *w = opaque;
    w->closing = 0;
    w->open = 0;
    close_settled(w->notify);
    release_if_done(w);
}

// The caller has counted this close in `closes`.
static void send_close(struct watch *w)
{
    struct smb2_close_request request = {0};
    memcpy(request.file_id, w->file, SMB2_FD_SIZE);
    struct smb2_pdu *pdu = smb2_cmd_close_async(w->notify->smb, &request, closed, w);
    if (!pdu) {
        end_connection(w->notify, 0);
        return;
    }
    w->closing = 1;
    smb2_queue_pdu(w->notify->smb, pdu);
}

static void count_close(struct tm_notify *n)
{
    pthread_mutex_lock(&n->lock);
    n->closes++;
    pthread_mutex_unlock(&n->lock);
}

static void arm(struct watch *w);

static void notified(struct smb2_context *smb, int status, void *data, void *opaque)
{
    struct watch *w = opaque;
    struct tm_notify *n = w->notify;
    w->armed = 0;
    if (atomic_load(&n->stopping) || w->removed) {
        release_if_done(w);
        return;
    }
    uint32_t raw = (uint32_t)status;
    if (raw == SMB2_STATUS_SUCCESS || raw == STATUS_NOTIFY_ENUM_DIR) {
        struct smb2_change_notify_reply *reply = data;
        uint32_t length = reply ? reply->output_buffer_length : 0;
        deliver(n, TM_NOTIFY_COMPLETED, w->token, raw, length ? reply->output : NULL, length);
        if (!w->removed && !n->ended && !atomic_load(&n->stopping)) arm(w);
        return;
    }
    deliver(n, TM_NOTIFY_COMPLETED, w->token, raw, NULL, 0);
    // The server ended this watch, for example because its folder was deleted.
    if (!w->removed) {
        w->removed = 1;
        if (w->open && !w->closing) {
            count_close(n);
            send_close(w);
        }
    }
    release_if_done(w);
}

static void arm(struct watch *w)
{
    struct smb2_change_notify_request request = {0};
    request.output_buffer_length = NOTIFY_BUFFER;
    request.completion_filter = NOTIFY_FILTER;
    memcpy(request.file_id, w->file, SMB2_FD_SIZE);
    struct smb2_pdu *pdu = smb2_cmd_change_notify_async(w->notify->smb, &request, notified, w);
    if (!pdu) {
        end_connection(w->notify, 0);
        return;
    }
    // A notify stays pending until a change; libsmb2's request timeout would expire it locally.
    pdu->timeout = 0;
    w->armed = 1;
    smb2_queue_pdu(w->notify->smb, pdu);
}

static void opened(struct smb2_context *smb, int status, void *data, void *opaque)
{
    struct watch *w = opaque;
    struct tm_notify *n = w->notify;
    w->opening = 0;
    if (status == SMB2_STATUS_SUCCESS && data) {
        memcpy(w->file, ((struct smb2_create_reply *)data)->file_id, SMB2_FD_SIZE);
        w->open = 1;
    }
    if (atomic_load(&n->stopping)) {
        w->open = 0;
        release_if_done(w);
        return;
    }
    if (w->removed) {
        // tm_notify_unwatch counted a close for this watch.
        if (w->open) send_close(w);
        else close_settled(n);
    } else if (w->open) {
        arm(w);
    } else {
        w->removed = 1;
        deliver(n, TM_NOTIFY_OPEN_FAILED, w->token, (uint32_t)status, NULL, 0);
    }
    release_if_done(w);
}

static void start_watch(struct tm_notify *n, uint64_t token, const char *path)
{
    struct watch *w = calloc(1, sizeof(*w));
    if (!w) {
        end_connection(n, 0);
        return;
    }
    w->notify = n;
    w->token = token;
    w->next = n->watches;
    n->watches = w;
    struct smb2_create_request request = {0};
    request.impersonation_level = SMB2_IMPERSONATION_IMPERSONATION;
    request.desired_access = SMB2_FILE_LIST_DIRECTORY | SMB2_FILE_READ_ATTRIBUTES;
    request.share_access = SMB2_FILE_SHARE_READ | SMB2_FILE_SHARE_WRITE | SMB2_FILE_SHARE_DELETE;
    request.create_disposition = SMB2_FILE_OPEN;
    request.create_options = SMB2_FILE_DIRECTORY_FILE;
    request.name = path;
    struct smb2_pdu *pdu = smb2_cmd_create_async(n->smb, &request, opened, w);
    if (!pdu) {
        w->removed = 1;
        release_if_done(w);
        end_connection(n, 0);
        return;
    }
    w->opening = 1;
    smb2_queue_pdu(n->smb, pdu);
}

static void stop_watch(struct tm_notify *n, uint64_t token)
{
    struct watch *w = n->watches;
    while (w && (w->token != token || w->removed)) w = w->next;
    if (!w) return;
    w->removed = 1;
    if (w->opening) {
        count_close(n);
    } else if (w->open && !w->closing) {
        count_close(n);
        send_close(w);
    }
    release_if_done(w);
}

// MARK: Thread

static void echoed(struct smb2_context *smb, int status, void *data, void *opaque)
{
    struct tm_notify *n = opaque;
    n->echo_pending = 0;
    if (atomic_load(&n->stopping)) return;
    if (status == SMB2_STATUS_SUCCESS) atomic_fetch_add(&n->echoes, 1);
    else end_connection(n, (uint32_t)status);
}

static void run_commands(struct tm_notify *n)
{
    pthread_mutex_lock(&n->lock);
    struct command *commands = n->commands;
    n->commands = NULL;
    n->last_command = &n->commands;
    n->busy = 1;
    int expired = n->settle_expired;
    pthread_mutex_unlock(&n->lock);
    while (commands) {
        struct command *next = commands->next;
        if (!n->ended) {
            if (commands->path) start_watch(n, commands->token, commands->path);
            else stop_watch(n, commands->token);
        }
        free(commands->path);
        free(commands);
        commands = next;
    }
    pthread_mutex_lock(&n->lock);
    n->busy = 0;
    pthread_cond_broadcast(&n->changed);
    pthread_mutex_unlock(&n->lock);
    if (expired) end_connection(n, SMB2_STATUS_IO_TIMEOUT);
}

static void *serve(void *opaque)
{
    struct tm_notify *n = opaque;
    while (!atomic_load(&n->stopping) && !n->ended) {
        run_commands(n);
        if (n->ended) break;
        time_t now = time(NULL);
        if (n->echo_seconds > 0 && !n->echo_pending && now >= n->next_echo) {
            struct smb2_pdu *pdu = smb2_cmd_echo_async(n->smb, echoed, n);
            if (!pdu) {
                end_connection(n, 0);
                break;
            }
            n->echo_pending = 1;
            n->next_echo = now + n->echo_seconds;
            smb2_queue_pdu(n->smb, pdu);
        }
        struct pollfd fds[2] = {{.fd = smb2_get_fd(n->smb), .events = (short)smb2_which_events(n->smb)},
                                {.fd = n->wake[0], .events = POLLIN}};
        if (poll(fds, 2, 1000) < 0 && errno != EINTR) {
            end_connection(n, 0);
            break;
        }
        if (fds[1].revents) {
            char drain[64];
            while (read(n->wake[0], drain, sizeof(drain)) > 0) {}
        }
        // Also runs libsmb2's request timeouts, so an unanswered echo ends the connection.
        if (smb2_service(n->smb, fds[0].revents) < 0) end_connection(n, 0);
    }
    atomic_store(&n->stopping, 1);
    smb2_destroy_context(n->smb);
    n->smb = NULL;
    while (n->watches) {
        struct watch *next = n->watches->next;
        free(n->watches);
        n->watches = next;
    }
    pthread_mutex_lock(&n->lock);
    n->ended = 1;
    n->finished = 1;
    int detached = n->detached;
    pthread_cond_broadcast(&n->changed);
    pthread_mutex_unlock(&n->lock);
    if (detached) {
        // tm_notify_close ran on this thread, from a callback.
        close(n->wake[0]);
        close(n->wake[1]);
        while (n->commands) {
            struct command *next = n->commands->next;
            free(n->commands->path);
            free(n->commands);
            n->commands = next;
        }
        pthread_cond_destroy(&n->changed);
        pthread_mutex_destroy(&n->lock);
        free(n);
    }
    return NULL;
}

// MARK: Interface

struct tm_notify *tm_notify_open(const char *server, const char *share, const char *account,
                                 const uint8_t *password, size_t password_length, int echo_seconds,
                                 tm_notify_callback callback, void *context, int *error,
                                 uint32_t *ntstatus)
{
    *error = 0;
    *ntstatus = 0;
    if (!server || !*server || !share || !*share || !account || !*account || !password ||
        !password_length || !callback) {
        *error = EINVAL;
        return NULL;
    }
    struct tm_notify *n = calloc(1, sizeof(*n));
    if (!n) {
        *error = ENOMEM;
        return NULL;
    }
    if (pipe(n->wake)) {
        *error = errno;
        free(n);
        return NULL;
    }
    for (int i = 0; i < 2; i++) {
        fcntl(n->wake[i], F_SETFL, O_NONBLOCK);
        fcntl(n->wake[i], F_SETFD, FD_CLOEXEC);
    }
    n->smb = connect_share(server, share, account, password, password_length, error, ntstatus);
    if (!n->smb) {
        close(n->wake[0]);
        close(n->wake[1]);
        free(n);
        return NULL;
    }
    n->callback = callback;
    n->context = context;
    n->echo_seconds = echo_seconds;
    n->next_echo = time(NULL) + echo_seconds;
    n->last_command = &n->commands;
    pthread_mutex_init(&n->lock, NULL);
    pthread_cond_init(&n->changed, NULL);
    if ((*error = pthread_create(&n->thread, NULL, serve, n))) {
        smb2_destroy_context(n->smb);
        pthread_cond_destroy(&n->changed);
        pthread_mutex_destroy(&n->lock);
        close(n->wake[0]);
        close(n->wake[1]);
        free(n);
        return NULL;
    }
    return n;
}

static int enqueue(struct tm_notify *n, uint64_t token, char *path)
{
    struct command *command = calloc(1, sizeof(*command));
    if (!command) {
        free(path);
        return ENOMEM;
    }
    command->token = token;
    command->path = path;
    pthread_mutex_lock(&n->lock);
    *n->last_command = command;
    n->last_command = &command->next;
    pthread_mutex_unlock(&n->lock);
    (void)write(n->wake[1], "w", 1);
    return 0;
}

int tm_notify_watch(struct tm_notify *notify, uint64_t token, const char *path)
{
    char composed[1024];
    if (!token || !path || !tm_smb_compose(path, composed, sizeof(composed))) return EINVAL;
    char *copy = strdup(composed);
    return copy ? enqueue(notify, token, copy) : ENOMEM;
}

int tm_notify_unwatch(struct tm_notify *notify, uint64_t token)
{
    return token ? enqueue(notify, token, NULL) : EINVAL;
}

int tm_notify_settle(struct tm_notify *notify, int timeout_ms)
{
    struct timespec deadline;
    clock_gettime(CLOCK_REALTIME, &deadline);
    deadline.tv_sec += timeout_ms / 1000;
    deadline.tv_nsec += (long)(timeout_ms % 1000) * 1000000;
    if (deadline.tv_nsec >= 1000000000) {
        deadline.tv_sec++;
        deadline.tv_nsec -= 1000000000;
    }
    pthread_mutex_lock(&notify->lock);
    int result = 0;
    // An ended connection has settled once its socket is closed.
    while (notify->ended ? !notify->finished : (notify->commands || notify->busy || notify->closes > 0)) {
        if (pthread_cond_timedwait(&notify->changed, &notify->lock, &deadline) == ETIMEDOUT) {
            result = ETIMEDOUT;
            break;
        }
    }
    if (result) {
        notify->settle_expired = 1;
        (void)write(notify->wake[1], "s", 1);
        deadline.tv_sec += 2;
        while (!notify->finished && pthread_cond_timedwait(&notify->changed, &notify->lock, &deadline) != ETIMEDOUT) {}
    }
    pthread_mutex_unlock(&notify->lock);
    return result;
}

int tm_notify_echoes(struct tm_notify *notify)
{
    return atomic_load(&notify->echoes);
}

void tm_notify_close(struct tm_notify *notify)
{
    atomic_store(&notify->stopping, 1);
    if (pthread_equal(pthread_self(), notify->thread)) {
        pthread_mutex_lock(&notify->lock);
        notify->detached = 1;
        pthread_mutex_unlock(&notify->lock);
        pthread_detach(notify->thread);
        return;
    }
    (void)write(notify->wake[1], "c", 1);
    pthread_join(notify->thread, NULL);
    close(notify->wake[0]);
    close(notify->wake[1]);
    while (notify->commands) {
        struct command *next = notify->commands->next;
        free(notify->commands->path);
        free(notify->commands);
        notify->commands = next;
    }
    pthread_cond_destroy(&notify->changed);
    pthread_mutex_destroy(&notify->lock);
    free(notify);
}
