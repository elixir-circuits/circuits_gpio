// SPDX-FileCopyrightText: 2018 Frank Hunleth, Mark Sebald, Matt Ludwigs
//
// SPDX-License-Identifier: Apache-2.0

#include "gpio_nif.h"

#include <string.h>

ERL_NIF_TERM make_ok_tuple(ErlNifEnv *env, ERL_NIF_TERM value)
{
    struct gpio_priv *priv = enif_priv_data(env);

    return enif_make_tuple2(env, priv->atom_ok, value);
}

ERL_NIF_TERM make_error_tuple(ErlNifEnv *env, const char *reason)
{
    ERL_NIF_TERM error_atom = enif_make_atom(env, "error");
    ERL_NIF_TERM reason_atom = enif_make_atom(env, reason);

    return enif_make_tuple2(env, error_atom, reason_atom);
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
