#include "MilkPTY.h"
#include <util.h>
#include <spawn.h>
#include <signal.h>
#include <termios.h>
#include <sys/ioctl.h>
#include <sys/wait.h>
#include <sys/proc.h>
#include <libproc.h>
#include <unistd.h>
#include <fcntl.h>
#include <errno.h>
#include <stdlib.h>
#include <stdio.h>
#include <string.h>

pid_t milk_pty_spawn(const char *host, const char *shell, const char *cwd,
                     char *const env[], unsigned short cols, unsigned short rows, int *master) {
    int slave;
    struct winsize size = {.ws_col = cols, .ws_row = rows};
    if (openpty(master, &slave, NULL, NULL, &size) < 0) return -1;
    fcntl(*master, F_SETFD, FD_CLOEXEC);
    fcntl(slave, F_SETFD, FD_CLOEXEC);
    posix_spawn_file_actions_t actions;
    posix_spawnattr_t attr;
    posix_spawn_file_actions_init(&actions);
    posix_spawnattr_init(&attr);
    for (int fd = 0; fd < 3; fd++) posix_spawn_file_actions_adddup2(&actions, slave, fd);
    // No inherited Milk/Pi/Preview sockets, files, pipes or credentials handles.
    posix_spawnattr_setflags(&attr, POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK);
    sigset_t defaults, mask;
    sigfillset(&defaults); sigemptyset(&mask);
    posix_spawnattr_setsigdefault(&attr, &defaults);
    posix_spawnattr_setsigmask(&attr, &mask);
    char *args[] = {(char *)host, "--milk-terminal-host", (char *)shell, (char *)cwd, NULL};
    pid_t pid = 0;
    int error = posix_spawn(&pid, host, &actions, &attr, args, env);
    posix_spawn_file_actions_destroy(&actions);
    posix_spawnattr_destroy(&attr);
    close(slave);
    if (error) { close(*master); *master = -1; errno = error; return -1; }
    return pid;
}

void milk_terminal_host(const char *shell, const char *cwd) {
    if (setsid() < 0 || ioctl(STDIN_FILENO, TIOCSCTTY, 0) < 0 || chdir(cwd) < 0) {
        perror("Milk Terminal"); _exit(126);
    }
    tcsetpgrp(STDIN_FILENO, getpgrp());
    const char *name = strrchr(shell, '/'); name = name ? name + 1 : shell;
    char *login = malloc(strlen(name) + 2);
    if (!login) _exit(126);
    login[0] = '-'; strcpy(login + 1, name);
    // Login argv[0] plus interactive mode works with zsh, bash and fish.
    char *args[] = {login, "-i", NULL};
    execv(shell, args);
    perror("Milk Terminal shell"); _exit(127);
}

int milk_pty_resize(int fd, unsigned short cols, unsigned short rows) {
    struct winsize size = {.ws_col = cols, .ws_row = rows};
    return ioctl(fd, TIOCSWINSZ, &size); // Kernel delivers SIGWINCH to foreground group.
}

static int live(pid_t pid) {
    struct proc_bsdinfo info;
    int n = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, sizeof(info));
    return n == sizeof(info) && info.pbi_status != SZOMB;
}

int milk_terminal_session_signal(pid_t leader, int sig) {
    if (leader <= 1 || leader == getpid()) return -1;
    int capacity = proc_listallpids(NULL, 0) + 128;
    pid_t *pids = calloc(capacity, sizeof(pid_t));
    if (!pids) return -1;
    int count = proc_listallpids(pids, capacity * (int)sizeof(pid_t));
    int remaining = 0;
    for (int i = 0; i < count && i < capacity; i++) {
        pid_t pid = pids[i];
        // Include the owned helper before setsid has completed. A zombie leader
        // reserves this PID/session ID, so neither can be reused during cleanup.
        if (pid > 1 && pid != getpid() && (pid == leader || getsid(pid) == leader) && live(pid)) {
            remaining++;
            if (sig && (pid == leader || getsid(pid) == leader)) kill(pid, sig);
        }
    }
    free(pids);
    return remaining;
}

int milk_terminal_wait_exit(pid_t pid) {
    siginfo_t info = {0};
    int result;
    do { result = waitid(P_PID, (id_t)pid, &info, WEXITED | WNOWAIT); } while (result < 0 && errno == EINTR);
    return result;
}
int milk_terminal_reap(pid_t pid, int *status) {
    int result;
    do { result = waitpid(pid, status, 0); } while (result < 0 && errno == EINTR);
    return result;
}


int milk_process_group_signal(pid_t leader, int sig) {
    if (leader <= 1 || leader == getpid()) return -1;
    int capacity = proc_listallpids(NULL, 0) + 128;
    pid_t *pids = calloc(capacity, sizeof(pid_t));
    if (!pids) return -1;
    int count = proc_listallpids(pids, capacity * (int)sizeof(pid_t));
    int remaining = 0;
    for (int i = 0; i < count && i < capacity; i++) {
        pid_t pid = pids[i];
        if (pid > 1 && pid != getpid() && getpgid(pid) == leader && live(pid)) {
            remaining++;
            if (sig && getpgid(pid) == leader) kill(pid, sig);
        }
    }
    free(pids);
    return remaining;
}
