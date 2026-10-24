#ifndef TINYMOUNTER_SMB_RENAME_H
#define TINYMOUNTER_SMB_RENAME_H
#include <stdint.h>

typedef int (*tm_smb_folder_callback)(void *context, uint64_t file_id, uint64_t birth_us);

int tm_smb_create_folder(const char *server, const char *share, const char *account,
                         const char *path, uint64_t expected_id, uint64_t expected_birth,
                         tm_smb_folder_callback receipt, void *context, int *create_sent);

int tm_smb_name_folder(const char *server, const char *share, const char *account,
                       const char *source, const char *destination, uint64_t expected_id,
                       uint64_t expected_birth, int recovery_only,
                       tm_smb_folder_callback receipt, void *context, int *rename_sent);

#endif
