// Probe SMB2 CHANGE_NOTIFY through the vendored libsmb2 on the disposable Samba fixture.
// Run it through Tools/check-smb-notify.py, which supplies the address and credential.
// Every scenario prints JSON lines; names are probe-generated, never server values.
#include <errno.h>
#include <fcntl.h>
#include <inttypes.h>
#include <poll.h>
#include <pthread.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>
#include <smb2/smb2.h>
#include <smb2/libsmb2.h>
#include <smb2/libsmb2-raw.h>
#include "libsmb2-private.h"

#define STATUS_NOTIFY_CLEANUP 0x0000010Bu
#define STATUS_NOTIFY_ENUM_DIR 0x0000010Cu
#define NAMES 0x003u   // FILE_NAME | DIR_NAME
#define CONTENT 0x018u // SIZE | LAST_WRITE
#define DEFAULT_FILTER (NAMES | CONTENT | 0x004u | 0x040u | 0x100u | 0x200u | 0x400u | 0x800u)

static char *host, *share, *account, *password;
static char root[256];

static double now_ms(void)
{
    struct timespec t;
    clock_gettime(CLOCK_MONOTONIC, &t);
    return t.tv_sec * 1e3 + t.tv_nsec / 1e6;
}

static double wall(void)
{
    struct timespec t;
    clock_gettime(CLOCK_REALTIME, &t);
    return t.tv_sec + t.tv_nsec / 1e9;
}

static void fail(const char *what, struct smb2_context *smb)
{
    printf("{\"fatal\":\"%s\",\"detail\":\"%s\"}\n", what, smb ? smb2_get_error(smb) : "");
    exit(70);
}

struct watch;
static int arm(struct watch *w);

// MARK: Event log shared by the watcher thread and the main thread

struct event {
    double t, wall;
    int watch;
    uint32_t status, length;
    int count, malformed, actions[10];
    char *names; // "action name\n" lines, '/' separated
};

static struct {
    pthread_mutex_t lock;
    pthread_cond_t changed;
    struct event *items;
    int count, capacity;
} events = {PTHREAD_MUTEX_INITIALIZER, PTHREAD_COND_INITIALIZER, NULL, 0, 0};

static void parse(struct event *e, const uint8_t *buffer, uint32_t length)
{
    size_t used = 0, capacity = 256;
    e->names = calloc(capacity, 1);
    for (uint32_t offset = 0; offset + 12 <= length;) {
        uint32_t next, action, size;
        memcpy(&next, buffer + offset, 4);
        memcpy(&action, buffer + offset + 4, 4);
        memcpy(&size, buffer + offset + 8, 4);
        if (offset + 12 + size > length || size % 2) { e->malformed = 1; break; }
        uint16_t *units = malloc(size + 2);
        memcpy(units, buffer + offset + 12, size);
        char *name = (char *)smb2_utf16_to_utf8(units, size / 2);
        free(units);
        if (!name) { e->malformed = 1; break; }
        for (char *c = name; *c; ++c) if (*c == '\\') *c = '/';
        size_t needed = strlen(name) + 16;
        if (used + needed >= capacity) {
            while (used + needed >= capacity) capacity *= 2;
            e->names = realloc(e->names, capacity);
        }
        used += snprintf(e->names + used, capacity - used, "%u %s\n", action, name);
        free(name);
        e->count++;
        e->actions[action < 10 ? action : 0]++;
        if (!next) break;
        if (next < 12 || next % 4) { e->malformed = 1; break; }
        offset += next;
    }
}

static void record(struct event *e)
{
    pthread_mutex_lock(&events.lock);
    if (events.count == events.capacity) {
        events.capacity = events.capacity ? events.capacity * 2 : 256;
        events.items = realloc(events.items, events.capacity * sizeof(*e));
    }
    events.items[events.count++] = *e;
    pthread_cond_broadcast(&events.changed);
    pthread_mutex_unlock(&events.lock);
}

static int event_count(void)
{
    pthread_mutex_lock(&events.lock);
    int count = events.count;
    pthread_mutex_unlock(&events.lock);
    return count;
}

static int names_contain(const struct event *e, const char *name)
{
    if (!e->names) return 0;
    size_t length = strlen(name);
    for (const char *line = e->names; *line; line = strchr(line, '\n') + 1) {
        const char *start = strchr(line, ' ') + 1, *end = strchr(line, '\n');
        if ((size_t)(end - start) == length && !strncmp(start, name, length)) return 1;
    }
    return 0;
}

// Waits until an event at index >= from contains name (or any event when name is NULL).
static int wait_event(int from, const char *name, double timeout_ms, double *at)
{
    double end = now_ms() + timeout_ms;
    pthread_mutex_lock(&events.lock);
    for (;;) {
        for (int i = from; i < events.count; ++i) {
            if (!name || names_contain(&events.items[i], name) ||
                events.items[i].status == STATUS_NOTIFY_ENUM_DIR) {
                if (at) *at = events.items[i].t;
                pthread_mutex_unlock(&events.lock);
                return i;
            }
        }
        from = events.count;
        double left = end - now_ms();
        if (left <= 0) break;
        struct timespec until;
        clock_gettime(CLOCK_REALTIME, &until);
        long ns = until.tv_nsec + (long)(left > 50 ? 50e6 : left * 1e6);
        until.tv_sec += ns / 1000000000;
        until.tv_nsec = ns % 1000000000;
        pthread_cond_timedwait(&events.changed, &events.lock, &until);
    }
    pthread_mutex_unlock(&events.lock);
    return -1;
}

// Waits until no event arrived for quiet_ms, at most limit_ms.
static void settle(double quiet_ms, double limit_ms)
{
    double end = now_ms() + limit_ms;
    int seen = event_count();
    double last = now_ms();
    while (now_ms() < end && now_ms() - last < quiet_ms) {
        usleep(20000);
        int count = event_count();
        if (count != seen) { seen = count; last = now_ms(); }
    }
}

