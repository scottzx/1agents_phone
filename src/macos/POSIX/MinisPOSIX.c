#include "MinisPOSIX.h"

#include <errno.h>
#include <stdlib.h>
#include <spawn.h>
#include <fcntl.h>
#include <sys/file.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/wait.h>
#include <termios.h>
#include <unistd.h>
#include <util.h>

extern char **environ;

pid_t minis_spawn_pty(const char *shell_path, const char *working_directory, int *master_fd) {
    if (shell_path == NULL || master_fd == NULL) {
        errno = EINVAL;
        return -1;
    }

    size_t environment_count = 0;
    while (environ[environment_count] != NULL) environment_count++;
    char **terminal_environment = calloc(environment_count + 2, sizeof(char *));
    if (terminal_environment == NULL) return -1;
    size_t terminal_index = 0;
    for (size_t index = 0; index < environment_count; index++) {
        if (strncmp(environ[index], "TERM=", 5) != 0) terminal_environment[terminal_index++] = environ[index];
    }
    terminal_environment[terminal_index++] = "TERM=xterm-256color";
    terminal_environment[terminal_index] = NULL;

    struct winsize size = { .ws_row = 30, .ws_col = 100, .ws_xpixel = 0, .ws_ypixel = 0 };
    pid_t pid = forkpty(master_fd, NULL, NULL, &size);
    if (pid != 0) {
        free(terminal_environment);
        return pid;
    }

    // Child: forkpty has already created a session, controlling terminal and
    // stdio wiring. Only async-signal-safe operations occur before exec.
    if (working_directory != NULL && chdir(working_directory) != 0) {
        _exit(126);
    }
    char *const arguments[] = { (char *)shell_path, "-l", NULL };
    execve(shell_path, arguments, terminal_environment);
    _exit(127);
}

int minis_resize_pty(int master_fd, uint16_t columns, uint16_t rows) {
    struct winsize size = {
        .ws_row = rows,
        .ws_col = columns,
        .ws_xpixel = 0,
        .ws_ypixel = 0,
    };
    return ioctl(master_fd, TIOCSWINSZ, &size);
}

int32_t minis_wait_exit_code(pid_t pid) {
    int status = 0;
    while (waitpid(pid, &status, 0) < 0) {
        if (errno != EINTR) return -1;
    }
    if (WIFEXITED(status)) return WEXITSTATUS(status);
    if (WIFSIGNALED(status)) return 128 + WTERMSIG(status);
    return status;
}

int minis_acquire_instance_lock(const char *path) {
    if (path == NULL) { errno = EINVAL; return -1; }
    int descriptor = open(path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR);
    if (descriptor < 0) return -1;
    if (flock(descriptor, LOCK_EX | LOCK_NB) != 0) {
        int saved = errno;
        close(descriptor);
        errno = saved;
        return -1;
    }
    return descriptor;
}

void minis_release_instance_lock(int descriptor) {
    if (descriptor < 0) return;
    flock(descriptor, LOCK_UN);
    close(descriptor);
}

pid_t minis_spawn_command(
    const char *shell_path,
    const char *working_directory,
    char *const environment[],
    int stdin_fd,
    int stdout_fd,
    int stderr_fd
) {
    if (shell_path == NULL || working_directory == NULL) {
        errno = EINVAL;
        return -1;
    }
    posix_spawn_file_actions_t actions;
    posix_spawnattr_t attributes;
    if (posix_spawn_file_actions_init(&actions) != 0) return -1;
    if (posix_spawnattr_init(&attributes) != 0) {
        posix_spawn_file_actions_destroy(&actions);
        return -1;
    }
    int setup_status = 0;
#define MINIS_SPAWN_CHECK(operation) do { setup_status = (operation); if (setup_status != 0) goto setup_failed; } while (0)
    MINIS_SPAWN_CHECK(posix_spawn_file_actions_adddup2(&actions, stdin_fd, STDIN_FILENO));
    MINIS_SPAWN_CHECK(posix_spawn_file_actions_adddup2(&actions, stdout_fd, STDOUT_FILENO));
    MINIS_SPAWN_CHECK(posix_spawn_file_actions_adddup2(&actions, stderr_fd, STDERR_FILENO));
    MINIS_SPAWN_CHECK(posix_spawn_file_actions_addclose(&actions, stdin_fd));
    MINIS_SPAWN_CHECK(posix_spawn_file_actions_addclose(&actions, stdout_fd));
    MINIS_SPAWN_CHECK(posix_spawn_file_actions_addclose(&actions, stderr_fd));
    MINIS_SPAWN_CHECK(posix_spawn_file_actions_addchdir_np(&actions, working_directory));
    MINIS_SPAWN_CHECK(posix_spawnattr_setflags(&attributes, POSIX_SPAWN_SETPGROUP));
    MINIS_SPAWN_CHECK(posix_spawnattr_setpgroup(&attributes, 0));
#undef MINIS_SPAWN_CHECK

    char *const argv[] = { (char *)shell_path, "-l", "-s", NULL };
    pid_t pid = -1;
    int status = posix_spawn(&pid, shell_path, &actions, &attributes, argv, environment);
    posix_spawn_file_actions_destroy(&actions);
    posix_spawnattr_destroy(&attributes);
    if (status != 0) {
        errno = status;
        return -1;
    }
    return pid;

setup_failed:
    posix_spawn_file_actions_destroy(&actions);
    posix_spawnattr_destroy(&attributes);
    errno = setup_status;
    return -1;
}
