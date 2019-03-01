kextlogd - A macOS kernel extension log recorder

This log recorder can be used to logging generic kernel extension and IOKit driver

Theorem:
kextlogd will spawn a log(1)/syslog(1) process and redirect its output into a file

NOTE:
Theoretically support macOS >= 10.4(macOS < 10.10 not yet tested)
Due to kext cache mechanism(need verbose explanation)  log(1) itself may unstable for logging
	i.e. sometimes there is no log even if a kext fired one

In such case, a wordaround is to clean the kext cache:
sudo kextcache -invalidate /

TODO:
add install/uninstall targets into Makefile
add install_agent/uninstall_agent targets into Makefile
add a manual page  section 1