static void print_event(const struct event *e, double base, int full)
{
    printf("{\"event\":%d,\"t_ms\":%.1f,\"wall\":%.6f,\"status\":\"0x%08x\",\"bytes\":%u,\"entries\":%d",
           e->watch, e->t - base, e->wall, e->status, e->length, e->count);
    if (e->malformed) printf(",\"malformed\":true");
    printf(",\"actions\":{");
    for (int a = 0, first = 1; a < 10; ++a) {
        if (e->actions[a]) { printf("%s\"%d\":%d", first ? "" : ",", a, e->actions[a]); first = 0; }
    }
    printf("}");
    if (full && e->names) {
        printf(",\"names\":[");
        int first = 1;
        for (const char *line = e->names; *line; line = strchr(line, '\n') + 1) {
            int length = (int)(strchr(line, '\n') - line);
            printf("%s\"%.*s\"", first ? "" : ",", length, line);
            first = 0;
        }
        printf("]");
    }
    printf("}\n");
}

static void print_events(int from, double base, int full)
{
    pthread_mutex_lock(&events.lock);
    for (int i = from; i < events.count; ++i) print_event(&events.items[i], base, full);
    pthread_mutex_unlock(&events.lock);
    fflush(stdout);
}

// MARK: Connections and raw requests

static struct smb2_context *connect_share(int timeout)
{
    struct smb2_context *smb = smb2_init_context();
    if (!smb) fail("context", NULL);
    smb2_set_timeout(smb, timeout);
    smb2_set_authentication(smb, SMB2_SEC_NTLMSSP);
    smb2_set_user(smb, account);
    smb2_set_password(smb, password);
    smb2_set_sign(smb, 1);
    smb2_set_seal(smb, 1);
    if (smb2_connect_share(smb, host, share, NULL)) {
        smb2_destroy_context(smb);
        return NULL;
    }
    return smb;
}

static int pump(struct smb2_context *smb, double ms, volatile int *until)
{
    double end = now_ms() + ms;
    while ((!until || !*until) && now_ms() < end) {
        struct pollfd p = {.fd = smb2_get_fd(smb), .events = smb2_which_events(smb)};
        if (poll(&p, 1, 20) < 0 && errno != EINTR) return -1;
        if (smb2_service(smb, p.revents) < 0) return -1;
    }
    return 0;
}

struct reply { volatile int done; uint32_t status; smb2_file_id file; };

static void replied(struct smb2_context *smb, int status, void *data, void *opaque)
{
    struct reply *r = opaque;
    r->status = (uint32_t)status;
    if (!status && data && r->file[0] == 0xff) memcpy(r->file, ((struct smb2_create_reply *)data)->file_id, SMB2_FD_SIZE);
    r->done = 1;
}

static uint32_t wait_pdu(struct smb2_context *smb, struct smb2_pdu *pdu, struct reply *r)
{
    if (!pdu) return 0xffffffffu;
    smb2_queue_pdu(smb, pdu);
    if (pump(smb, 15000, &r->done) < 0 || !r->done) return 0xfffffffeu;
    return r->status;
}

static uint32_t open_directory(struct smb2_context *smb, const char *path, smb2_file_id file)
{
    struct smb2_create_request request = {0};
    request.impersonation_level = SMB2_IMPERSONATION_IMPERSONATION;
    request.desired_access = SMB2_FILE_LIST_DIRECTORY | SMB2_FILE_READ_ATTRIBUTES;
    request.share_access = SMB2_FILE_SHARE_READ | SMB2_FILE_SHARE_WRITE | SMB2_FILE_SHARE_DELETE;
    request.create_disposition = SMB2_FILE_OPEN;
    request.create_options = SMB2_FILE_DIRECTORY_FILE;
    request.name = path;
    struct reply r = {0};
    r.file[0] = 0xff;
    uint32_t status = wait_pdu(smb, smb2_cmd_create_async(smb, &request, replied, &r), &r);
    if (!status) memcpy(file, r.file, SMB2_FD_SIZE);
    return status;
}

static struct smb2_pdu *close_pdu(struct smb2_context *smb, smb2_file_id file, struct reply *r)
{
    struct smb2_close_request request = {0};
    memcpy(request.file_id, file, SMB2_FD_SIZE);
    return smb2_cmd_close_async(smb, &request, replied, r);
}

// libsmb2 has no client CANCEL; reuse the target's MessageId, which Samba matches.
static void send_cancel(struct smb2_context *smb, uint64_t message_id)
{
    struct smb2_pdu *pdu = smb2_allocate_pdu(smb, SMB2_CANCEL, NULL, NULL);
    uint8_t *body = calloc(1, 4);
    struct smb2_iovec *iov = smb2_add_iovector(smb, &pdu->out, body, 4, free);
    smb2_set_uint16(iov, 0, SMB2_CANCEL_REQUEST_SIZE);
    smb2_pad_to_64bit(smb, &pdu->out);
    pdu->header.credit_charge = 0;
    pdu->header.credit_request_response = 0;
    pdu->timeout = 0;
    uint64_t saved = smb->message_id;
    smb->message_id = message_id;
    smb2_queue_pdu(smb, pdu);
    smb->message_id = saved;
}

// MARK: Watches

struct watch {
    struct smb2_context *smb;
    smb2_file_id dir;
    uint32_t filter, buffer;
    int index, keep_timeout, charge, auto_rearm, flat;
    volatile int pending, stopped;
    uint64_t message_id;
    uint32_t last_status;
};

static void notified(struct smb2_context *smb, int status, void *data, void *opaque)
{
    struct watch *w = opaque;
    struct event e = {.t = now_ms(), .wall = wall(), .watch = w->index, .status = (uint32_t)status};
    if (data && (status == 0 || (uint32_t)status == STATUS_NOTIFY_ENUM_DIR)) {
        struct smb2_change_notify_reply *rep = data;
        e.length = rep->output_buffer_length;
        if (e.length) parse(&e, rep->output, e.length);
    }
    w->last_status = (uint32_t)status;
    w->pending = 0;
    if (status && (uint32_t)status != STATUS_NOTIFY_ENUM_DIR) w->stopped = 1;
    record(&e);
    if (w->auto_rearm && !w->stopped) arm(w);
}

