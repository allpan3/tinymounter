// Bridging header for Tools/check-smb-watch.swift: the app's notify connection and the actor.
#include <stddef.h>
#include <stdint.h>
#include "../Prototype/SMB/SMBNotify.h"

int actor_connect(const char *server, const char *share, const char *account, const uint8_t *password,
                  size_t length);
void actor_disconnect(void);
const char *actor_error(void);
uint32_t actor_ntstatus(void);
int actor_mkdir(const char *path);
int actor_rmdir(const char *path);
int actor_unlink(const char *path);
int actor_rename(const char *from, const char *to);
int actor_write(const char *path, uint32_t size, int create, uint8_t fill);
uint32_t actor_set_attributes(const char *path, uint32_t attributes);
int actor_list(const char *path, void (*found)(void *context, const char *name), void *context);
int actor_is_directory(const char *path);
