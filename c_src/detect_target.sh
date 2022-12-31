#!/bin/sh

# SPDX-FileCopyrightText: 2018 Frank Hunleth, Mark Sebald, Matt Ludwigs
#
# SPDX-License-Identifier: Apache-2.0

#
# Detect the platform and output -D flags for use in compilation
#

if [ -z "$CC" ]; then
  CC=cc
fi

#
# Raspberry Pi check
#

# Is the bcmhost.h header file available?
if [ -e /opt/vc/include/bcm_host.h ]; then
    EXTRA_CFLAGS=-I/opt/vc/include
fi

$CC $CFLAGS $EXTRA_CFLAGS -o /dev/null -xc - 2>/dev/null <<EOF
#include <bcm_host.h>

int main(int argc,char *argv[]) {
    return 0;
}
EOF
if [ "$?" = "0" ]; then
    printf -- "-DTARGET_RPI $EXTRA_CFLAGS -lbcm_host"
fi

