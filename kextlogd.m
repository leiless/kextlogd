/**
 * Kernel extension logging utility
 *
 * Created 180817
 */

#import <Foundation/Foundation.h>

#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>
#include <getopt.h>
#include <mach-o/ldsyms.h>

/* XXX: ONLY quote those deprecated functions */
#define SUPPRESS_WARN_DEPRECATED_DECL_BEGIN     \
    _Pragma("clang diagnostic push")            \
    _Pragma("clang diagnostic ignored \"-Wdeprecated-declarations\"")

#define SUPPRESS_WARN_DEPRECATED_DECL_END       \
    _Pragma("clang diagnostic pop")

#define CHECK_STATUS(ex)    NSCParameterAssert(ex)
#define CHECK_NONNULL(ptr)  NSCParameterAssert(ptr != NULL)

#define LOG(fmt, ...)       printf(fmt "\n", ##__VA_ARGS__)
#define LOG_ERR(fmt, ...)   fprintf(stderr, "[ERR]: " fmt "\n", ##__VA_ARGS__)
#ifdef DEBUG
#define LOG_DBG(fmt, ...)   LOG("[DBG]: " fmt, ##__VA_ARGS__)
#else
#define LOG_DBG(fmt, ...)   (void) (0, ##__VA_ARGS__)
#endif

/**
 * Initialize a file handle from given path
 */
static NSFileHandle *create_filehandle(NSString *path)
{
    CHECK_NONNULL(path);

    NSFileManager *fm = [NSFileManager defaultManager];
    if (![fm fileExistsAtPath:path]) {
        /* Will truncate file if already exists */
        if (![fm createFileAtPath:path contents:nil attributes:nil]) {
            LOG_ERR("NSFileManager createFileAtPath");
            return nil;
        }
    }

    NSFileHandle *file = [NSFileHandle fileHandleForWritingAtPath:path];
    if (file == nil) {
        LOG_ERR("NSFileHandle fileHandleForWritingAtPath");
        return nil;
    }

    return file;
}

/**
 * Recycle a file when it getting too large
 *
 * @fhp         file handle pointer
 * @path        backing file path associated to the file handle
 * @max_sz      maximum file size in bytes  <=0 indicate no write limit
 * @rollcnt     FIFO recycle count limit    <=0 indicate no rolling at all
 * @return      0 if success  -1 o.w.
 */
static int recycle_file(NSFileHandle **fhp, NSString *path, long max_sz, long rollcnt)
{
    CHECK_NONNULL(fhp);
    CHECK_NONNULL(*fhp);
    CHECK_NONNULL(path);

    NSFileHandle *fh = *fhp;

    if (fh == [NSFileHandle fileHandleWithStandardOutput]) return 0;

    if (max_sz == 0 || [fh offsetInFile] < (uint64_t) max_sz) return 0;
    if (rollcnt == 0) {
        [fh truncateFileAtOffset:0];
        return 0;
    }

    size_t sz = [path length] + 12;
    char old[sz];
    char new[sz];
    int e;
    long i = rollcnt;
    while (--i > 0) {
        sprintf(old, "%s.%ld", [path UTF8String], i);
        sprintf(new, "%s.%ld", [path UTF8String], i+1);
        e = rename(old, new);
        if (e != 0 && errno != ENOENT) {
            LOG_ERR("#1 mv %s %s  errno: %d", old, new, errno);
            return -1;
        }
    }

    [fh closeFile];

    sprintf(old, "%s", [path UTF8String]);
    sprintf(new, "%s.1", [path UTF8String]);
    e = rename(old, new);
    if (e != 0) {
        LOG_ERR("#2 mv %s %s  errno: %d", old, new, errno);
        *fhp = [NSFileHandle fileHandleWithStandardError];
        return -1;
    }

    NSFileHandle *fh1 = create_filehandle(path);
    if (fh1 == nil) {
        *fhp = [NSFileHandle fileHandleWithStandardError];
        return -1;
    }

    *fhp = fh1;
    return 0;
}

#define CMDNAME     "kextlogd"
#define VERSION     "0.5"

static void usage(void)
{
    fprintf(stderr,
            "usage:\n"
            "%s [-o file] [-x number] [-c number] name\n"
            "           -o, --output            Output file path\n"
            "           -x, --max-size          Maximum single rolling file size\n"
            "           -c, --rolling-count     Maximum rolling file count\n"
            "           -v, --version           Print version\n",
            CMDNAME);
    exit(1);
}

