/**
 * Kernel extension logging utility
 *
 * Created 180817
 */

#import <Foundation/Foundation.h>

#include <stdio.h>
#include <stdlib.h>
#include <assert.h>
#include <unistd.h>
#include <mach-o/ldsyms.h>

#define LOG(fmt, ...)       NSLog(@fmt, ##__VA_ARGS__)
#define LOG_ERR(fmt, ...)   LOG("ERR: " fmt, ##__VA_ARGS__)
#ifdef DEBUG
#define LOG_DBG(fmt, ...)   LOG("DBG: " fmt, ##__VA_ARGS__)
#else
#define LOG_DBG(fmt, ...)   (void) (0, ##__VA_ARGS__)
#endif

/**
 * Initialize a file handle from given path
 */
static NSFileHandle *create_filehandle(NSString *path)
{
    assert(path != nil);

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
 * @cycnt       FIFO recycle count limit    <=0 indicate no recycle at all
 * @return      0 if success  -1 o.w.
 */
static int recycle_file(NSFileHandle **fhp, NSString *path, long max_sz, long cycnt)
{
    assert(fhp != nil);
    NSFileHandle *fh = *fhp;
    assert(fh != nil);

    if (fh == [NSFileHandle fileHandleWithStandardOutput]) return 0;
    assert(path != nil);

    if (max_sz <= 0 || [fh offsetInFile] < max_sz) return 0;
    if (cycnt <= 0) {
        [fh truncateFileAtOffset:0];
        return 0;
    }

    size_t sz = [path length] + 12;
    char old[sz];
    char new[sz];
    int e;
    long i = cycnt;
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

#define PCOMM       "kextlogd"

static void usage(void)
{
    fprintf(stderr, "Usage: %s [-o FILE] [-m NUM] [-c NUM] NAME\n\n", PCOMM);
    exit(1);
}

/**
 * see:
 *  https://stackoverflow.com/questions/10119700
 *  https://lowlevelbits.org/parsing-mach-o-files
 */
NSString *egoUUID(void)
{
    const uint8_t *c = (const uint8_t *)(&_mh_execute_header + 1);
    for (uint32_t i = 0; i < _mh_execute_header.ncmds; i++) {
        if (((const struct load_command *) c)->cmd == LC_UUID) {
            c += sizeof(struct load_command);
            return [NSString stringWithFormat:@"%02x%02x%02x%02x-%02x%02x-%02x%02x-%02x%02x-%02x%02x%02x%02x%02x%02x",
                    c[0], c[1], c[2], c[3], c[4], c[5], c[6], c[7],
                    c[8], c[9], c[10], c[11], c[12], c[13], c[14], c[15]];
        } else {
            c += ((const struct load_command *) c)->cmdsize;
        }
    }

    return [NSString string];
}

int main(int argc, char *argv[])
{
    if (argc < 2) usage();

    const char *output = NULL;
    long max_sz = 0;
    long cycnt = 0;
    int ch;
    while ((ch = getopt(argc, argv, "o:m:c:")) != -1) {
        switch (ch) {
        case 'o':
            output = optarg;
            break;
        case 'm':
            max_sz = atol(optarg);
            break;
        case 'c':
            cycnt = atol(optarg);
            break;
        case '?':
        default:
            usage();
        }
    }

    if (optind != argc - 1) usage();
    char *name = argv[optind];

    printf("%s  (built: %s %s uuid: %s)\n\n",
        PCOMM, __DATE__, __TIME__, [egoUUID() UTF8String]);

    NSTask *task = [[NSTask alloc] init];
    [task setLaunchPath: @"/bin/sh"];
    NSString *cmd = [NSString stringWithFormat:@"/usr/bin/log stream --predicate 'processID == 0 and sender == \"%s\"'", name];
    [task setArguments:@[@"-c", cmd]];
    // syslog | grep -w 'kernel\[0\]' | grep -w XXX


    /**
     * The NSPipe seems line buffered
     * see: https://cocoadev.github.io/NSPipe
     */
    NSPipe *pipe = [NSPipe pipe];
    [task setStandardOutput:pipe];
    [task setStandardError:pipe];
    [task launch];

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
            [file writeData:[@"\n\n" dataUsingEncoding:NSUTF8StringEncoding]];
        }
    }
    NSData *data;
    if (file == nil) goto out_exit;

    while (1) {
        data = [fh availableData];    /* WOULDBLOCK */

        if ([data length] != 0) {
            [file writeData:data];

            if (recycle_file(&file, path, max_sz, cycnt) != 0) {
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

