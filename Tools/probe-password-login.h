// Spike probe for the 0.2.0 password login. Not part of the product build.
#ifndef PROBE_PASSWORD_LOGIN_H
#define PROBE_PASSWORD_LOGIN_H
#include <stddef.h>
#include <stdint.h>

struct probe_login_result {
    int connect_result;   // smb2_connect_share's return value
    int error;            // errno derived from it, 0 on success
    uint32_t status;      // last NTSTATUS libsmb2 decoded
    uint16_t dialect;
    int sealed, signed_requests, entries, listing_error;
    char message[160];    // libsmb2's error text, redacted if it names the server
};

// The password is `length` bytes, not NUL-terminated. The probe zeroes its own copy.
int probe_login(const char *server, const char *share, const char *user, const char *domain,
                const uint8_t *password, size_t length, struct probe_login_result *result);

#endif
