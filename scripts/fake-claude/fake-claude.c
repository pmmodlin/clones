// Claude.app stub for clones end-to-end tests (CI, Linux, macOS without touching real data).
// Mimics what matters to clones: Electron takes userData from --user-data-dir, reads
// claude_desktop_config.json from it at startup, keeps a log open and exits cleanly on SIGTERM.
//
// Without --user-data-dir it writes NOT to ~/Library/Application Support/Claude but to
// <sandbox>/home/Library/Application Support/Claude (the nearest parent with home/): LaunchServices does not pass the
// caller's HOME to the app, and the real Claude data must never be touched.
#include <libgen.h>
#include <limits.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

static volatile sig_atomic_t quit_requested = 0;
static void on_term(int sig) { (void)sig; quit_requested = 1; }

static void mkdirs(const char *path) {
    char tmp[PATH_MAX];
    snprintf(tmp, sizeof tmp, "%s", path);
    for (char *p = tmp + 1; *p; p++) {
        if (*p == '/') { *p = 0; mkdir(tmp, 0700); *p = '/'; }
    }
    mkdir(tmp, 0700);
}

static void write_file(const char *dir, const char *name, const char *content) {
    char path[PATH_MAX];
    snprintf(path, sizeof path, "%s/%s", dir, name);
    FILE *f = fopen(path, "w");
    if (f) { fputs(content, f); fclose(f); }
}

int main(int argc, char **argv) {
    char dir[PATH_MAX] = {0};
    for (int i = 1; i < argc; i++) {
        if (strncmp(argv[i], "--user-data-dir=", 16) == 0) snprintf(dir, sizeof dir, "%s", argv[i] + 16);
    }
    if (!dir[0]) {
        // Walk up from the executable to the sandbox folder that has home/ (works for the stub
        // itself and for profile copies under data/bundles.noindex/...).
        char path[PATH_MAX], probe[PATH_MAX];
        struct stat st;
        if (!realpath(argv[0], path)) snprintf(path, sizeof path, "%s", argv[0]);
        char *cur = dirname(path);
        while (strcmp(cur, "/") != 0) {
            snprintf(probe, sizeof probe, "%s/home", cur);
            if (stat(probe, &st) == 0 && S_ISDIR(st.st_mode)) break;
            cur = dirname(cur);
        }
        snprintf(dir, sizeof dir, "%s/home/Library/Application Support/Claude", cur);
    }
    mkdirs(dir);
    write_file(dir, "Local State", "{\"fake\":true}\n");

    char config[PATH_MAX], loaded[PATH_MAX];
    snprintf(config, sizeof config, "%s/claude_desktop_config.json", dir);
    snprintf(loaded, sizeof loaded, "%s/loaded-config.json", dir);
    FILE *in = fopen(config, "r"), *out = fopen(loaded, "w");
    if (out) {
        if (in) { int c; while ((c = fgetc(in)) != EOF) fputc(c, out); } else fputs("{}\n", out);
        fclose(out);
    }
    if (in) fclose(in);

    // Record the Claude Code folder the profile passed in (clones sets CLAUDE_CONFIG_DIR per profile).
    const char *code_dir = getenv("CLAUDE_CONFIG_DIR");
    write_file(dir, "claude-config-dir.txt", code_dir ? code_dir : "");

    char logpath[PATH_MAX];
    snprintf(logpath, sizeof logpath, "%s/main.log", dir);
    FILE *log = fopen(logpath, "a");
    if (log) { fprintf(log, "started pid=%d userData=%s\n", (int)getpid(), dir); fflush(log); }

    signal(SIGTERM, on_term);
    while (!quit_requested) pause();
    if (log) { fprintf(log, "quit pid=%d\n", (int)getpid()); fclose(log); }
    return 0;
}
