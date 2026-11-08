#ifndef TINYMOUNTER_SMB_NOTIFY_H
#define TINYMOUNTER_SMB_NOTIFY_H
#include <stddef.h>
#include <stdint.h>

// One connection that holds CHANGE_NOTIFY watches on a share, served by a thread of its own.

enum tm_notify_event {
    // A watch completed. `status` and the FILE_NOTIFY_INFORMATION `buffer` are the server's.
    // The watch is armed again after the callback returns for 0 and STATUS_NOTIFY_ENUM_DIR;
    // any other status ends that watch and closes its handle.
    TM_NOTIFY_COMPLETED = 1,
    // The folder of a watch could not be opened; `status` is the CREATE reply's.
    TM_NOTIFY_OPEN_FAILED = 2,
    // The connection failed or stopped answering. No other event follows. `token` is 0.
    TM_NOTIFY_ENDED = 3,
};

// Runs on the notify thread. It may call tm_notify_watch, tm_notify_unwatch and tm_notify_close.
typedef void (*tm_notify_callback)(void *context, int event, uint64_t token, uint32_t status,
                                   const uint8_t *buffer, uint32_t length);

struct tm_notify;

// Signs in on the calling thread as tm_edit_connect_password does: SMB 3, signing and encryption
// required, no guest. The password bytes are copied and every copy is zeroed after the connect. On failure, returns NULL with
// an errno value in `error` and the server's NTSTATUS, if any, in `ntstatus`.
struct tm_notify *tm_notify_open(const char *server, const char *share, const char *account,
                                 const uint8_t *password, size_t password_length, int echo_seconds,
                                 tm_notify_callback callback, void *context, int *error,
                                 uint32_t *ntstatus);
// Opens a share-relative folder and watches its own entries. Tokens are nonzero and unique.
int tm_notify_watch(struct tm_notify *notify, uint64_t token, const char *path);
// Closes the watch's handle. No event for the token follows.
int tm_notify_unwatch(struct tm_notify *notify, uint64_t token);
// Waits until the server confirmed every close. On timeout the connection ends: ETIMEDOUT.
int tm_notify_settle(struct tm_notify *notify, int timeout_ms);
// Number of echo replies, for checks.
int tm_notify_echoes(struct tm_notify *notify);
// After it returns, no callback runs. From the callback, it takes effect when that returns.
void tm_notify_close(struct tm_notify *notify);
#endif