static int arm(struct watch *w)
{
    struct smb2_change_notify_request request = {0};
    request.flags = w->flat ? 0 : SMB2_CHANGE_NOTIFY_WATCH_TREE;
    request.output_buffer_length = w->buffer;
    request.completion_filter = w->filter;
    memcpy(request.file_id, w->dir, SMB2_FD_SIZE);
    struct smb2_pdu *pdu = smb2_cmd_change_notify_async(w->smb, &request, notified, w);
    if (!pdu) return -1;
    // A notify stays pending indefinitely; libsmb2's per-request timeout would expire it.
    if (!w->keep_timeout) pdu->timeout = 0;
    if (w->charge) pdu->header.credit_charge = (uint16_t)((w->buffer + 65535) / 65536);
    w->pending = 1;
    smb2_queue_pdu(w->smb, pdu);
    if (w->pending) w->message_id = pdu->header.message_id;
    return 0;
}

// MARK: Watcher thread: owns one connection and re-arms after each completion

enum { CMD_NONE, CMD_CANCEL, CMD_CLOSE, CMD_ECHO, CMD_ARM };

static struct {
    struct watch w;
    pthread_t thread;
    int wake[2];
    volatile int stop, rearm, command, dead, closed;
    uint32_t close_status;
    double close_at;
    char error[256];
    double echo_ms;
    int echoes;
} watcher;

static void echoed(struct smb2_context *smb, int status, void *data, void *opaque)
{
    if (!status) watcher.echoes++;
}

static void *watch_thread(void *unused)
{
    struct reply closing = {0};
    while (!watcher.stop) {
        if (watcher.rearm && !watcher.w.pending && !watcher.w.stopped && !watcher.closed) arm(&watcher.w);
        int command = __atomic_exchange_n(&watcher.command, CMD_NONE, __ATOMIC_SEQ_CST);
        if (command == CMD_CANCEL && watcher.w.pending) send_cancel(watcher.w.smb, watcher.w.message_id);
        if (command == CMD_CLOSE) {
            watcher.closed = 1;
            smb2_queue_pdu(watcher.w.smb, close_pdu(watcher.w.smb, watcher.w.dir, &closing));
        }
        if (command == CMD_ECHO) smb2_queue_pdu(watcher.w.smb, smb2_cmd_echo_async(watcher.w.smb, echoed, NULL));
        if (command == CMD_ARM) { watcher.w.stopped = 0; if (!watcher.w.pending) arm(&watcher.w); }
        struct pollfd p[2] = {{.fd = smb2_get_fd(watcher.w.smb), .events = smb2_which_events(watcher.w.smb)},
                              {.fd = watcher.wake[0], .events = POLLIN}};
        if (poll(p, 2, 50) < 0 && errno != EINTR) break;
        if (p[1].revents) { char drain[16]; (void)read(watcher.wake[0], drain, sizeof(drain)); }
        if (smb2_service(watcher.w.smb, p[0].revents) < 0) {
            snprintf(watcher.error, sizeof(watcher.error), "%s", smb2_get_error(watcher.w.smb));
            struct event e = {.t = now_ms(), .wall = wall(), .watch = -1, .status = 0xffffffffu};
            watcher.dead = 1;
            record(&e);
            break;
        }
        if (closing.done && !watcher.close_at) { watcher.close_status = closing.status; watcher.close_at = now_ms(); }
    }
    return NULL;
}

static void command(int c)
{
    __atomic_store_n(&watcher.command, c, __ATOMIC_SEQ_CST);
    (void)write(watcher.wake[1], "x", 1);
    while (__atomic_load_n(&watcher.command, __ATOMIC_SEQ_CST) != CMD_NONE && !watcher.dead) usleep(1000);
}

static void start_watcher(const char *path, uint32_t filter, uint32_t buffer, int rearm)
{
    memset(&watcher, 0, sizeof(watcher));
    watcher.w.smb = connect_share(0);
    if (!watcher.w.smb) fail("watcher connect", NULL);
    if (open_directory(watcher.w.smb, path, watcher.w.dir)) fail("watcher open", watcher.w.smb);
    watcher.w.filter = filter;
    watcher.w.buffer = buffer;
    watcher.rearm = rearm;
    if (pipe(watcher.wake)) fail("pipe", NULL);
    if (!rearm) arm(&watcher.w);
    pthread_create(&watcher.thread, NULL, watch_thread, NULL);
}

static void stop_watcher(void)
{
    watcher.stop = 1;
    (void)write(watcher.wake[1], "x", 1);
    pthread_join(watcher.thread, NULL);
    smb2_destroy_context(watcher.w.smb);
    close(watcher.wake[0]);
    close(watcher.wake[1]);
}

// MARK: Actor operations on a second connection

static struct smb2_context *actor;

static char *at(const char *relative)
{
    static char paths[8][512];
    static int next;
    char *path = paths[next++ % 8];
    snprintf(path, 512, "%s%s%s", root, *relative ? "/" : "", relative);
    return path;
}

static int write_file(const char *relative, size_t size, int create, char fill)
{
    struct smb2fh *fh = smb2_open(actor, at(relative), O_WRONLY | (create ? O_CREAT | O_EXCL : 0));
    if (!fh) return -1;
    uint8_t *data = malloc(size ? size : 1);
    memset(data, fill, size);
    int result = size ? smb2_pwrite(actor, fh, data, (uint32_t)size, 0) : 0;
    free(data);
    smb2_close(actor, fh);
    return result < 0 ? result : 0;
}

static uint32_t set_basic(const char *relative, uint32_t attributes, time_t mtime)
{
    struct smb2fh *fh = smb2_open(actor, at(relative), O_RDWR);
    if (!fh) return 0xffffffffu;
    struct smb2_file_basic_info info = {0};
    info.file_attributes = attributes;
    info.last_write_time.tv_sec = mtime;
    struct smb2_set_info_request request = {0};
    request.info_type = SMB2_0_INFO_FILE;
    request.file_info_class = SMB2_FILE_BASIC_INFORMATION;
    request.input_data = &info;
    memcpy(request.file_id, smb2_get_file_id(fh), SMB2_FD_SIZE);
    struct reply r = {0};
    uint32_t status = wait_pdu(actor, smb2_cmd_set_info_async(actor, &request, replied, &r), &r);
    smb2_close(actor, fh);
    return status;
}

static void make_root(void)
{
    actor = connect_share(30);
    if (!actor) fail("actor connect", NULL);
    snprintf(root, sizeof(root), "probe-notify-%08x%04x", (unsigned)time(NULL), (unsigned)getpid() & 0xffff);
    if (smb2_mkdir(actor, root)) fail("mkdir root", actor);
}

