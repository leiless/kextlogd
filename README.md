## kextlogd - A macOS kernel extension log recorder

This log recorder can be used to logging generic kernel extension and IOKit driver in macOS

### Theorem

kextlogd will spawn a [log(1)](x-man-page://1/log)/[syslog(1)](x-man-page://1/syslog) process and redirect its output into a file

### Build

Build this project requres Xcode or [Command Line Tools](https://developer.apple.com/download/more/?=Command%20Line%20Tools) installed

```shell
# Use `release' target for release build
make
```

You can specify additional variables in `Makefile.inc`

### Caveats

Theoretically this utility support macOS >= 10.4(macOS below 10.9 not yet tested)

Due to kext cache mechanism(**need verbose explanation**), [log(1)](x-man-page://1/log) itself may unstable for logging. i.e. sometimes there is no log even if you issued one from [printf](http://xr.anadoxin.org/source/xref/macos-10.13.6-highsierra/xnu-4570.71.2/osfmk/kern/printf.c#853) or [IOLog](http://xr.anadoxin.org/source/xref/macos-10.13.6-highsierra/xnu-4570.71.2/iokit/Kernel/IOLib.cpp#1152).

In such case, a wordaround is to clean the kext cache and reload target kext

```shell
sudo kextcache -invalidate /
sudo kextunload -v foobar.kext
sudo kextload -v foobar.kext
```

### TODO

* add install/uninstall targets into Makefile

* add install_agent/uninstall_agent targets into Makefile

* add a manual page  section 1

