#ifndef TINYMOUNTER_SMB_RENAME_H
#define TINYMOUNTER_SMB_RENAME_H
#include <stdint.h>
#include "SMBEdit.h"

typedef int (*tm_smb_folder_callback)(void *context, uint64_t file_id, uint64_t birth_us);

enum tm_smb_folder_stage {
    TM_FOLDER_ARGUMENTS = 1, TM_FOLDER_CONNECT, TM_FOLDER_PARENT, TM_FOLDER_TARGET, TM_FOLDER_QUERY,
    TM_FOLDER_IDENTITY, TM_FOLDER_RECEIPT, TM_FOLDER_DONE
};

// Name-free diagnostics for one tm_smb_create_folder call.
struct tm_smb_folder_trace {
    int stage;            // the failed stage, or TM_FOLDER_DONE
    int parents;          // successful parent opens, counting the share root
    uint32_t status;      // raw NTSTATUS of the stage's last reply; 0 if none arrived
    int error;
    int sent_queued;      // create_sent before the CREATE reply was classified
    int sent;
};

const char *tm_smb_folder_stage_name(int stage);

int tm_smb_create_folder(const char *server, const char *share, const char *account,
                         const char *path, uint64_t expected_id, uint64_t expected_birth,
                         tm_smb_folder_callback receipt, void *context, int *create_sent,
                         struct tm_smb_folder_trace *trace);

int tm_smb_name_folder(const char *server, const char *share, const char *account,
                       const char *source, const char *destination, uint64_t expected_id,
                       uint64_t expected_birth, int recovery_only,
                       tm_smb_folder_callback receipt, void *context, int *rename_sent);

#endif
