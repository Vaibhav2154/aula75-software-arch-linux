#define _GNU_SOURCE
#include <dlfcn.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <fcntl.h>
#include <unistd.h>
#include <sys/ioctl.h>
#include <errno.h>

static int (*real_ioctl)(int, unsigned long, void *) = NULL;

static void logbuf(const char *tag, int fd, int ret, int err, const unsigned char *buf, int size)
{
    char line[4096];
    int n = 0, i, dump = size < 96 ? size : 96;
    const char *logpath = getenv("HIDSNOOP_LOG");
    if (!logpath) return;
    n += snprintf(line + n, sizeof(line) - n, "%s fd=%d size=%d ret=%d errno=%d data=", tag, fd, size, ret, err);
    for (i = 0; i < dump && n < (int)sizeof(line) - 4; i++)
        n += snprintf(line + n, sizeof(line) - n, "%02x", buf[i]);
    n += snprintf(line + n, sizeof(line) - n, "\n");
    int lf = open(logpath, O_WRONLY | O_CREAT | O_APPEND, 0644);
    if (lf >= 0) { write(lf, line, n); close(lf); }
}

int ioctl(int fd, unsigned long req, ...)
{
    va_list ap;
    void *arg;
    int ret;

    va_start(ap, req);
    arg = va_arg(ap, void *);
    va_end(ap);

    if (!real_ioctl) real_ioctl = dlsym(RTLD_NEXT, "ioctl");

    if (_IOC_TYPE(req) == 'H' && (_IOC_NR(req) == 0x06 || _IOC_NR(req) == 0x07)) {
        int size = _IOC_SIZE(req);
        if (_IOC_NR(req) == 0x06) { /* HIDIOCSFEATURE */
            logbuf("SFEATURE(req)", fd, 0, 0, arg, size);
            ret = real_ioctl(fd, req, arg);
            logbuf("SFEATURE(ret)", fd, ret, ret < 0 ? errno : 0, arg, 1);
        } else { /* HIDIOCGFEATURE */
            logbuf("GFEATURE(req)", fd, 0, 0, arg, 1);
            ret = real_ioctl(fd, req, arg);
            logbuf("GFEATURE(ret)", fd, ret, ret < 0 ? errno : 0, arg, size);
            /* Windows reports the full report length even when the device
             * answers with a short transfer; some vendor apps validate the
             * returned length, so zero-pad and claim the full size. */
            if (ret > 0 && ret < size) {
                memset((unsigned char *)arg + ret, 0, size - ret);
                ret = size;
            }
        }
        return ret;
    }
    return real_ioctl(fd, req, arg);
}