static void remove_tree(const char *path)
{
    struct smb2dir *dir = smb2_opendir(actor, path);
    if (dir) {
        struct smb2dirent *entry;
        char child[1024];
        char (*names)[256] = NULL;
        int count = 0, types[4096];
        while ((entry = smb2_readdir(actor, dir)) && count < 4096) {
            if (!strcmp(entry->name, ".") || !strcmp(entry->name, "..")) continue;
            names = realloc(names, (count + 1) * sizeof(*names));
            snprintf(names[count], 256, "%s", entry->name);
            types[count++] = entry->st.smb2_type;
        }
        smb2_closedir(actor, dir);
        for (int i = 0; i < count; ++i) {
            snprintf(child, sizeof(child), "%s/%s", path, names[i]);
            if (types[i] == SMB2_TYPE_DIRECTORY) remove_tree(child);
            else smb2_unlink(actor, child);
        }
        free(names);
    }
    smb2_rmdir(actor, path);
}

static void finish_root(void)
{
    remove_tree(root);
    struct smb2_stat_64 st;
    printf("{\"cleanup\":\"%s\"}\n", smb2_stat(actor, root, &st) ? "removed" : "left");
    smb2_destroy_context(actor);
}

static double median(double *values, int count)
{
    for (int i = 1; i < count; ++i)
        for (int j = i; j > 0 && values[j - 1] > values[j]; --j) { double t = values[j]; values[j] = values[j - 1]; values[j - 1] = t; }
    return count ? (count % 2 ? values[count / 2] : (values[count / 2 - 1] + values[count / 2]) / 2) : -1;
}

static void print_samples(const char *name, double *values, int count, int missed)
{
    double copy[4096];
    memcpy(copy, values, count * sizeof(double));
    double m = median(copy, count);
    printf("{\"latency\":\"%s\",\"samples\":%d,\"missed\":%d,\"median_ms\":%.1f,\"p90_ms\":%.1f,\"min_ms\":%.1f,\"max_ms\":%.1f}\n",
           name, count, missed, m, count ? copy[(count * 9) / 10 < count ? (count * 9) / 10 : count - 1] : -1,
           count ? copy[0] : -1, count ? copy[count - 1] : -1);
}

// MARK: Scenarios

typedef int (*step_fn)(void);
struct step { const char *name, *expect; step_fn run; };

static int s_mkdir(void) { return smb2_mkdir(actor, at("sub")) | smb2_mkdir(actor, at("sub/deep")); }
static int s_create(void) { return write_file("sub/deep/f.txt", 0, 1, 0); }
static int s_write(void) { return write_file("sub/deep/f.txt", 4096, 0, 'a'); }
static int s_same_size(void) { return write_file("sub/deep/f.txt", 4096, 0, 'b'); }
static int s_attributes(void) { return set_basic("sub/deep/f.txt", SMB2_FILE_ATTRIBUTE_HIDDEN, 0) ? -1 : 0; }
static int s_mtime(void) { return set_basic("sub/deep/f.txt", 0, time(NULL) - 86400) ? -1 : 0; }
static int s_stream(void) { return write_file("sub/deep/f.txt:probe-stream", 16, 1, 's'); }
static int s_rename(void) { return smb2_rename(actor, at("sub/deep/f.txt"), at("sub/deep/g.txt")); }
static int s_move(void) { return smb2_rename(actor, at("sub/deep/g.txt"), at("sub/g.txt")); }
static int s_delete(void) { return smb2_unlink(actor, at("sub/g.txt")); }
static int s_rename_dir(void) { return smb2_rename(actor, at("sub/deep"), at("sub/deep2")); }
static int s_rmdir(void) { return smb2_rmdir(actor, at("sub/deep2")); }

static void coverage(uint32_t filter)
{
    make_root();
    start_watcher(root, filter, 65536, 1);
    usleep(300000);
    printf("{\"scenario\":\"coverage\",\"filter\":\"0x%03x\"}\n", filter);
    struct step steps[] = {
        {"mkdir sub/deep", "sub/deep", s_mkdir}, {"create empty file", "sub/deep/f.txt", s_create},
        {"write 4 KiB", "sub/deep/f.txt", s_write}, {"rewrite same size", "sub/deep/f.txt", s_same_size},
        {"set hidden attribute", "sub/deep/f.txt", s_attributes}, {"set mtime only", "sub/deep/f.txt", s_mtime},
        {"write named stream", "sub/deep/f.txt:probe-stream", s_stream}, {"rename file", "sub/deep/g.txt", s_rename},
        {"move file up", "sub/g.txt", s_move}, {"delete file", "sub/g.txt", s_delete},
        {"rename folder", "sub/deep2", s_rename_dir}, {"remove folder", "sub/deep2", s_rmdir},
    };
    for (size_t i = 0; i < sizeof(steps) / sizeof(*steps); ++i) {
        int from = event_count();
        double start = now_ms(), first = -1;
        int result = steps[i].run();
        double done = now_ms();
        wait_event(from, steps[i].expect, 2000, &first);
        settle(400, 3000);
        printf("{\"step\":\"%s\",\"result\":%d,\"op_ms\":%.1f,\"first_event_ms\":%.1f}\n",
               steps[i].name, result, done - start, first >= 0 ? first - start : -1);
        print_events(from, start, 1);
    }
    // Changes while no request is pending: does the server keep them for the next request?
    watcher.rearm = 0;
    int from = event_count();
    write_file("gap-a", 0, 1, 0);
    wait_event(from, "gap-a", 2000, NULL);
    settle(300, 2000);
    write_file("gap-b", 0, 1, 0);
    write_file("gap-c", 0, 1, 0);
    usleep(1500000);
    from = event_count();
    double armed = now_ms(), first = -1;
    command(CMD_ARM);
    wait_event(from, "gap-c", 3000, &first);
    settle(300, 2000);
    printf("{\"step\":\"changes made while not armed, then re-arm\",\"first_event_ms\":%.1f}\n", first >= 0 ? first - armed : -1);
    print_events(from, armed, 1);
    watcher.rearm = 1;
    stop_watcher();
    finish_root();
}

