#ifndef TINYMOUNTER_SMB_RENAME_H
#define TINYMOUNTER_SMB_RENAME_H
#include <stdint.h>

int tm_smb_name_folder(const char *server, const char *share, const char *account,
                       const char *source, const char *destination, uint64_t expected_id, int recovery_only);

#endif
