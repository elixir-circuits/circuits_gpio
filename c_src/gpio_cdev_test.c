#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <string.h>
#include <fcntl.h>

#include <unistd.h>
#include <sys/ioctl.h>

#include <linux/gpio.h>

#define log_location stderr
//#define LOG_PATH "/tmp/circuits_gpio.log"
#define debug(...) do { fprintf(log_location, __VA_ARGS__); fprintf(log_location, "\r\n"); fflush(log_location); } while(0)
#define error(...) do { debug(__VA_ARGS__); } while (0)

typedef struct gpiochip_info gpiochip_info_t;

int gpio_get_chipinfo_ioctl(int fd, gpiochip_info_t* info) {
    return ioctl(fd, GPIO_GET_CHIPINFO_IOCTL, info);
}

int main(int argc, char* argv[]) {
    if(argc != 2) {
        error("usage: %s /dev/gpiochipN", argv[0]);
        exit(1);
    }
    
    char *path = argv[1];

    gpiochip_info_t info;
    memset(&info, 0, sizeof(gpiochip_info_t));

    debug("opening: %s", path);
    int fd = open(path, O_RDWR|O_CLOEXEC);
    if(fd < 0) {
        error("failed to open %s", path);
        exit(1);
    }
    int ret = gpio_get_chipinfo_ioctl(fd, &info);
    if(ret < 0) {
        error("ioctl failed: %d", ret);
        exit(1);
    }
    debug("name: %s", info.name);
    debug("label: %s", info.label);
    debug("lines: %d", info.lines);
    close(fd);
}