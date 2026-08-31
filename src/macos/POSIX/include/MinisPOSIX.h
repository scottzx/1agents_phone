#ifndef MINIS_POSIX_H
#define MINIS_POSIX_H

#include <stdint.h>
#include <sys/types.h>

/// Start a login shell attached to a fresh host PTY. Returns the child pid or
/// -1 and leaves errno set. The child is its own process-group/session leader.
pid_t minis_spawn_pty(const char *shell_path, const char *working_directory, int *master_fd);

int minis_resize_pty(int master_fd, uint16_t columns, uint16_t rows);
int32_t minis_wait_exit_code(pid_t pid);
int minis_acquire_instance_lock(const char *path);
void minis_release_instance_lock(int descriptor);

pid_t minis_spawn_command(
    const char *shell_path,
    const char *working_directory,
    char *const environment[],
    int stdin_fd,
    int stdout_fd,
    int stderr_fd
);

#endif