// Content-only changes: does the server report writes, and when?
static void content(void)
{
    make_root();
    smb2_mkdir(actor, at("sub"));
    write_file("top.bin", 0, 1, 0);
    write_file("sub/nested.bin", 0, 1, 0);
    start_watcher(root, DEFAULT_FILTER, 65536, 1);
    usleep(300000);
    printf("{\"scenario\":\"content\"}\n");
    const char *files[] = {"top.bin", "sub/nested.bin"};
    for (int f = 0; f < 2; ++f) {
        int from = event_count();
        double start = now_ms();
        write_file(files[f], 8192, 0, 'x');
        settle(5000, 6000);
        printf("{\"case\":\"open, extend to 8 KiB, close\",\"file\":\"%s\"}\n", files[f]);
        print_events(from, start, 1);
        from = event_count();
        start = now_ms();
        struct smb2fh *fh = smb2_open(actor, at(files[f]), O_WRONLY);
        uint8_t data[4096];
        memset(data, 'y', sizeof(data));
        smb2_pwrite(actor, fh, data, sizeof(data), 0);
        usleep(4000000);
        double closing = now_ms();
        smb2_close(actor, fh);
        settle(3000, 4000);
        printf("{\"case\":\"same-size write, handle held 4 s\",\"file\":\"%s\",\"close_at_ms\":%.0f}\n", files[f], closing - start);
        print_events(from, start, 1);
        from = event_count();
        start = now_ms();
        fh = smb2_open(actor, at(files[f]), O_WRONLY);
        smb2_ftruncate(actor, fh, 100);
        smb2_close(actor, fh);
        settle(3000, 4000);
        printf("{\"case\":\"truncate to 100 bytes\",\"file\":\"%s\"}\n", files[f]);
        print_events(from, start, 1);
    }
    stop_watcher();
    finish_root();
}

// Per-folder watches without WATCH_TREE, several on one connection.
static void flat(void)
{
    make_root();
    smb2_mkdir(actor, at("sub"));
    smb2_mkdir(actor, at("sub/deep"));
    write_file("top.bin", 0, 1, 0);
    write_file("sub/a.bin", 0, 1, 0);
    write_file("sub/deep/b.bin", 0, 1, 0);
    struct smb2_context *smb = connect_share(0);
    if (!smb) fail("connect", NULL);
    const char *folders[] = {"", "sub", "sub/deep"};
    struct watch w[3];
    for (int i = 0; i < 3; ++i) {
        w[i] = (struct watch){.smb = smb, .filter = DEFAULT_FILTER, .buffer = 65536, .index = i, .auto_rearm = 1, .flat = 1};
        if (open_directory(smb, at(folders[i]), w[i].dir)) fail("open", smb);
        arm(&w[i]);
    }
    pump(smb, 500, NULL);
    printf("{\"scenario\":\"flat\",\"watches\":[\"root\",\"sub\",\"sub/deep\"]}\n");
    struct { const char *name; int kind; const char *path; } steps[] = {
        {"write top.bin", 0, "top.bin"}, {"write sub/a.bin", 0, "sub/a.bin"}, {"write sub/deep/b.bin", 0, "sub/deep/b.bin"},
        {"create sub/deep/c.bin", 1, "sub/deep/c.bin"}, {"set mtime sub/a.bin", 2, "sub/a.bin"},
    };
    for (size_t i = 0; i < sizeof(steps) / sizeof(*steps); ++i) {
        int from = event_count();
        double start = now_ms();
        if (steps[i].kind == 0) write_file(steps[i].path, 4096, 0, 'z');
        else if (steps[i].kind == 1) write_file(steps[i].path, 0, 1, 0);
        else set_basic(steps[i].path, 0, time(NULL) - 3600);
        pump(smb, 3000, NULL);
        printf("{\"step\":\"%s\"}\n", steps[i].name);
        print_events(from, start, 1);
    }
    smb2_destroy_context(smb);
    finish_root();
}

static void latency(int iterations, int depth)
{
    make_root();
    char folder[256] = "";
    for (int d = 0; d < depth; ++d) {
        strcat(folder, d ? "/n" : "n");
        smb2_mkdir(actor, at(folder));
    }
    start_watcher(root, DEFAULT_FILTER, 65536, 1);
    usleep(300000);
    double created[512], removed[512], written[512];
    int nc = 0, nr = 0, nw = 0, missed = 0;
    for (int i = 0; i < iterations && i < 512; ++i) {
        char name[300], expect[300];
        snprintf(name, sizeof(name), "%s%sl%d", folder, *folder ? "/" : "", i);
        snprintf(expect, sizeof(expect), "%s", name);
        int from = event_count();
        double start = now_ms(), t;
        write_file(name, 0, 1, 0);
        if (wait_event(from, expect, 3000, &t) >= 0) created[nc++] = t - start; else missed++;
        settle(150, 1000);
        from = event_count();
        start = now_ms();
        write_file(name, 512, 0, 'w');
        if (wait_event(from, expect, 3000, &t) >= 0) written[nw++] = t - start; else missed++;
        settle(150, 1000);
        from = event_count();
        start = now_ms();
        smb2_unlink(actor, at(name));
        if (wait_event(from, expect, 3000, &t) >= 0) removed[nr++] = t - start; else missed++;
        settle(150, 1000);
    }
    printf("{\"scenario\":\"latency\",\"depth\":%d}\n", depth);
    print_samples("create", created, nc, 0);
    print_samples("write", written, nw, 0);
    print_samples("delete", removed, nr, missed);
    stop_watcher();
    finish_root();
}

