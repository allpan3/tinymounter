/* -*-  mode:c; tab-width:8; c-basic-offset:8; indent-tabs-mode:nil;  -*- */
/*
   Copyright (C) 2018 by Ronnie Sahlberg <ronniesahlberg@gmail.com>

   This program is free software; you can redistribute it and/or modify
   it under the terms of the GNU Lesser General Public License as published by
   the Free Software Foundation; either version 2.1 of the License, or
   (at your option) any later version.

   This program is distributed in the hope that it will be useful,
   but WITHOUT ANY WARRANTY; without even the implied warranty of
   MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
   GNU Lesser General Public License for more details.

   You should have received a copy of the GNU Lesser General Public License
   along with this program; if not, see <http://www.gnu.org/licenses/>.
*/
#include "config.h"
#include <GSS/GSS.h>
#include <errno.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "smb2.h"
#include "libsmb2.h"
#include "libsmb2-private.h"
#include "krb5-wrapper.h"

void krb5_set_gss_error(struct smb2_context *smb2, char *operation, uint32_t major, uint32_t minor)
{
    smb2_set_error(smb2, "%s major=%u minor=%u", operation, major, minor);
}

void krb5_free_auth_data(struct private_auth_data *auth)
{
    if (!auth) return;
    OM_uint32 minor;
    if (auth->context) gss_delete_sec_context(&minor, &auth->context, GSS_C_NO_BUFFER);
    if (auth->cred) gss_release_cred(&minor, &auth->cred);
    if (auth->user_name) gss_release_name(&minor, &auth->user_name);
    if (auth->target_name) gss_release_name(&minor, &auth->target_name);
    gss_release_buffer(&minor, &auth->output_token);
    free(auth->g_server);
    free(auth);
}

struct private_auth_data *krb5_negotiate_reply(struct smb2_context *smb2, const char *server,
                                              const char *domain, const char *user, const char *password)
{
    if (!server || !user || password || smb2->use_cached_creds) return NULL;
    struct private_auth_data *auth = calloc(1, sizeof(*auth));
    if (!auth) return NULL;
    if (asprintf(&auth->g_server, "cifs@%s", server) < 0) { free(auth); return NULL; }
    OM_uint32 minor, major;
    gss_buffer_desc target = { strlen(auth->g_server), auth->g_server };
    major = gss_import_name(&minor, &target, GSS_C_NT_HOSTBASED_SERVICE, &auth->target_name);
    if (major != GSS_S_COMPLETE) goto failed;
    gss_buffer_desc name = { strlen(user), (void *)user };
    major = gss_import_name(&minor, &name, GSS_C_NT_NTLM, &auth->user_name);
    if (major != GSS_S_COMPLETE) goto failed;
    gss_OID_set_desc mechanisms = { 1, (gss_OID)GSS_NTLM_MECHANISM };
    major = gss_acquire_cred(&minor, auth->user_name, 0, &mechanisms, GSS_C_INITIATE,
                             &auth->cred, NULL, NULL);
    if (major != GSS_S_COMPLETE) goto failed;
    auth->mech_type = GSS_NTLM_MECHANISM;
    return auth;
failed:
    krb5_set_gss_error(smb2, "credential acquisition", major, minor);
    krb5_free_auth_data(auth);
    return NULL;
}

int krb5_session_request(struct smb2_context *smb2, struct private_auth_data *auth,
                        unsigned char *bytes, int length)
{
    if (auth->complete) return 0;
    OM_uint32 minor, major;
    gss_release_buffer(&minor, &auth->output_token);
    gss_buffer_desc input = { length, bytes };
    major = gss_init_sec_context(&minor, auth->cred, &auth->context, auth->target_name,
                                 (gss_OID)auth->mech_type,
                                 GSS_C_SEQUENCE_FLAG | GSS_C_REPLAY_FLAG | GSS_C_MUTUAL_FLAG,
                                 GSS_C_INDEFINITE, GSS_C_NO_CHANNEL_BINDINGS,
                                 bytes ? &input : GSS_C_NO_BUFFER, NULL, &auth->output_token, NULL, NULL);
    if (GSS_ERROR(major)) {
        krb5_set_gss_error(smb2, "session authentication", major, minor);
        return -EACCES;
    }
    auth->complete = major == GSS_S_COMPLETE;
    return 0;
}

int krb5_session_get_session_key(struct smb2_context *smb2, struct private_auth_data *auth)
{
    OM_uint32 minor, major;
    gss_buffer_set_t keys = GSS_C_NO_BUFFER_SET;
    major = gss_inquire_sec_context_by_oid(&minor, auth->context, GSS_C_INQ_SSPI_SESSION_KEY, &keys);
    if (major != GSS_S_COMPLETE) {
        krb5_set_gss_error(smb2, "session key", major, minor);
        return -EACCES;
    }
    int result = -EACCES;
    if (keys && keys->count && keys->elements[0].length == SMB2_KEY_SIZE) {
        smb2->session_key = malloc(SMB2_KEY_SIZE);
        if (smb2->session_key) {
            memcpy(smb2->session_key, keys->elements[0].value, SMB2_KEY_SIZE);
            smb2->session_key_size = SMB2_KEY_SIZE;
            result = 0;
        } else result = -ENOMEM;
    }
    gss_release_buffer_set(&minor, &keys);
    return result;
}

int krb5_get_output_token_length(struct private_auth_data *auth) { return (int)auth->output_token.length; }
unsigned char *krb5_get_output_token_buffer(struct private_auth_data *auth) { return auth->output_token.value; }
