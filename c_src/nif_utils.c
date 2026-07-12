// SPDX-FileCopyrightText: 2018 Frank Hunleth
// SPDX-FileCopyrightText: 2024 Connor Rigby
//
// SPDX-License-Identifier: Apache-2.0

#include "gpio_nif.h"

#include <erl_driver.h> // erl_errno_id
#include <errno.h>
#include <string.h>

ERL_NIF_TERM make_ok_tuple(ErlNifEnv *env, ERL_NIF_TERM value)
{
    return enif_make_tuple2(env, atom_ok, value);
}

ERL_NIF_TERM make_errno_atom(ErlNifEnv *env, int errno_value)
{
    // Handle return codes from functions that return -errno
    if (errno_value < 0)
        errno_value = -errno_value;

    switch (errno_value) {
    // For historical reasons, these errno values are translated to custom atoms
    case ENOENT: return enif_make_atom(env, "not_found");
    case EBUSY: return enif_make_atom(env, "already_open");
    case EOPNOTSUPP: return enif_make_atom(env, "not_supported");

    // Fallback to the plain errno name
    default: return enif_make_atom(env, erl_errno_id(errno_value));
    }
}

ERL_NIF_TERM make_errno_error(ErlNifEnv *env, int errno_value)
{
    return enif_make_tuple2(env, atom_error, make_errno_atom(env, errno_value));
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
