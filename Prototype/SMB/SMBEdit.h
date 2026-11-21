#ifndef TINYMOUNTER_SMB_EDIT_H
#define TINYMOUNTER_SMB_EDIT_H
#include <stddef.h>
#include <stdint.h>

// A password login over NTLMSSP: SMB 3 only, with signing and encryption required.
struct tm_smb_login {
    const char *server;
    // "name", "DOMAIN\\name", "DOMAIN;name" or "name@domain".
    const char *account;
    // UTF-8 without a terminator. Copied only for libsmb2, which zeroes its copies after connect.
    const uint8_t *password;
    size_t password_length;
};

// On failure, *status is the server's NTSTATUS for the refused step, or 0 if none arrived.
// previous_session, unless 0, is a session this process dropped: the server ends it and its opens.
void *tm_edit_connect_password(const struct tm_smb_login *login, const char *share,
                               uint64_t previous_session, int *error, uint32_t *status);
void tm_edit_disconnect(void *opaque);
// The server's ID for the session, also after a drop.
uint64_t tm_edit_session(void *opaque);
// The ID of the session that a failed request dropped with its connection; 0 while it is open.
uint64_t tm_edit_dropped_session(void *opaque);
// Zero means the preceding operation had no failure with a decoded server reply.
// Copy immediately: the next operation clears this, including successful cleanup closes.
uint32_t tm_edit_last_ntstatus(void *opaque);
// Path arguments are share-relative and reach the server composed (NFC), as from the macOS client.
int tm_edit_open(void *opaque, const char *path, uint32_t access, uint32_t sharing,
               uint8_t *file);
int tm_edit_create(void *opaque, const char *path, uint32_t access, uint8_t *file);
int tm_edit_close(void *opaque, uint8_t *file);
// Close attributes: creation, modification and change times in microseconds, size, attributes.
int tm_edit_close_info(void *opaque, uint8_t *file, uint64_t *values);
int tm_edit_open_directory(void *opaque, const char *path, uint32_t access, uint32_t sharing,
                         uint8_t *file);
int tm_edit_set_size(void *opaque, uint8_t *file, uint64_t size);
// FileBasicInformation with only LastWriteTime set, in microseconds since 1970; the rest stay.
int tm_edit_set_write_time(void *opaque, uint8_t *file, uint64_t microseconds);
int tm_edit_info(void *opaque, uint8_t *file, uint64_t *values);
int tm_edit_list(void *opaque, uint8_t *directory, int restart, uint8_t *buffer,
                 uint32_t capacity, uint32_t *count, int *finished);
enum {
    TM_SMB_READ_SIZE = 1024 * 1024,
    TM_SMB_READ_DEPTH = 4,
    TM_SMB_READ_BATCH_SIZE = TM_SMB_READ_SIZE * TM_SMB_READ_DEPTH
};
int tm_edit_read(void *opaque, uint8_t *file, uint64_t offset, uint8_t *buffer, uint32_t length,
               uint32_t *count);
int tm_edit_write(void *opaque, uint8_t *file, uint64_t offset, const uint8_t *buffer, uint32_t length,
                  uint32_t *count);
int tm_edit_rename(void *opaque, uint8_t *file, const char *destination);
int tm_edit_delete(void *opaque, uint8_t *file);
int tm_edit_flush(void *opaque, uint8_t *file);

typedef int (*tm_smb_folder_callback)(void *context, uint64_t file_id, uint64_t birth_us);
struct tm_smb_folder_trace;
// Folder creation and initial naming on this connection; paths are share-relative and composed.
int tm_edit_create_folder(void *opaque, const char *path, uint64_t expected_id, uint64_t expected_birth,
                          tm_smb_folder_callback receipt, void *context, int *create_sent,
                          struct tm_smb_folder_trace *trace);
int tm_edit_name_folder(void *opaque, const char *source, const char *destination, uint64_t expected_id,
                        uint64_t expected_birth, int recovery_only, tm_smb_folder_callback receipt,
                        void *context, int *rename_sent);
#endif
