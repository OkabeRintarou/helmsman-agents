/* One advisory lock per daemon home, held until the owning Erlang port closes.
 * Never unlink the lock file: contenders must always lock the same inode. */
#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <stdio.h>
#include <sys/stat.h>
#include <unistd.h>

int main(int argc, char **argv) {
    if (argc != 2) return 2;
    int fd = open(argv[1], O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0600);
    struct stat st;
    if (fd < 0 || fstat(fd, &st) < 0 || !S_ISREG(st.st_mode) ||
        fchmod(fd, 0600) < 0) return 3;

    struct flock lock = {.l_type = F_WRLCK, .l_whence = SEEK_SET};
    struct pollfd input = {.fd = STDIN_FILENO, .events = POLLIN};
    while (fcntl(fd, F_SETLK, &lock) < 0) {
        if (errno != EACCES && errno != EAGAIN && errno != EINTR) return 4;
        /* A waiting CLI can die too. EOF must release its helper immediately. */
        int ready = poll(&input, 1, 50);
        if (ready > 0) return 0;
        if (ready < 0 && errno != EINTR) return 5;
    }
    if (write(STDOUT_FILENO, "locked\n", 7) != 7) return 6;
    char byte;
    while (read(STDIN_FILENO, &byte, 1) < 0 && errno == EINTR) {}
    close(fd);
    return 0;
}
