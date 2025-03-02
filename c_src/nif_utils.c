// SPDX-FileCopyrightText: 2018 Frank Hunleth
// SPDX-FileCopyrightText: 2024 Connor Rigby
//
// SPDX-License-Identifier: Apache-2.0

#include "gpio_nif.h"

#include <errno.h>
#include <string.h>

ERL_NIF_TERM make_ok_tuple(ErlNifEnv *env, ERL_NIF_TERM value)
{
    return enif_make_tuple2(env, atom_ok, value);
}

ERL_NIF_TERM make_errno_error(ErlNifEnv *env, int errno_value)
{
    // Handle return codes from functions that return -errno
    if (errno_value < 0)
        errno_value = -errno_value;

    ERL_NIF_TERM reason;
    switch (errno_value) {
    case ENOENT:
        reason = enif_make_atom(env, "not_found");
        break;

    case EBUSY:
        reason = enif_make_atom(env, "already_open");
        break;

    case EOPNOTSUPP:
        reason = enif_make_atom(env, "not_supported");
        break;

    default:
        // These errors aren't that helpful, so if they happen, please report
        // or update this code to provide a better reason.
        reason = enif_make_tuple2(env, enif_make_atom(env, "errno"), enif_make_int(env, errno_value));
        break;
    }

    return enif_make_tuple2(env, atom_error, reason);
}

ERL_NIF_TERM make_string_binary(ErlNifEnv *env, const char *str)
{
    ERL_NIF_TERM term;
    size_t len = strlen(str);
    unsigned char *data = enif_make_new_binary(env, len, &term);
    memcpy(data, str, len);
    return term;
}

int enif_get_boolean(ErlNifEnv *env, ERL_NIF_TERM term, bool *v)
{
    char buffer[16];
    if (enif_get_atom(env, term, buffer, sizeof(buffer), ERL_NIF_LATIN1) <= 0)
        return false;

    if (strcmp("false", buffer) == 0)
        *v = false;
    else
        *v = true;

    return true;
}