/**
 * see:
 *  https://stackoverflow.com/questions/10119700
 *  https://lowlevelbits.org/parsing-mach-o-files
 */
static const char *mh_exec_uuid(void)
{
    const uint8_t *c = (const uint8_t *)(&_mh_execute_header + 1);
    for (uint32_t i = 0; i < _mh_execute_header.ncmds; i++) {
        if (((const struct load_command *) c)->cmd == LC_UUID) {
            c += sizeof(struct load_command);
            return [[NSString stringWithFormat:
                    @"%02x%02x%02x%02x-%02x%02x-%02x%02x-%02x%02x-%02x%02x%02x%02x%02x%02x",
                    c[0], c[1], c[2], c[3], c[4], c[5], c[6], c[7],
                    c[8], c[9], c[10], c[11], c[12], c[13], c[14], c[15]] UTF8String];
        } else {
            c += ((const struct load_command *) c)->cmdsize;
        }
    }

    return [[NSString string] UTF8String];
}

/**
 * Retrieve last segment of UUID
 */
static const char *mh_exec_uuid_ls(void)
{
    const char *uuid = mh_exec_uuid();
    char *p = strrchr(uuid, '-');
    if (p == NULL) return uuid;
    return p + 1;
}

/**
 * Retrieve system(product-level) version
 * @return      system version in format of xxyyzz
 *              which represents major, minor, patch version respectively
 *              0 indicates an error occurred
 * see: sw_vers(1)
 */
static long os_version(void)
{
    static volatile long ver = 0;
    if (ver != 0) goto out_exit;

    if ([[NSProcessInfo processInfo] respondsToSelector:@selector(operatingSystemVersion)]) {
        NSOperatingSystemVersion v = [[NSProcessInfo processInfo] operatingSystemVersion];
        CHECK_STATUS(v.majorVersion < 100);
        CHECK_STATUS(v.minorVersion < 100);
        CHECK_STATUS(v.patchVersion < 100);

        ver = 10000 * v.majorVersion + 100 * v.minorVersion + v.patchVersion;
    } else {
        SInt32 v[3];
SUPPRESS_WARN_DEPRECATED_DECL_BEGIN
        if (Gestalt(gestaltSystemVersionMajor, v) == noErr &&
            Gestalt(gestaltSystemVersionMinor, v+1) == noErr &&
            Gestalt(gestaltSystemVersionBugFix, v+2) == noErr) {
SUPPRESS_WARN_DEPRECATED_DECL_END
            CHECK_STATUS(v[0] < 100);
            CHECK_STATUS(v[1] < 100);
            CHECK_STATUS(v[2] < 100);

            ver = 10000 * v[0] + 100 * v[1] + v[2];
        }
    }

out_exit:
    return ver;
}

static NSTask *task = nil;

static void proc_cleanup(int signo)
{
    LOG_DBG("Caught signal: %d", signo);

    CHECK_STATUS(task != nil);
    int pid = [task processIdentifier];
    if (pid == 0) {
        LOG_DBG("Logging process not yet spawn or already dead?");
        return;
    }

    if (kill(pid, SIGKILL) != 0) {
        LOG_ERR("kill(2) failed  errno: %d", errno);
    }
}

static inline void proc_cleanup2(void)
{
    proc_cleanup(-1);
}

#define ARRAY_SIZE(a)           (sizeof(a) / sizeof(*a))

/*
 * see: https://www.gnu.org/software/libc/manual/html_node/Termination-Signals.html
 */
static void reg_exit_entries(void)
{
    static int sig[] = {SIGHUP, SIGINT, SIGQUIT, SIGTERM, SIGTSTP};
    static size_t sz = ARRAY_SIZE(sig);
    size_t i;

    for (i = 0; i < sz; i++) {
        if (signal(sig[i], proc_cleanup) == SIG_ERR) {
            LOG_ERR("signal(2) failed  sig: %d errno: %d", sig[i], errno);
        }
    }

    if (atexit(proc_cleanup2) != 0) {
        LOG_ERR("atexit(3) failed  errno: %d", errno);
    }
}

#ifndef __TARGET_OS__
#define __TARGET_OS__   "apple-darwin"
#endif

