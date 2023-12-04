#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <string.h>
#include <fcntl.h>

#include <unistd.h>
#include <sys/ioctl.h>

#include "linux/gpio.h"

#define log_location stderr
//#define LOG_PATH "/tmp/circuits_gpio.log"
#define debug(...) do { fprintf(log_location, __VA_ARGS__); fprintf(log_location, "\r\n"); fflush(log_location); } while(0)
#define error(...) do { debug(__VA_ARGS__); } while (0)

int main(int argc, char* argv[])
{
    char path[32];
    struct gpiochip_info info;
    int i;

    for (i = 0; i < 16; i++) {
        sprintf(path, "/dev/gpiochip%d", i);

        int fd = open(path, O_RDONLY|O_CLOEXEC);
        if (fd < 0)
            break;

        memset(&info, 0, sizeof(struct gpiochip_info));
        if (ioctl(fd, GPIO_GET_CHIPINFO_IOCTL, &info) < 0)
            break;

        unsigned int j;
        for (j = 0; j < info.lines; j++) {
            struct gpio_v2_line_info line;
            memset(&line, 0, sizeof(struct gpio_v2_line_info));
            line.offset = j;
            if (ioctl(fd, GPIO_V2_GET_LINEINFO_IOCTL, &line) >= 0) {
                debug("  {:cdev, \"%s\", %d} -> {\"%s\", \"%s\"}", info.name, j, info.label, line.name);
            }
        }

        close(fd);
    }

    debug("done.");
}