static void burst(int count, uint32_t buffer, int late)
{
    make_root();
    smb2_mkdir(actor, at("b"));
    start_watcher(root, DEFAULT_FILTER, buffer, !late);
    usleep(300000);
    if (late) {
        // One reply consumes the pending request; the burst then arrives with none pending.
        int from = event_count();
        write_file("trigger", 0, 1, 0);
        wait_event(from, "trigger", 3000, NULL);
    }
    int from = event_count();
    double start = now_ms();
    char name[64];
    for (int i = 0; i < count; ++i) {
        snprintf(name, sizeof(name), "b/f%05d", i);
        if (write_file(name, 0, 1, 0)) fail("burst create", actor);
    }
    double created = now_ms();
    if (late) {
        usleep(1000000);
        watcher.rearm = 1;
        command(CMD_ARM);
    }
    settle(1500, 30000);
    int to = event_count();
    int entries = 0, enum_dir = 0, replies = 0, malformed = 0, max_entries = 0;
    uint32_t max_bytes = 0;
    int seen = 0;
    pthread_mutex_lock(&events.lock);
    for (int i = from; i < to; ++i) {
        struct event *e = &events.items[i];
        replies++;
        entries += e->count;
        malformed += e->malformed;
        if (e->count > max_entries) max_entries = e->count;
        if (e->length > max_bytes) max_bytes = e->length;
        if (e->status == STATUS_NOTIFY_ENUM_DIR) enum_dir++;
    }
    for (int k = 0; k < count; ++k) {
        snprintf(name, sizeof(name), "b/f%05d", k);
        for (int i = from; i < to; ++i) if (names_contain(&events.items[i], name)) { seen++; break; }
    }
    double last = to > from ? events.items[to - 1].t - start : -1;
    pthread_mutex_unlock(&events.lock);
    printf("{\"scenario\":\"burst\",\"files\":%d,\"buffer\":%u,\"late_arm\":%d,\"create_ms\":%.0f,\"replies\":%d,"
           "\"entries\":%d,\"distinct_names_seen\":%d,\"enum_dir\":%d,\"malformed\":%d,\"max_entries_per_reply\":%d,"
           "\"max_reply_bytes\":%u,\"last_event_ms\":%.0f}\n",
           count, buffer, late, created - start, replies, entries, seen, enum_dir, malformed, max_entries, max_bytes, last);
    if (late) print_events(from, start, 0);
    stop_watcher();
    finish_root();
}

static void buffers(void)
{
    make_root();
    struct smb2_context *smb = connect_share(0);
    if (!smb) fail("connect", NULL);
    printf("{\"scenario\":\"buffers\",\"max_transact\":%u,\"max_read\":%u}\n", smb->max_transact_size, smb->max_read_size);
    uint32_t sizes[] = {0, 4096, 65536, 65537, 1048576, 8388608, 8388609};
    for (int charge = 0; charge < 2; ++charge) {
        for (size_t i = 0; i < sizeof(sizes) / sizeof(*sizes); ++i) {
            struct watch w = {.smb = smb, .filter = DEFAULT_FILTER, .buffer = sizes[i], .charge = charge};
            if (open_directory(smb, root, w.dir)) fail("open", smb);
            int from = event_count();
            arm(&w);
            pump(smb, 300, NULL);
            char name[64];
            snprintf(name, sizeof(name), "buf-%d-%zu", charge, i);
            write_file(name, 0, 1, 0);
            pump(smb, 1500, NULL);
            int done = !w.pending;
            struct reply r = {0};
            wait_pdu(smb, close_pdu(smb, w.dir, &r), &r);
            pump(smb, 300, NULL);
            pthread_mutex_lock(&events.lock);
            struct event *e = events.count > from ? &events.items[from] : NULL;
            printf("{\"buffer\":%u,\"credit_charge\":%d,\"completed_by_change\":%d,\"status\":\"0x%08x\",\"entries\":%d}\n",
                   sizes[i], charge ? (int)((sizes[i] + 65535) / 65536) : 1, done, e ? e->status : 0, e ? e->count : -1);
            pthread_mutex_unlock(&events.lock);
        }
    }
    smb2_destroy_context(smb);
    finish_root();
}

static void shared(void)
{
    make_root();
    write_file("data.bin", 65536, 1, 'd');
    struct smb2_context *smb = connect_share(10);
    if (!smb) fail("connect", NULL);
    struct watch w = {.smb = smb, .filter = DEFAULT_FILTER, .buffer = 65536, .auto_rearm = 1};
    if (open_directory(smb, root, w.dir)) fail("open", smb);
    printf("{\"scenario\":\"shared\",\"connection_timeout_s\":10}\n");
    double base = now_ms();
    arm(&w);
    pump(smb, 200, NULL);
    // Ordinary synchronous calls on the same connection while the notify is pending.
    for (int round = 0; round < 3; ++round) {
        double t0 = now_ms();
        struct smb2dir *dir = smb2_opendir(smb, root);
        int entries = 0;
        if (dir) { while (smb2_readdir(smb, dir)) entries++; smb2_closedir(smb, dir); }
        double t1 = now_ms();
        struct smb2fh *fh = smb2_open(smb, at("data.bin"), O_RDONLY);
        uint8_t buffer[65536];
        int read = fh ? smb2_pread(smb, fh, buffer, sizeof(buffer), 0) : -1;
        if (fh) smb2_close(smb, fh);
        double t2 = now_ms();
        printf("{\"round\":%d,\"events_so_far\":%d,\"list_entries\":%d,\"list_ms\":%.1f,\"read_bytes\":%d,\"read_ms\":%.1f}\n",
               round, event_count(), entries, t1 - t0, read, t2 - t1);
        if (round == 1) {
            // Change made by the other connection; the next sync call on this one delivers it.
            write_file("during-sync", 0, 1, 0);
            usleep(300000);
        }
    }
    print_events(0, base, 1);
    // 15 s idle with a pending notify whose request timeout is cleared; connection timeout is 10 s.
    pump(smb, 1000, NULL);
    int from = event_count();
    int pumped = pump(smb, 15000, NULL);
    printf("{\"idle_15s_timeout_cleared\":{\"service\":%d,\"callbacks\":%d,\"pending\":%d}}\n",
           pumped, event_count() - from, w.pending);
    int echo = smb2_echo(smb);
    printf("{\"sync_echo\":%d,\"detail\":\"%s\"}\n", echo, echo ? smb2_get_error(smb) : "");
    struct reply r = {0};
    printf("{\"async_echo_status\":\"0x%08x\"}\n", wait_pdu(smb, smb2_cmd_echo_async(smb, replied, &r), &r));
    double start = now_ms();
    write_file("after-idle", 0, 1, 0);
    pumped = pump(smb, 1500, NULL);
    printf("{\"change_after_idle\":{\"service\":%d}}\n", pumped);
    print_events(from, start, 1);
    // A second watch on the same connection keeps libsmb2's request timeout.
    struct watch t = {.smb = smb, .filter = DEFAULT_FILTER, .buffer = 65536, .index = 1, .keep_timeout = 1};
    if (open_directory(smb, root, t.dir)) fail("open", smb);
    from = event_count();
    double armed = now_ms();
    arm(&t);
    pumped = pump(smb, 13000, NULL);
    printf("{\"timeout_left_on\":{\"service\":%d,\"after_ms\":%.0f}}\n", pumped, now_ms() - armed);
    print_events(from, armed, 1);
    from = event_count();
    start = now_ms();
    write_file("after-timeout", 0, 1, 0);
    pumped = pump(smb, 2000, NULL);
    printf("{\"late_server_reply_after_local_timeout\":{\"service\":%d,\"error\":\"%s\"}}\n", pumped,
           pumped < 0 ? smb2_get_error(smb) : "");
    print_events(from, start, 1);
    smb2_destroy_context(smb);
    finish_root();
}