static void print_version(void)
{
    LOG("%s v%s (built: %s %s uuid_ls: %s)\n"
        "compiler: Apple LLVM version %s\n"
        "target:   %s",
        CMDNAME, VERSION, __DATE__, __TIME__, mh_exec_uuid_ls(),
        __clang_version__, __TARGET_OS__);
}

int main(int argc, char *argv[])
{
    if (argc < 2) usage();

    const char *output = NULL;
    long max_sz = 0;
    long rollcnt = 0;

    static struct option long_options[] = {
        {"output", required_argument, NULL, 'o'},
        {"max-size", required_argument, NULL, 'x'},
        {"rolling-count", required_argument, NULL, 'c'},
        {"version", no_argument, NULL, 'v'},
        {NULL, no_argument, NULL, 0},
    };

    int opt;
    int long_index;
    char *endptr;

    while ((opt = getopt_long(argc, argv, "o:x:c:v", long_options, &long_index)) != -1) {
        switch (opt) {
        case 'o':
            output = optarg;
            break;
        case 'x':
            errno = 0;
            max_sz = strtol(optarg, &endptr, 10);
            if (errno != 0) {
                LOG_ERR("strtol(3) failure  errno: %d", errno);
                exit(EXIT_FAILURE);
            }
            if (*endptr != '\0' || max_sz < 0) {
                LOG_ERR("Bad size: %s", optarg);
                exit(EXIT_FAILURE);
            }
            break;
        case 'c':
            errno = 0;
            rollcnt = strtol(optarg, &endptr, 10);
            if (errno != 0) {
                LOG_ERR("strtol(3) failure  errno: %d", errno);
                exit(EXIT_FAILURE);
            }
            if (*endptr != '\0' || rollcnt < 0) {
                LOG_ERR("Bad count: %s", optarg);
                exit(EXIT_FAILURE);
            }
            break;
        case 'v':
            print_version();
            exit(0);
        case '?':
        default:
            usage();
        }
    }

    if (optind != argc - 1) usage();
    char *name = argv[optind];

    print_version();

    LOG_DBG("output: %s max_size: %ld rolling_count: %ld", output, max_sz, rollcnt);

    task = [[NSTask alloc] init];
    [task setLaunchPath:@"/bin/sh"];

    NSString *cmd;
    if (os_version() >= 101200L) {
        cmd = [NSString stringWithFormat:@"/usr/bin/log stream --predicate 'processID == 0 and sender == \"%s\"'", name];
    } else {
        cmd = [NSString stringWithFormat:@"/usr/bin/syslog -F '$((Time)(JZ)) $Host <$((Level)(str))> $(Sender)[$(PID)]: $Message' -w 0 -k PID 0 -k Sender kernel -k Message S '%s'", name];
    }
    LOG_DBG("cmd: %s", [cmd UTF8String]);
    [task setArguments:@[@"-c", cmd]];

    /**
     * The NSPipe seems line buffered
     * see: https://cocoadev.github.io/NSPipe
     */
    NSPipe *pipe = [NSPipe pipe];
    [task setStandardOutput:pipe];
    [task setStandardError:pipe];

    reg_exit_entries();

    [task launch];
    LOG_DBG("Logging process pid: %d", [task processIdentifier]);

    NSFileHandle *fh = [pipe fileHandleForReading];
    NSFileHandle *file;
    NSString *path = output ? @(output) : nil;
    if (output == NULL) {
        file = [NSFileHandle fileHandleWithStandardOutput];
    } else {
        file = create_filehandle(path);
        unsigned long long off = [file seekToEndOfFile];
        if (off != 0) {
            /* Separate each instance log */
            [file writeData:[@"\n" dataUsingEncoding:NSUTF8StringEncoding]];
        }
    }
    NSData *data;
    if (file == nil) goto out_exit;

    while (1) {
        data = [fh availableData];    /* WOULDBLOCK */

        if ([data length] != 0) {
            [file writeData:data];

            if (recycle_file(&file, path, max_sz, rollcnt) != 0) {
                [file writeData:[@"\nERR: Failure when recycling log file\n" dataUsingEncoding:NSUTF8StringEncoding]];
                break;
            }
        } else {
            [file writeData:[@"\nERR: EOF when reading from pipe\n" dataUsingEncoding:NSUTF8StringEncoding]];
            break;
        }
    }

    [file closeFile];
out_exit:
    [task terminate];
    return 1;
}

