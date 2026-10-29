#ifndef TINYMOUNTER_SMB_EDIT_H
#define TINYMOUNTER_SMB_EDIT_H
#include <stdint.h>

void *tm_edit_connect(const char *server, const char *share, const char *account, int *error);
void tm_edit_disconnect(void *opaque);
int tm_edit_open(void *opaque, const char *path, uint32_t access, uint32_t sharing,
               uint8_t *file);
int tm_edit_open_quarantine(void *opaque, const char *path, uint8_t *file);
int tm_edit_close(void *opaque, uint8_t *file);
int tm_edit_open_directory(void *opaque, const char *path, uint32_t access, uint32_t sharing,
                         uint8_t *file);
int tm_edit_open_private(void *opaque, const char *path, uint32_t access, uint32_t sharing,
                       const uint8_t *security, uint32_t length, uint8_t *file);
int tm_edit_resume_key(void *opaque, uint8_t *file, uint8_t *key);
int tm_edit_copy_chunk(void *opaque, uint8_t *target, const uint8_t *key, uint64_t source_offset,
                     uint64_t target_offset, uint32_t length, uint8_t *result);
int tm_edit_set_size(void *opaque, uint8_t *file, uint64_t size);
int tm_edit_info(void *opaque, uint8_t *file, uint64_t *values);
int tm_edit_list(void *opaque, uint8_t *directory, int restart, uint8_t *buffer,
                 uint32_t capacity, uint32_t *count, int *finished);
int tm_edit_read(void *opaque, uint8_t *file, uint64_t offset, uint8_t *buffer, uint32_t length,
               uint32_t *count);
int tm_edit_rename(void *opaque, uint8_t *file, const char *destination);
int tm_edit_delete(void *opaque, uint8_t *file);
int tm_edit_flush(void *opaque, uint8_t *file);
int tm_edit_metadata(void *opaque, uint8_t *file, int security, uint8_t *buffer,
                   uint32_t capacity, uint32_t *count);
int tm_edit_set_metadata(void *opaque, uint8_t *file, int security,
                       uint8_t *buffer, uint32_t length);
#endif
