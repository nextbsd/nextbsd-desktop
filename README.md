# nextbsd-desktop

Cross-builds the NextBSD desktop for amd64 and arm64 in CI, against the GNUstep
SDK that [nextbsd-gnustep](https://github.com/nextbsd/nextbsd-gnustep)
publishes, with the same FreeBSD cross-toolchain container as the kernel and
userland.

| Installed in | What |
|---|---|
| `/System/Library/CoreServices` | WindowServer, loginwindow, Workspace, the Dock |
| `/System/Applications` | Terminal, the settings apps, Software, Update, Installer |
| `/System/Library` | the InnerSpace modules, the NextBSD theme |

Each app keeps its own source repository; this repository pins the commit of
each that it builds. It publishes one build per architecture, which
[nextbsd-pkg](https://github.com/nextbsd/nextbsd-pkg) packages as
`NextBSD-desktop`, requiring `NextBSD-server` and `NextBSD-gnustep`.
`pkg install NextBSD-desktop` and a reboot then gives the whole desktop.

Planned in [nextbsd/nextbsd#675](https://github.com/nextbsd/nextbsd/issues/675)
(epic [E47](https://github.com/nextbsd/nextbsd/issues/671)).

## License

BSD 2-Clause. See [LICENSE](LICENSE). This covers this repository's build
scripts; each app keeps its own license.
