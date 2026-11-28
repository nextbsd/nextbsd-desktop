# nextbsd-desktop

Cross-builds the NextBSD desktop for amd64 and arm64 in CI, against the GNUstep
SDK that [nextbsd-gnustep](https://github.com/nextbsd/nextbsd-gnustep)
publishes, with the same FreeBSD cross-toolchain container as the kernel and
userland.

| Installed in | What |
|---|---|
| `/System/Library/CoreServices` | WindowServer, ScreenCaptureAgent, loginwindow, Workspace, the Dock, Help |
| `/System/Applications` | Terminal, the settings apps, Software, Update, Installer, XLibre |
| `/System/Library` | the WindowServer backend, the InnerSpace modules, the NextBSD theme, the Dock extras |

Each app keeps its own source repository; this repository pins the commit of
each that it builds. It publishes one build per architecture,
`nextbsd-desktop-<arch>.tar.gz` on its `continuous` release, which
[nextbsd-pkg](https://github.com/nextbsd/nextbsd-pkg) packages as
`NextBSD-desktop-apps` (requiring the base, the userland and
`NextBSD-gnustep`). `NextBSD-desktop` is an empty meta-package requiring
`NextBSD-server`, `NextBSD-gnustep` and `NextBSD-desktop-apps`, so
`pkg install NextBSD-desktop` and a reboot gives the whole desktop.

Planned in [nextbsd/nextbsd#675](https://github.com/nextbsd/nextbsd/issues/675)
and [#676](https://github.com/nextbsd/nextbsd/issues/676) (epic
[E47](https://github.com/nextbsd/nextbsd/issues/671)).

## What it builds, and where it goes

In `sources.lock` order, with what pkgdemon/nextbsd-gnustep's
`build-windowserver.sh` and pkgdemon/nextbsd-gnustep-apps' `install-apps.sh` do
on a machine, except that every app is installed in the SYSTEM domain instead
of `~/Applications`, and Workspace, the Dock and Help in CoreServices:

| Repository | Installs |
|---|---|
| [apps-windowserver](https://github.com/nextbsd/apps-windowserver) | `/System/Library/CoreServices/WindowServer`, `ScreenCaptureAgent.app`; `/System/Library/LaunchDaemons/org.nextbsd.WindowServer.plist`, `LaunchAgents/org.nextbsd.ScreenCaptureAgent.plist`, `Preferences/org.nextbsd.WindowServer.plist`; `/usr/lib/libWindowServerClient.so.1` (and `.so`, `.a`), `/usr/include/WindowServer`, `/usr/libdata/pkgconfig/WindowServerClient.pc`; `/usr/libexec/WindowServer` (`wsctl`, `ws-session`, `wstest`, `wscapture` ...) |
| [libs-back](https://github.com/nextbsd/libs-back) (the SDK's commit) | the WindowServer backend, `/System/Library/Bundles/libgnustep-nextbsd-032.bundle` (`Source/` only, beside NextBSD-gnustep's X11 backend) |
| [apps-loginwindow](https://github.com/nextbsd/apps-loginwindow) | `/System/Library/CoreServices/loginwindow.app` (its LaunchDaemon plist inside it, not enabled). Its `/etc/pam.d/loginwindow` is not staged: nextbsd-overlays seeds it, and NextBSD-desktop-apps' post-install writes it where it is missing |
| this repository | `/System/Library/Preferences/GlobalDefaults/NSGlobalDomain.plist` (`GSTheme` NextBSD, `GSBackHandlesWindowDecorations` NO, `GSSuppressAppIcon` YES, `GSWorkspaceApplication` Workspace, `GSHelpViewer` Help.app) and `Dock.plist` (`DockPlacement` 2, `DockUseCellTileBackground` YES): the desktop's system-wide GNUstep defaults, below each user's own |
| [nextbsd-theme](https://github.com/nextbsd/nextbsd-theme) | `/System/Library/Themes/NextBSD.theme`; its fonts in `/System/Library/Fonts` |
| [apps-terminal](https://github.com/nextbsd/apps-terminal) | `/System/Applications/Terminal.app` |
| [apps-workspace](https://github.com/nextbsd/apps-workspace) | `/System/Library/CoreServices/Workspace.app` |
| [apps-dock](https://github.com/nextbsd/apps-dock) | `/System/Library/CoreServices/Dock.app`; the extras in `/System/Library/DockExtras` |
| [libs-innerspace](https://github.com/nextbsd/libs-innerspace) | `/System/Library/InnerSpace/*.InnerSpace` |
| [apps-xlibre](https://github.com/nextbsd/apps-xlibre) | `/System/Applications/XLibre.app`, with Xnextbsd (apps-xlibre's `xnextbsd-latest` release, SHA-256 checked) inside it |
| [apps-settings](https://github.com/nextbsd/apps-settings) | `/System/Applications`: Bluetooth, Date & Time, Displays, Energy, Keyboard, Language & Region, Mouse, Network, Printers, Sound, Trackpad, Users & Login, Webcam |
| [apps-software](https://github.com/nextbsd/apps-software) | `/System/Applications/Software.app` |
| [apps-update](https://github.com/nextbsd/apps-update) | `/System/Applications/Update.app` |
| [apps-installer](https://github.com/nextbsd/apps-installer) | `/System/Applications/Installer.app` |
| [apps-textedit](https://github.com/nextbsd/apps-textedit) | `/System/Applications/TextEdit.app` |
| [apps-help](https://github.com/nextbsd/apps-help) | `/System/Library/CoreServices/Help.app`, with NextBSD Help (`Resources/NextBSD.help`) |
| [apps-video](https://github.com/nextbsd/apps-video) | `/System/Applications/Video.app` (plays and records with the SDK's ffmpeg libraries) |
| [apps-scanner](https://github.com/nextbsd/apps-scanner) | `/System/Applications/Scanner.app`; links `libsane.so.1` from NextBSD-gnustep-support (sane-backends) |
| [apps-preview](https://github.com/nextbsd/apps-preview) | `/System/Applications/Preview.app`; links `libpoppler-cpp.so.3` from NextBSD-gnustep-support (poppler) |
| [apps-server](https://github.com/nextbsd/apps-server) | `/System/Applications/Server.app`; runs `serveradmin` (nextbsd-userland) over SSH on each computer it manages |

gnustep-make also links each app into `/System/Library/Tools` (`Terminal`,
`DateTime` ...), as it does for every installed app. Outside `/System` the
build has only libWindowServerClient and the WindowServer tools in `/usr`;
nothing goes into `/etc`. Xnextbsd needs `libepoxy.so.0` from
`NextBSD-xlibre` at run time, the one library that isn't in the SDK's sysroot;
the CI checks list it in `RUNTIME-DEPS-<arch>`.

## How it builds

`build-desktop.sh` runs in the `nextbsd-toolchain` container for one
architecture (`T=amd64` or `T=arm64`), against an unpacked GNUstep SDK
(`fetch-sdk.sh` takes it from nextbsd-gnustep's `continuous` release), into a
staging root (`DESTDIR`, `/stage` in CI):

```
T=arm64 OUT=/opt/sdk ./fetch-sdk.sh
T=arm64 SDK=/opt/sdk/nextbsd-gnustep-sdk-arm64 DESTDIR=/stage ./build-desktop.sh
```

- The SDK's `env.sh` sets up the cross build: `clang` for NextBSD against the
  SDK, `/System` linked to the SDK's GNUstep, pkg-config seeing only the SDK,
  and the configure answers (`CONFIG_SITE`). Nothing built for NextBSD runs.
- libWindowServerClient, once built, is installed into the SDK too, where the
  backend, loginwindow, the Dock and the settings apps look for it.
- MIG: `migcom` is built for the build host from nextbsd-userland (its
  `bootstrap_cmds`), as nextbsd-userland's own cross build does, and `mig`
  runs it with the target's clang as the preprocessor, for the settings apps'
  and the Dock extras' MIG client stubs.
- Workspace, the Dock and Help go to CoreServices with `Workspace_INSTALL_DIR`,
  `Dock_INSTALL_DIR` and `Help_INSTALL_DIR` on the install command line;
  everything else goes where its makefile puts it in the SYSTEM domain.

The checks after the build: every ELF file is for the target, its
RPATH/RUNPATH stays in `/System` and `/usr`, and each `DT_NEEDED` is in the
SDK, the stage, or a listed run-time package (nextbsd-xlibre); no text file
or symlink names a build-host path, and no symlink dangles.

| File | What it is |
|---|---|
| `sources.lock` | each repository and the branch built, in build order |
| `build-desktop.sh` | the cross build, with per-repository times, warnings, file lists and the checks |
| `fetch-sdk.sh` | downloads and unpacks the GNUstep SDK |
| `.github/workflows/build.yml` | both architectures, with ccache; publishes to `continuous` from main |

Per architecture, CI uploads `nextbsd-desktop-<arch>` (the staged tree,
rooted at `/`), `desktop-manifest-<arch>` (`MANIFEST-<arch>.tsv`: every path
with its type, mode, size, SHA-256 or link target, and the repository that
installed it; `LOCATIONS-<arch>`: where each repository's apps, bundles and
tools went; `BUILD-INFO-<arch>`; `RUNTIME-DEPS-<arch>`) and
`desktop-build-report-<arch>` (times, logs, each repository's distinct
warnings and installed files). The build's `BUILD-INFO` (each commit, the
SDK's commits and where the SDK came from) is also installed as
`/System/Library/Preferences/nextbsd-desktop-BUILD-INFO`.

## License

BSD 2-Clause. See [LICENSE](LICENSE). This covers this repository's build
scripts; each app keeps its own license.
