#pragma once
#include <sys/types.h>
#include <stdint.h>

// Returns an owned child PID, or -1 with errno. Only the slave is inherited.
pid_t milk_pty_spawn(const char *host, const char *shell, const char *cwd,
                     char *const env[], unsigned short cols, unsigned short rows, int *master);
// Called only in the freshly spawned helper, before initializing AppKit.
void milk_terminal_host(const char *shell, const char *cwd);
int milk_pty_resize(int fd, unsigned short cols, unsigned short rows);
// The caller must keep the session leader unreaped until cleanup completes.
int milk_terminal_session_signal(pid_t leader, int signal_number);
int milk_terminal_wait_exit(pid_t pid);
int milk_terminal_reap(pid_t pid, int *status);

// Exact owned process group; keep its leader unreaped until cleanup completes. Counts live members only.
int milk_process_group_signal(pid_t leader, int signal_number);
