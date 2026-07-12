#ifndef CPTY_H
#define CPTY_H

#include <util.h>
#include <sys/ioctl.h>

static inline int cpty_set_winsize(int fd, unsigned short rows, unsigned short cols) {
    struct winsize ws;
    ws.ws_row = rows;
    ws.ws_col = cols;
    ws.ws_xpixel = 0;
    ws.ws_ypixel = 0;
    return ioctl(fd, TIOCSWINSZ, &ws);
}

#endif
