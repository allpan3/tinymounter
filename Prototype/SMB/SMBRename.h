#ifndef TINYMOUNTER_SMB_RENAME_H
#define TINYMOUNTER_SMB_RENAME_H
#include <stdint.h>
#include "SMBEdit.h"
#include "SMBNotify.h"

enum tm_smb_folder_stage {
    TM_FOLDER_ARGUMENTS = 1, TM_FOLDER_PARENT, TM_FOLDER_TARGET, TM_FOLDER_QUERY,
    TM_FOLDER_IDENTITY, TM_FOLDER_RECEIPT, TM_FOLDER_DONE
};

// Name-free diagnostics for one tm_edit_create_folder call.
struct tm_smb_folder_trace {
    int stage;            // the failed stage, or TM_FOLDER_DONE
    int parents;          // successful parent opens, counting the share root
    uint32_t status;      // raw NTSTATUS of the stage's last reply; 0 if none arrived
    int error;
    int sent_queued;      // create_sent before the CREATE reply was classified
    int sent;
};

const char *tm_smb_folder_stage_name(int stage);

// Called once per share the server lists; a nonzero result stops the listing with that error.
typedef int (*tm_smb_share_callback)(void *context, const char *name, uint32_t type);

// Signs in to IPC$ and lists the server's shares (srvsvc NetrShareEnum, level 1), unfiltered.
int tm_smb_share_names(const struct tm_smb_login *login, tm_smb_share_callback each, void *context,
                       uint32_t *status);

#endif
