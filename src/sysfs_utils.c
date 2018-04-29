#include "gpio_nif.h"

#include <fcntl.h>
#include <string.h>
#include <unistd.h>

int sysfs_write_file(const char *pathname, const char *value)
{
    int fd = open(pathname, O_WRONLY);
    if (fd < 0) {
        error("Error opening %s", pathname);
        return -1;
    }

    size_t count = strlen(value);
    ssize_t written = write(fd, value, count);
    close(fd);

    if (written < 0 || (size_t) written != count) {
        error("Error writing '%s' to %s", value, pathname);
        return -1;
    }
    return written;
}
