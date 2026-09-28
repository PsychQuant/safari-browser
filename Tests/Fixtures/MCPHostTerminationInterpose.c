/* Owned, non-GUI termination fixture. Never linked into the product. */
#include <stdlib.h>
#include <string.h>
#include <signal.h>
#include <unistd.h>
#include <fcntl.h>
#include <spawn.h>
#include <sys/syscall.h>
#include <crt_externs.h>
static int host_role = 0;
static int record_fd = -1;
static void worker_term(int signal_number) {
    (void)signal_number;
    if (record_fd >= 0) write(record_fd, "T", 1);

}
__attribute__((constructor)) static void setup(void) {
    int argc = *_NSGetArgc(); char **argv = *_NSGetArgv();
    if (argc < 2 || !getenv("OWNED_TERM_RECORD")) return;
    host_role = strcmp(argv[1], "mcp") == 0;
    const char *direct = getenv("SAFARI_BROWSER_MCP_DIRECT");

    int worker = (strcmp(argv[1], "__mcp-worker") == 0 || strcmp(argv[1], "__mcp-exec") == 0)
        && direct && strcmp(direct, "1") == 0;
    if (worker) {
        record_fd = open(getenv("OWNED_TERM_RECORD"), O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC, 0600);
        // Add one ordinary owned descendant. It shares the worker's group,
        // ignores TERM, inherits no private descriptors, and is harmless/time-bounded.
        signal(SIGTERM, SIG_IGN);
        posix_spawnattr_t attributes;
        pid_t descendant;
        char *arguments[] = { "/bin/sleep", "5", NULL };
        char *environment[] = { NULL };
        int error = posix_spawnattr_init(&attributes);
        if (!error) {
            error = posix_spawnattr_setflags(&attributes, POSIX_SPAWN_CLOEXEC_DEFAULT);
            if (!error) error = posix_spawn(&descendant, "/bin/sleep", NULL, &attributes, arguments, environment);
            posix_spawnattr_destroy(&attributes);
        }
        signal(SIGTERM, worker_term);
        if (record_fd >= 0) write(record_fd, error ? "E" : "R", 1);
    }
}
static int record_kill(pid_t target, int signal_number) {
    int result = (int)syscall(SYS_kill, target, signal_number);
    if (host_role && target < 0 && signal_number == SIGTERM && getenv("OWNED_STOP_AFTER_TERM")) {
        // Pause only this process, immediately after its real group TERM. The
        // Python owner may now kill its own Popen child before the next KILL.
        syscall(SYS_kill, getpid(), SIGSTOP);
    }
    return result;
}
// dyld's documented interposing section stores replacement/replacee pairs:
// https://github.com/apple-oss-distributions/dyld/blob/main/include/mach-o/dyld-interposing.h
struct KillSubstitution { int (*replacement)(pid_t, int); int (*original)(pid_t, int); };
__attribute__((used, section("__DATA,__interpose,interposing")))
static const struct KillSubstitution owned_kill_substitution = { record_kill, kill };
