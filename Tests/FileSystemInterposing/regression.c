#include <assert.h>
#include <dlfcn.h>
#include <errno.h>
#include <fcntl.h>
#include <pthread.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>
#include "fishhook.h"

static int (*saved_open)(const char *, int, ...);
static int (*saved_stat)(const char *, struct stat *);
static int (*saved_access)(const char *, int);
static int (*saved_rename)(const char *, const char *);
static int (*saved_unlink)(const char *);
static _Thread_local unsigned depth;

static void enter(void) {
    if (++depth > 16) {
        // Fail deterministically before overflowing the process stack.
        _Exit(42);
    }
}

static int resource_open(const char *path, int flags, ...) {
    enter();
    int result;
    if (flags & O_CREAT) {
        va_list args;
        va_start(args, flags);
        int mode = va_arg(args, int);
        va_end(args);
        result = saved_open(path, flags, mode);
    } else {
        result = saved_open(path, flags);
    }
    --depth;
    return result;
}

static int resource_stat(const char *path, struct stat *buf) {
    enter();
    int result = saved_stat(path, buf);
    --depth;
    return result;
}

static int resource_access(const char *path, int mode) {
    enter();
    int result = saved_access(path, mode);
    --depth;
    return result;
}

static int resource_rename(const char *old_path, const char *new_path) {
    enter();
    int result = saved_rename(old_path, new_path);
    --depth;
    return result;
}

static int resource_unlink(const char *path) {
    enter();
    int result = saved_unlink(path);
    --depth;
    return result;
}

static char path[4096];
static char missing[4096];
static const char *operation;

static void check_read(void) {
    if (strcmp(operation, "access") == 0) {
        assert(access(path, F_OK) == 0);
        errno = 0;
        assert(access(missing, F_OK) == -1 && errno == ENOENT);
    } else if (strcmp(operation, "stat") == 0) {
        struct stat buf;
        assert(stat(path, &buf) == 0 && buf.st_size == 4);
        errno = 0;
        assert(stat(missing, &buf) == -1 && errno == ENOENT);
    } else {
        char buf[4];
        int fd = open(path, O_RDONLY);
        assert(fd >= 0);
        assert(read(fd, buf, sizeof(buf)) == sizeof(buf));
        assert(memcmp(buf, "data", sizeof(buf)) == 0);
        assert(close(fd) == 0);
        errno = 0;
        assert(open(missing, O_RDONLY) == -1 && errno == ENOENT);
    }
}

static void *reader(void *unused) {
    (void)unused;
    for (int i = 0; i < 100; ++i) {
        check_read();
    }
    return NULL;
}

int main(int argc, char **argv) {
    assert(argc == 4);
    operation = argv[1];
    char real_path[4096];
    snprintf(real_path, sizeof(real_path), "%s/fixture-XXXXXX", argv[2]);
    int fd = mkstemp(real_path);
    assert(fd >= 0);
    assert(write(fd, "data", 4) == 4);
    assert(close(fd) == 0);

    int unreal = strcmp(argv[3], "unreal") == 0;
    if (unreal) {
        void (*enable)(void) = dlsym(RTLD_DEFAULT, "test_unreal");
        assert(enable != NULL);
        enable();
    }
    // Unreal's bug concatenates an extra prefix with an absolute home path.
    snprintf(path, sizeof(path), "%s%s", unreal ? "/ignored//" : "", real_path);
    snprintf(missing, sizeof(missing), "%s-missing", path);

    struct rebinding hooks[] = {
        {"open", resource_open, (void **)&saved_open},
        {"stat", resource_stat, (void **)&saved_stat},
        {"access", resource_access, (void **)&saved_access},
        {"rename", resource_rename, (void **)&saved_rename},
        {"unlink", resource_unlink, (void **)&saved_unlink},
    };
    assert(rebind_symbols(hooks, sizeof(hooks) / sizeof(hooks[0])) == 0);

    if (strcmp(operation, "rename") == 0) {
        char renamed[4096];
        snprintf(renamed, sizeof(renamed), "%s-renamed", path);
        assert(rename(path, renamed) == 0);
        assert(rename(renamed, path) == 0);
        errno = 0;
        assert(rename(missing, path) == -1 && errno == ENOENT);
    } else if (strcmp(operation, "unlink") == 0) {
        assert(unlink(path) == 0);
        errno = 0;
        assert(unlink(path) == -1 && errno == ENOENT);
        return 0;
    } else {
        check_read();
        pthread_t threads[8];
        for (int i = 0; i < 8; ++i) {
            assert(pthread_create(&threads[i], NULL, reader, NULL) == 0);
        }
        for (int i = 0; i < 8; ++i) {
            assert(pthread_join(threads[i], NULL) == 0);
        }
        if (strcmp(operation, "open") == 0) {
            int created = open(missing, O_CREAT, 0600);
            assert(created >= 0);
            struct stat buf;
            assert(fstat(created, &buf) == 0 && (buf.st_mode & 0777) == 0600);
            assert(close(created) == 0);
            assert(unlink(missing) == 0);
        }
    }
    assert(unlink(path) == 0);
    return 0;
}