// 4,000 watches on one folder made Samba 4.19's notifyd exhaust memory; stay near 1,000 or below.
static void many(int count)
{
    make_root();
    struct smb2_context *smb = connect_share(0);
    if (!smb) fail("connect", NULL);
    struct watch *w = calloc(count, sizeof(*w));
    int opened = 0;
    uint32_t open_status = 0;
    for (; opened < count; ++opened) {
        w[opened] = (struct watch){.smb = smb, .filter = DEFAULT_FILTER, .buffer = 4096, .index = opened};
        if ((open_status = open_directory(smb, root, w[opened].dir))) break;
    }
    double t0 = now_ms();
    for (int i = 0; i < opened; ++i) arm(&w[i]);
    pump(smb, 2000, NULL);
    int early = event_count();
    int credits = smb->credits;
    int from = event_count();
    double start = now_ms();
    write_file("many-trigger", 0, 1, 0);
    double end = start + 20000;
    while (now_ms() < end && event_count() - from < opened) if (pump(smb, 100, NULL) < 0) break;
    int got = event_count() - from, ok = 0;
    pthread_mutex_lock(&events.lock);
    double last = got ? events.items[events.count - 1].t - start : -1;
    uint32_t odd = 0;
    for (int i = from; i < events.count; ++i) {
        if (names_contain(&events.items[i], "many-trigger")) ok++;
        else odd = events.items[i].status;
    }
    pthread_mutex_unlock(&events.lock);
    // A second round shows every watch re-arms on the same connection.
    from = event_count();
    for (int i = 0; i < opened; ++i) if (!w[i].pending && !w[i].stopped) arm(&w[i]);
    pump(smb, 1000, NULL);
    write_file("many-second", 0, 1, 0);
    end = now_ms() + 20000;
    while (now_ms() < end && event_count() - from < opened) if (pump(smb, 100, NULL) < 0) break;
    int second = event_count() - from;
    for (int i = 0; i < opened; ++i) {
        struct reply r = {0};
        smb2_queue_pdu(smb, close_pdu(smb, w[i].dir, &r));
        if (i % 64 == 63) pump(smb, 200, NULL);
    }
    pump(smb, 2000, NULL);
    printf("{\"scenario\":\"many\",\"requested\":%d,\"opened\":%d,\"open_status\":\"0x%08x\",\"arm_ms\":%.0f,"
           "\"early_completions\":%d,\"credits_after_arm\":%d,\"replies\":%d,\"with_name\":%d,\"other_status\":\"0x%08x\","
           "\"last_reply_ms\":%.0f,\"second_round_replies\":%d}\n",
           count, opened, open_status, start - t0, early, credits, got, ok, odd, last, second);
    free(w);
    smb2_destroy_context(smb);
    finish_root();
}

static void cancellation(void)
{
    make_root();
    smb2_mkdir(actor, at("victim"));
    smb2_mkdir(actor, at("victim2"));
    printf("{\"scenario\":\"cancellation\"}\n");
    // SMB2 CANCEL on a pending notify.
    start_watcher(root, DEFAULT_FILTER, 65536, 0);
    usleep(500000);
    int from = event_count();
    double start = now_ms(), t = -1;
    command(CMD_CANCEL);
    wait_event(from, NULL, 3000, &t);
    printf("{\"case\":\"cancel\",\"completion_ms\":%.1f,\"status\":\"0x%08x\",\"connection_alive\":%d}\n",
           t >= 0 ? t - start : -1, watcher.w.last_status, !watcher.dead);
    command(CMD_ARM);
    usleep(300000);
    from = event_count();
    write_file("after-cancel", 0, 1, 0);
    printf("{\"case\":\"re-arm after cancel\",\"delivered\":%d}\n", wait_event(from, "after-cancel", 3000, NULL) >= 0);
    // Closing the directory handle with a notify pending; drain queued changes first.
    watcher.rearm = 1;
    settle(800, 3000);
    watcher.rearm = 0;
    usleep(200000);
    from = event_count();
    start = now_ms();
    command(CMD_CLOSE);
    wait_event(from, NULL, 3000, &t);
    usleep(300000);
    printf("{\"case\":\"close handle\",\"completion_ms\":%.1f,\"status\":\"0x%08x\",\"close_status\":\"0x%08x\","
           "\"notify_before_close_reply\":%d}\n", t >= 0 ? t - start : -1, watcher.w.last_status, watcher.close_status,
           t >= 0 && watcher.close_at && t <= watcher.close_at);
    stop_watcher();
    // Another client renames, then deletes, the watched folder itself.
    const char *cases[][2] = {{"rename watched folder", "victim"}, {"delete watched folder", "victim2"}};
    for (int c = 0; c < 2; ++c) {
        start_watcher(at(cases[c][1]), DEFAULT_FILTER, 65536, 1);
        usleep(300000);
        from = event_count();
        start = now_ms();
        int result = c ? smb2_rmdir(actor, at("victim2")) : smb2_rename(actor, at("victim"), at("victim-renamed"));
        settle(1000, 3000);
        printf("{\"case\":\"%s\",\"result\":%d,\"detail\":\"%s\",\"events\":%d,\"last_status\":\"0x%08x\"}\n",
               cases[c][0], result, result ? smb2_get_error(actor) : "", event_count() - from, watcher.w.last_status);
        print_events(from, start, 1);
        if (!c) {
            from = event_count();
            write_file("victim-renamed/inside", 0, 1, 0);
            printf("{\"case\":\"change inside renamed watched folder\",\"delivered\":%d}\n",
                   wait_event(from, "inside", 2000, NULL) >= 0);
        }
        stop_watcher();
    }
    finish_root();
}

