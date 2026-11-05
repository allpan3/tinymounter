#ifndef TINYMOUNTER_SMB_EDIT_H
#define TINYMOUNTER_SMB_EDIT_H
#include <stdint.h>

void *tm_edit_connect(const char *server, const char *share, const char *account, int *error);
void tm_edit_disconnect(void *opaque);
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
int tm_edit_info(void *opaque, uint8_t *file, uint64_t *values);
int tm_edit_list(void *opaque, uint8_t *directory, int restart, uint8_t *buffer,
                 uint32_t capacity, uint32_t *count, int *finished);
int tm_edit_read(void *opaque, uint8_t *file, uint64_t offset, uint8_t *buffer, uint32_t length,
               uint32_t *count);
int tm_edit_write(void *opaque, uint8_t *file, uint64_t offset, const uint8_t *buffer, uint32_t length,
                  uint32_t *count);
int tm_edit_rename(void *opaque, uint8_t *file, const char *destination);
int tm_edit_delete(void *opaque, uint8_t *file);
int tm_edit_flush(void *opaque, uint8_t *file);
#endif
