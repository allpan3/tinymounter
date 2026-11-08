// Spike probe for the 0.2.0 password login: libsmb2 NTLMSSP with an explicit password.
// See docs/results/2026-11-08-password-login.md. Not part of the product build.
#define __STDC_WANT_LIB_EXT1__ 1
#include "probe-password-login.h"
#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <smb2/smb2.h>
#include <smb2/libsmb2.h>
#include "libsmb2-private.h"

static void wipe(void *buffer, size_t length)
{
    if (buffer && length) memset_s(buffer, length, 0, length);
}

static void record(struct smb2_context *smb, const char *server, struct probe_login_result *result)
{
    const char *message = smb2_get_error(smb);
    if (!message) message = "";
    snprintf(result->message, sizeof(result->message), "%s",
             strstr(message, server) ? "<names the server>" : message);
    result->status = (uint32_t)smb2_get_nterror(smb);
}

int probe_login(const char *server, const char *share, const char *user, const char *domain,
                const uint8_t *password, size_t length, struct probe_login_result *result)
{
    memset(result, 0, sizeof(*result));
    char *secret = calloc(1, length + 1);
    struct smb2_context *smb = secret ? smb2_init_context() : NULL;
    if (!smb) { free(secret); return result->error = ENOMEM; }
    memcpy(secret, password, length);
    smb2_set_timeout(smb, 10);
    smb2_set_authentication(smb, SMB2_SEC_NTLMSSP);
    smb2_set_user(smb, user);
    if (domain && *domain) smb2_set_domain(smb, domain);
    smb2_set_password(smb, secret);
    wipe(secret, length);
    free(secret);
    smb2_set_sign(smb, 1);
    smb2_set_seal(smb, 1);
    smb2_set_security_mode(smb, SMB2_NEGOTIATE_SIGNING_ENABLED | SMB2_NEGOTIATE_SIGNING_REQUIRED);
    result->connect_result = smb2_connect_share(smb, server, share, NULL);
    // Same mapping as connect_folder_share: -1 means no connection was made.
    result->error = result->connect_result == 0 ? 0 : result->connect_result == -1 ? ENOTCONN
        : result->connect_result < 0 ? -result->connect_result : EIO;
    record(smb, server, result);
    if (smb->password) {
        wipe(discard_const(smb->password), strlen(smb->password));
        smb2_set_password(smb, NULL);
    }
    if (!result->connect_result) {
        result->dialect = smb2_get_dialect(smb);
        result->sealed = smb->seal;
        result->signed_requests = smb->sign;
        struct smb2dir *dir = smb2_opendir(smb, "");
        if (dir) {
            while (smb2_readdir(smb, dir)) result->entries++;
            smb2_closedir(smb, dir);
        } else {
            result->listing_error = errno ? errno : EIO;
            record(smb, server, result);
        }
        smb2_disconnect_share(smb);
    }
    smb2_destroy_context(smb);
    return result->error;
}

#ifdef PROBE_LOGIN_MAIN
#ifdef PROBE_CURRENT_PATH
void *tm_smb_begin_edit(const char *server, const char *share, const char *account, int *error);
void tm_smb_end_edit(void *smb);
#endif

static void print(const struct probe_login_result *r)
{
    printf("connect_result=%d error=%d(%s) status=0x%08x(%s) dialect=0x%04x sealed=%d signed=%d "
           "entries=%d listing_error=%d message=\"%s\"\n", r->connect_result, r->error,
           r->error ? strerror(r->error) : "ok", r->status, nterror_to_str(r->status), r->dialect,
           r->sealed, r->signed_requests, r->entries, r->listing_error, r->message);
}

int main(int argc, char **argv)
{
#ifdef PROBE_CURRENT_PATH
    if (argc == 5 && !strcmp(argv[1], "--current")) {
        int error = 0;
        void *smb = tm_smb_begin_edit(argv[2], argv[3], argv[4], &error);
        // connect_folder_share leaves *error set on success; the context is the result.
        if (smb) error = 0;
        printf("current_path connected=%d error=%d(%s) dialect=0x%04x sealed=%d\n", smb != NULL, error,
               error ? strerror(error) : "ok", smb ? smb2_get_dialect(smb) : 0,
               smb ? ((struct smb2_context *)smb)->seal : 0);
        tm_smb_end_edit(smb);
        return error ? 1 : 0;
    }
#endif
    if (argc < 4 || argc > 5) {
        fputs("usage: probe-password-login <server> <share> <user> [domain] < password\n", stderr);
        return 64;
    }
    char buffer[512];
    size_t length = fread(buffer, 1, sizeof(buffer) - 1, stdin);
    while (length && (buffer[length - 1] == '\n' || buffer[length - 1] == '\r')) length--;
    struct probe_login_result result;
    int error = probe_login(argv[1], argv[2], argv[3], argc == 5 ? argv[4] : NULL,
                            (const uint8_t *)buffer, length, &result);
    wipe(buffer, sizeof(buffer));
    print(&result);
    return error ? 1 : 0;
}
#endif
