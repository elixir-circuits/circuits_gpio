#include "gpio_nif.h"

#include <stdint.h>
#include <sys/mman.h>
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

// Copied from host_bcm.c source, bcm_host_get_peripheral_address()
// was undefined when loading the GPIO NIF
static unsigned get_dt_ranges(const char *filename, unsigned offset)
{
    unsigned address = ~0;

    FILE *fp = fopen(filename, "rb");
    if (fp)
    {
        unsigned char buf[4];
        fseek(fp, offset, SEEK_SET);
        if (fread(buf, 1, sizeof buf, fp) == sizeof buf)
            address = buf[0] << 24 | buf[1] << 16 | buf[2] << 8 | buf[3] << 0;
        fclose(fp);
    }
    return address;
}

// Copied from host_bcm.c source.
unsigned bcm_host_get_peripheral_address(void)
{
    unsigned address = get_dt_ranges("/proc/device-tree/soc/ranges", 4);
    return address == ~0 ? 0x20000000 : address;
}

// Need gpio access to set pull up/down resistors
int get_gpio_map(uint32_t **gpio_map)
{
    int mem_fd;
    void *map;

    debug("get_gpio_map()");
    // Prefer using "/dev/gpiomem" to "/dev/mem"
    if ((mem_fd = open("/dev/gpiomem", O_RDWR|O_SYNC)) > 0)
    {
        debug("get_gpio_map() open() /dev/gpiomem, success");
        map = mmap(NULL, GPIO_MAP_BLOCK_SIZE, PROT_READ|PROT_WRITE, MAP_SHARED, mem_fd, 0);
        if (*((int32_t*)map) < 0) {
            error("get_gpio_map() mmap(), failed");
            return -1;
        } else {
            *gpio_map = (uint32_t *) map;
            debug("get_gpio_map() mmap(), success");
            return 0;
        }
    }
    error("get_gpio_map() open() /dev/gpiomem, failed");

    uint32_t peri_addr =  bcm_host_get_peripheral_address();
    uint32_t gpio_base = peri_addr + GPIO_BASE_OFFSET;
    debug("get_gpio_map() 2 peri_addr %d", gpio_base);

    // mmap the GPIO memory registers
    if ((mem_fd = open("/dev/mem", O_RDWR|O_SYNC) ) < 0) {
        error("get_gpio_map() 2 open(), failed");
        return -1;
    }
    uint8_t *gpio_mem;
    if ((gpio_mem = malloc(GPIO_MAP_BLOCK_SIZE + (PAGE_SIZE-1))) == NULL) {
        error("get_gpio_map() 2 malloc(), failed");
        return -1;
    }

    if ((uint32_t)gpio_mem % PAGE_SIZE)
        gpio_mem += PAGE_SIZE - ((uint32_t)gpio_mem % PAGE_SIZE);

    *gpio_map = (uint32_t *)mmap( (void *)gpio_mem, GPIO_MAP_BLOCK_SIZE, PROT_READ|PROT_WRITE, MAP_SHARED|MAP_FIXED, mem_fd, gpio_base);

    if (*((int32_t*)gpio_map) < 0) {
        error("get_gpio_map() 2 mmap(), failed");
        return -1;
    }

    debug("get_gpio_map() 2 mmap(), success");
    return 0;
}
