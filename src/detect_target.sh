#!/bin/sh

#
# Detect the platform and output -D flags for use in compilion
#

if [ -z $CC ]; then
  CC=cc
fi

#
# Raspberry Pi check
#

# Is the bcmhost.h header file available?

$CC $CFLAGS -o /dev/null -xc - 2>/dev/null <<EOF
#include <bcm_host.h>

int main(int argc,char *argv[]) {
    return 0;
}
EOF
if [ "$?" = "0" ]; then
    printf -- "-DTARGET_RPI -lbcm_host"
fi