// Watches path for seconds and prints events as they arrive; reconnects when the connection drops.
static void listen_folder(const char *path, int seconds, int echo_s)
{
    actor = connect_share(30);
    if (!actor) fail("actor connect", NULL);
    double best = 1e9, offset = 0;
    for (int i = 0; i < 5; ++i) {
        char name[128];
        snprintf(name, sizeof(name), "%s/probe-clock-%d", path, i);
        double t0 = wall();
        struct smb2fh *fh = smb2_open(actor, name, O_WRONLY | O_CREAT | O_EXCL);
        double t1 = wall();
        if (!fh) fail("clock probe", actor);
        smb2_close(actor, fh);
        struct smb2_stat_64 st;
        smb2_stat(actor, name, &st);
        smb2_unlink(actor, name);
        if (t1 - t0 < best) { best = t1 - t0; offset = st.smb2_mtime + st.smb2_mtime_nsec / 1e9 - (t0 + t1) / 2; }
    }
    usleep(1500000);
    printf("{\"scenario\":\"listen\",\"server_minus_client_s\":%.4f,\"offset_uncertainty_ms\":%.1f}\n", offset, best * 500);
    start_watcher(path, DEFAULT_FILTER, 65536, 1);
    printf("{\"ready_wall\":%.3f}\n", wall());
    fflush(stdout);
    double end = now_ms() + seconds * 1000.0, next_echo = now_ms() + echo_s * 1000.0;
    int printed = 0;
    while (now_ms() < end) {
        usleep(50000);
        int count = event_count();
        if (count > printed) { print_events(printed, 0, 1); printed = count; }
        if (echo_s && now_ms() >= next_echo && !watcher.dead) { command(CMD_ECHO); next_echo += echo_s * 1000.0; }
        if (watcher.dead || watcher.w.stopped) {
            printf("{\"lost\":{\"wall\":%.3f,\"dead\":%d,\"status\":\"0x%08x\",\"error\":\"%s\"}}\n", wall(), watcher.dead,
                   watcher.w.last_status, watcher.error);
            fflush(stdout);
            stop_watcher();
            double t0 = now_ms();
            for (;;) {
                struct smb2_context *probe = connect_share(0);
                smb2_file_id dir;
                if (probe && !open_directory(probe, path, dir)) { smb2_destroy_context(probe); break; }
                if (probe) smb2_destroy_context(probe);
                if (now_ms() > end) { printf("{\"reconnect\":\"gave up\"}\n"); return; }
                usleep(1000000);
            }
            start_watcher(path, DEFAULT_FILTER, 65536, 1);
            printf("{\"rearmed_after_ms\":%.0f,\"wall\":%.3f,\"relist_needed\":true}\n", now_ms() - t0, wall());
            fflush(stdout);
        }
    }
    printf("{\"done\":true,\"echoes\":%d,\"alive\":%d}\n", watcher.echoes, !watcher.dead);
    stop_watcher();
    smb2_destroy_context(actor);
}

static void idle(int seconds, int echo_s)
{
    make_root();
    start_watcher(root, DEFAULT_FILTER, 65536, 1);
    double end = now_ms() + seconds * 1000.0, next_echo = now_ms() + echo_s * 1000.0;
    while (now_ms() < end && !watcher.dead) {
        usleep(200000);
        if (echo_s && now_ms() >= next_echo) { command(CMD_ECHO); next_echo += echo_s * 1000.0; }
    }
    int early = event_count();
    // The actor connection was idle too; reconnect it so only the watcher is under test.
    smb2_destroy_context(actor);
    actor = connect_share(30);
    if (!actor) fail("actor reconnect", NULL);
    double start = now_ms(), t = -1;
    write_file("after-idle", 0, 1, 0);
    int got = wait_event(early, "after-idle", 5000, &t) >= 0;
    printf("{\"scenario\":\"idle\",\"seconds\":%d,\"echo_s\":%d,\"echoes\":%d,\"events_during_idle\":%d,\"dead\":%d,"
           "\"error\":\"%s\",\"delivered_after_idle\":%d,\"latency_ms\":%.1f}\n",
           seconds, echo_s, watcher.echoes, early, watcher.dead, watcher.error, got, got ? t - start : -1);
    stop_watcher();
    finish_root();
}

int main(int argc, char **argv)
{
    setvbuf(stdout, NULL, _IOLBF, 0);
    host = getenv("TM_NOTIFY_HOST");
    share = getenv("TM_NOTIFY_SHARE");
    account = getenv("TM_NOTIFY_ACCOUNT");
    static char line[512];
    if (!host || !share || !account || !fgets(line, sizeof(line), stdin)) { fputs("missing fixture settings\n", stderr); return 64; }
    line[strcspn(line, "\n")] = 0;
    password = line;
    const char *mode = argc > 1 ? argv[1] : "";
    if (!strcmp(mode, "coverage")) coverage(argc > 2 ? (uint32_t)strtoul(argv[2], NULL, 0) : DEFAULT_FILTER);
    else if (!strcmp(mode, "content")) content();
    else if (!strcmp(mode, "flat")) flat();
    else if (!strcmp(mode, "latency")) latency(argc > 2 ? atoi(argv[2]) : 20, argc > 3 ? atoi(argv[3]) : 0);
    else if (!strcmp(mode, "burst")) burst(atoi(argv[2]), (uint32_t)strtoul(argv[3], NULL, 0), argc > 4 && !strcmp(argv[4], "late"));
    else if (!strcmp(mode, "buffers")) buffers();
    else if (!strcmp(mode, "shared")) shared();
    else if (!strcmp(mode, "many")) many(atoi(argv[2]));
    else if (!strcmp(mode, "cancel")) cancellation();
    else if (!strcmp(mode, "listen")) listen_folder(argv[2], atoi(argv[3]), argc > 4 ? atoi(argv[4]) : 0);
    else if (!strcmp(mode, "idle")) idle(atoi(argv[2]), argc > 3 ? atoi(argv[3]) : 0);
    else { fputs("usage: coverage|content|flat|latency|burst|buffers|shared|many|cancel|listen|idle\n", stderr); return 64; }
    return 0;
}
