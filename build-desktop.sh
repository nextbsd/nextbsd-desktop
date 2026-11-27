#!/usr/bin/env bash
# =============================================================================
# build-desktop.sh: cross-build the NextBSD desktop for one architecture
# =============================================================================
#
# Builds every repository in sources.lock, in order, against the GNUstep SDK
# from nextbsd-gnustep, and installs them into one staging root ($DESTDIR) laid
# out as the packaged desktop is installed:
#
#   /System/Library/CoreServices   WindowServer, ScreenCaptureAgent.app,
#                                  loginwindow.app, Workspace.app, Dock.app,
#                                  Help.app
#   /System/Applications           Terminal, TextEdit, Video, Scanner, the
#                                  settings apps, Software, Update, Installer,
#                                  XLibre
#   /System/Library/...            the WindowServer backend
#                                  (Bundles/libgnustep-nextbsd-*.bundle), the
#                                  theme (Themes/NextBSD.theme, its Fonts),
#                                  the InnerSpace modules (InnerSpace/), the
#                                  Dock extras (DockExtras/), the LaunchDaemon
#                                  and LaunchAgent
#   /usr                           libWindowServerClient, its headers and .pc,
#                                  and wsctl and the other WindowServer tools
#                                  (/usr/libexec/WindowServer)
#   /System/Library/Preferences/GlobalDefaults
#                                  the desktop's system-wide GNUstep
#                                  defaults, from this repository
# Nothing goes into /etc: /etc/pam.d/loginwindow is nextbsd-overlays'.
#
# This is what pkgdemon/nextbsd-gnustep's build-windowserver.sh and
# pkgdemon/nextbsd-gnustep-apps' install-apps.sh build on a machine, with the
# same flags, except that every app goes into the SYSTEM domain instead of
# ~/Applications, and Workspace, the Dock and Help into CoreServices.
#
# How it cross-builds: the SDK's env.sh sets everything up (clang and clang++
# for the target against the SDK's sysroot, /System linked to the SDK's
# GNUstep, pkg-config seeing only the SDK, CONFIG_SITE). On top of that:
#   - libWindowServerClient, its headers and its .pc are also installed into
#     the SDK, once built, where everything after it looks for them;
#   - MIG: migcom is built for the build host from nextbsd-userland, as
#     nextbsd-userland's own cross build does, and `mig` runs it with the
#     target's clang as the preprocessor (bin-<arch>/mig);
#   - Xnextbsd, XLibre's X server, is apps-xlibre's CI build
#     (xnextbsd-latest release), checked against its SHA-256, as
#     install-apps.sh does on a machine.
#
# Environment (the CI workflow sets these):
#   T             amd64 | arm64
#   SDK           the unpacked GNUstep SDK (nextbsd-gnustep-sdk-<arch>).
#                 Scratch: libWindowServerClient is installed into it.
#   CROSS_BINDIR  the image's clang/lld (set by the nextbsd-toolchain image)
#   DESTDIR       the staging root (default /stage)
#   CCACHE        non-empty: compile through ccache
#   XNEXTBSD      a local Xnextbsd binary to use instead of downloading one
#   RUNTIME_ROOTS space-separated <package>=<dir>: other NextBSD packages'
#                 staged trees (nextbsd-xlibre for Xnextbsd's libepoxy), which
#                 the checks resolve DT_NEEDED against after the SDK; what is
#                 found there goes to RUNTIME-DEPS-<arch>
#
# Usage:
#   ./build-desktop.sh                 everything, in sources.lock order
#   ./build-desktop.sh apps-dock ...   only those (what they need must already
#                                      be built, in the SDK and in $DESTDIR)
#
# Results, in .build/: times-<arch>.tsv (seconds per repository),
# BUILD-INFO-<arch> (the commit of each), logs-<arch>/<repo>.log,
# warnings-<arch>/<repo>.txt (each distinct compiler warning) and
# warnings-<arch>.tsv (counts), files-<arch>/<repo>.txt (what each installed),
# and, after the checks, LOCATIONS-<arch> and MANIFEST-<arch>.tsv (every
# staged file, with its type, mode, size, SHA-256 and repository).
# =============================================================================

set -euo pipefail

: "${T:?set T to amd64 or arm64}"
: "${SDK:?set SDK to the unpacked GNUstep SDK}"
: "${CROSS_BINDIR:?set CROSS_BINDIR to the toolchain clang directory}"
: "${DESTDIR:=/stage}"
: "${CCACHE:=}"
: "${XNEXTBSD:=}"
: "${RUNTIME_ROOTS:=}"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD="$ROOT/.build"
SRC="$BUILD/src-$T"
WRAP="$BUILD/bin-$T"
LOGS="$BUILD/logs-$T"
WARN="$BUILD/warnings-$T"
FILES="$BUILD/files-$T"
TIMES="$BUILD/times-$T.tsv"
INFO="$BUILD/BUILD-INFO-$T"

case "$T" in
    amd64) TA=amd64;   WANT_MACHINE='X86-64' ;;
    arm64) TA=aarch64; WANT_MACHINE='AArch64' ;;
    *) echo "FAIL: T=$T is not amd64 or arm64" >&2; exit 1 ;;
esac
BUILD_TRIPLE="$(uname -m)-pc-linux-gnu"
JOBS="$(nproc 2>/dev/null || echo 2)"

SDK="$(cd "$SDK" && pwd)"
mkdir -p "$DESTDIR"
DESTDIR="$(cd "$DESTDIR" && pwd)"

comp() { echo; echo "==> [$T] $*"; }
note() { echo "    - $*"; }
fail() { echo "FAIL: $*" >&2; exit 1; }

# ---- the build environment ---------------------------------------------------

setup() {
    mkdir -p "$BUILD" "$SRC" "$WRAP" "$LOGS" "$WARN" "$FILES"

    # The build host's own environment, for host tools (migcom).
    HOST_PATH="$PATH"
    [ -f "$SDK/env.sh" ] || fail "$SDK is not a GNUstep SDK (no env.sh)"
    export NEXTBSD_SDK="$SDK" NEXTBSD_CLANG_BINDIR="$CROSS_BINDIR"
    # shellcheck disable=SC1091
    . "$SDK/env.sh"
    if [ -n "$CCACHE" ]; then
        export NEXTBSD_CCACHE=1
    else
        unset NEXTBSD_CCACHE
    fi

    # gmake is GNU make under the name NextBSD has it; apps-windowserver's
    # README and gnustep-make's configuration use it.
    ln -sf "$(command -v make)" "$WRAP/gmake"
    export PATH="$WRAP:$PATH"

    # As build-windowserver.sh and install-apps.sh, except for the domain.
    umask 022
    export ac_cv_prog_cc_c23=no
    export GNUSTEP_INSTALLATION_DOMAIN=SYSTEM
    unset CPATH LIBRARY_PATH LD_LIBRARY_PATH

    command -v plmerge >/dev/null || fail "no plmerge on the build host (apt-get install gnustep-base-runtime)"
    command -v pl2link >/dev/null || fail "no pl2link on the build host (apt-get install gnustep-base-runtime)"
    command -v pkgconf >/dev/null || fail "no pkgconf on the build host"
    clang --version | head -1
    note "host $NEXTBSD_HOST, build $BUILD_TRIPLE, $JOBS jobs, ccache ${CCACHE:-off}"
    note "SDK $SDK"
    [ -f "$SDK/BUILD-INFO" ] && sed 's/^/      sdk: /' "$SDK/BUILD-INFO"
    return 0
}

# ---- sources -----------------------------------------------------------------

# lock_field <name> <url|ref>
lock_field() {
    local col
    case "$2" in url) col=2 ;; ref) col=3 ;; *) fail "lock_field $2" ;; esac
    awk -v n="$1" -v c="$col" '$1 == n { print $c; found=1 } END { exit !found }' "$ROOT/sources.lock" ||
        fail "$1 is not in sources.lock"
}

# fetch <name> [sparse paths...]: a fresh shallow clone of the repository's ref
# (or, for @sdk, of the commit the SDK records); sets S. With paths, only those
# are checked out.
fetch() {
    local name="$1" url ref commit
    shift
    url=$(lock_field "$name" url)
    ref=$(lock_field "$name" ref)
    S="$SRC/$name"
    # A rerun in the same tree builds in a new directory, never deleting.
    [ -e "$S" ] && S="$SRC/$name.$(date +%s)"
    if [ "$ref" = "@sdk" ]; then
        commit=$(awk -v n="$name" '$1 == n { print $4 }' "$SDK/BUILD-INFO" 2>/dev/null)
        [ -n "$commit" ] || fail "$name: the SDK's BUILD-INFO records no commit for it"
        git init -q "$S"
        git -C "$S" fetch -q --depth 1 "$url" "$commit"
        git -C "$S" checkout -q FETCH_HEAD
    elif [ $# -gt 0 ]; then
        git clone -q --depth 1 --filter=blob:none --sparse --branch "$ref" "$url" "$S"
        git -C "$S" sparse-checkout set "$@"
    else
        git clone -q --depth 1 --branch "$ref" "$url" "$S"
    fi
    printf '%s\t%s\t%s\t%s\n' "$name" "$url" "$ref" "$(git -C "$S" rev-parse HEAD)" >> "$INFO"
    note "$name $ref $(git -C "$S" rev-parse --short HEAD)"
}

# ---- the repositories --------------------------------------------------------

# Host migcom, as nextbsd-userland's build-userland.sh (Tier 0) builds it:
# FreeBSD's legacy stage builds it with the build host's compiler, in the
# image's /usr/src. `mig` (bin-<arch>/mig) is mig.sh with that migcom and the
# target's clang as the .defs preprocessor, so the stubs see the target's
# headers and macros.
build_nextbsd_userland() {
    fetch nextbsd-userland src/bootstrap_cmds/migcom.tproj src/libmach/include
    [ ! -e /usr/src/libexec/migcom ] && [ ! -e /usr/src/libmach ] ||
        fail "/usr/src already has libexec/migcom or libmach; this must run in a fresh container"
    mkdir -p /usr/src/libexec/migcom /usr/src/libmach
    cp -a "$S/src/bootstrap_cmds/migcom.tproj/." /usr/src/libexec/migcom/
    cp -a "$S/src/libmach/include" /usr/src/libmach/
    # With the build host's environment: env.sh's CC=clang and PATH would
    # make the legacy stage compile host tools with the target's clang.
    ( cd /usr/src && env -u CC -u CXX -u OBJC -u CONFIG_SITE -u PKG_CONFIG_LIBDIR \
        -u PKG_CONFIG_PATH -u GNUSTEP_MAKEFILES -u GNUSTEP_CONFIG_FILE PATH="$HOST_PATH" \
        ./tools/build/make.py --cross-bindir="$CROSS_BINDIR" \
        TARGET="$T" TARGET_ARCH="$TA" LOCAL_LEGACY_DIRS=libexec/migcom _legacy )
    local migcom
    migcom=$(find /usr/obj -path '*/legacy/usr/libexec/migcom' -type f 2>/dev/null | head -1)
    [ -n "$migcom" ] || fail "the legacy stage built no migcom"
    cp "$S/src/bootstrap_cmds/migcom.tproj/mig.sh" "$WRAP/mig.sh"
    cat > "$WRAP/mig" <<EOF
#!/bin/sh
# mig for NextBSD $T: the build host's migcom, the target's clang as cpp.
MIGCOM="$migcom" MIGCC="$SDK/bin/clang" exec /bin/sh "$WRAP/mig.sh" "\$@"
EOF
    chmod 755 "$WRAP/mig"
    mig -version
}

# build-windowserver.sh: WindowServer, libWindowServerClient and the tools,
# then ScreenCaptureAgent. The client library also goes into the SDK, where
# the backend, loginwindow, the Dock and the settings apps look for it.
build_apps_windowserver() {
    fetch apps-windowserver
    cd "$S"
    make -j"$JOBS"
    make install DESTDIR="$DESTDIR"
    make install DESTDIR="$SDK"
    pkgconf --exists WindowServerClient || fail "WindowServerClient.pc is not in the SDK"
    make -j"$JOBS" agent messages=yes
    make install-agent DESTDIR="$DESTDIR"
}

# build-windowserver.sh: libs-back's nextbsd backend, Source/ only (a
# top-level install would also install this build's gpbs and back.make over
# the X11 backend's, which NextBSD-gnustep has).
build_libs_back() {
    fetch libs-back
    cd "$S"
    fonts=no ./configure --build="$BUILD_TRIPLE" --host="$NEXTBSD_HOST" \
        --enable-server=nextbsd \
        --enable-graphics=cairo \
        --with-name=nextbsd \
        --without-x
    fonts=no make -C Source -j"$JOBS" messages=yes
    fonts=no make -C Source install DESTDIR="$DESTDIR"
}

# gnustep_app <name> [make install variables...]: gnustep-make's build, then
# install into the staging root (the SYSTEM domain unless told otherwise).
gnustep_app() {
    local name="$1"
    shift
    fetch "$name"
    cd "$S"
    make -j"$JOBS" messages=yes
    make install DESTDIR="$DESTDIR" "$@"
}

# CoreServices for the system UI that isn't opened from Applications.
CORESERVICES=/System/Library/CoreServices

# loginwindow's PAM service goes to a scratch directory, not into the
# stage: /etc is the admin's. nextbsd-overlays seeds /etc/pam.d/loginwindow
# on new images, and NextBSD-desktop-apps' post-install writes it where it
# is missing (nextbsd/nextbsd#676).
build_apps_loginwindow() { gnustep_app apps-loginwindow PAM_DIR="$BUILD/pam.d-$T"; }
build_nextbsd_theme()    { gnustep_app nextbsd-theme; }
build_apps_terminal()    { gnustep_app apps-terminal; }
build_apps_workspace()   { gnustep_app apps-workspace Workspace_INSTALL_DIR="$DESTDIR$CORESERVICES"; }
build_apps_dock()        { gnustep_app apps-dock Dock_INSTALL_DIR="$DESTDIR$CORESERVICES"; }
build_libs_innerspace()  { gnustep_app libs-innerspace; }
build_apps_settings()    { gnustep_app apps-settings; }
build_apps_software()    { gnustep_app apps-software; }
build_apps_installer()   { gnustep_app apps-installer; }
build_apps_textedit()    { gnustep_app apps-textedit; }
# Help, with NextBSD Help in it; every app's Help menu opens it
# (GSHelpViewer in GlobalDefaults/NSGlobalDomain.plist).
build_apps_help()        { gnustep_app apps-help Help_INSTALL_DIR="$DESTDIR$CORESERVICES"; }
build_apps_video()       { gnustep_app apps-video; }

# Scanner links libsane.so.1 (and zlib) from the SDK's sysroot, where
# NextBSD-gnustep-support's sane-backends puts it; the backends and their
# configuration are that package's, at run time.
build_apps_scanner()     { gnustep_app apps-scanner; }

# Update compiles in apps-settings' NBSettings, from the checkout built
# above (install-apps.sh clones them side by side).
build_apps_update() {
    local settings
    settings=$(ls -d "$SRC"/apps-settings* 2>/dev/null | tail -1)
    [ -d "$settings/Frameworks/NBSettings" ] || fail "apps-update needs apps-settings built first"
    gnustep_app apps-update NBSETTINGS="$settings/Frameworks/NBSettings"
}

# XLibre.app, then Xnextbsd inside it. Xnextbsd needs meson and a full X
# server build; apps-xlibre's CI builds it and publishes it on the
# xnextbsd-latest release, which install-apps.sh fetches too.
XNEXTBSD_URL=https://github.com/nextbsd/apps-xlibre/releases/download/xnextbsd-latest
build_apps_xlibre() {
    fetch apps-xlibre
    cd "$S"
    make -j"$JOBS" messages=yes
    make install DESTDIR="$DESTDIR"
    local bin="$XNEXTBSD" want have
    if [ -z "$bin" ]; then
        bin="$BUILD/xnextbsd-$T.$(date +%s)/Xnextbsd-$T"
        mkdir -p "$(dirname "$bin")"
        curl -fsSL -o "$bin" "$XNEXTBSD_URL/Xnextbsd-$T"
        curl -fsSL -o "$bin.sha256" "$XNEXTBSD_URL/Xnextbsd-$T.sha256"
        want=$(awk '{ print $1; exit }' "$bin.sha256")
        have=$(sha256sum "$bin" | awk '{ print $1 }')
        [ -n "$want" ] && [ "$want" = "$have" ] || fail "Xnextbsd-$T: SHA-256 is $have, expected $want"
        printf 'Xnextbsd\t%s\txnextbsd-latest\tsha256:%s\n' "$XNEXTBSD_URL/Xnextbsd-$T" "$have" >> "$INFO"
    else
        printf 'Xnextbsd\t%s\tlocal\tsha256:%s\n' "$bin" "$(sha256sum "$bin" | awk '{ print $1 }')" >> "$INFO"
    fi
    "$CROSS_BINDIR/llvm-readelf" -h "$bin" | grep -q "Machine:.*$WANT_MACHINE" || fail "Xnextbsd-$T is not $WANT_MACHINE"
    # XLibre/'s install passes Xnextbsd's makefile a GNUSTEP_APPS that already
    # has DESTDIR in it, plus DESTDIR again; install it here with the app's
    # real path instead.
    make -C Xnextbsd -f GNUmakefile install XNEXTBSD="$bin" \
        XLIBRE_APP=/System/Applications/XLibre.app DESTDIR="$DESTDIR"
}

# ---- bookkeeping -------------------------------------------------------------

snapshot() { find "$DESTDIR" -mindepth 1 | sed "s#^$DESTDIR##" | LC_ALL=C sort; }

# warnings <repo>: each distinct compiler or linker warning in its log.
collect_warnings() {
    local name="$1" n
    grep -E '(warning:|WARNING:)' "$LOGS/$name.log" | sed -E "s#$SRC/[^/]+/##g" |
        LC_ALL=C sort -u > "$WARN/$name.txt" || true
    n=$(grep -c . "$WARN/$name.txt" || true)
    printf '%s\t%s\t%s\n' "$T" "$name" "$n" >> "$BUILD/warnings-$T.tsv"
    note "$name: $n distinct warnings"
}

# ---- checks ------------------------------------------------------------------

# Every ELF file staged is for the target, its RPATH/RUNPATH stays in /System
# and /usr, and each DT_NEEDED is a library the installed system has (the
# SDK's sysroot and GNUstep, or this stage). No text file names a build-host
# path; no symlink points at one, or at nothing.
check_stage() {
    comp "checking $DESTDIR"
    local readelf="$CROSS_BINDIR/llvm-readelf" f dyn n d found bad=0 count=0 devlink= target dir
    local libdirs="$SDK/lib $SDK/usr/lib $SDK/usr/lib/system $SDK/usr/X11/lib" r deps="$BUILD/RUNTIME-DEPS-$T"
    : > "$deps"
    while IFS= read -r -d '' f; do
        head -c 4 "$f" | grep -q 'ELF' || continue
        count=$((count + 1))
        "$readelf" -h "$f" | grep -q "Machine:.*$WANT_MACHINE" || { echo "  not $WANT_MACHINE: $f"; bad=1; continue; }
        dyn=$("$readelf" -d "$f" 2>/dev/null || true)
        if printf '%s\n' "$dyn" | grep -q 'R[UN]*PATH.*/Developer/Link'; then
            devlink="$devlink ${f#"$DESTDIR"}"
        fi
        if printf '%s\n' "$dyn" | grep -E '\((RPATH|RUNPATH)\)' |
                sed -E 's/.*\[(.*)\]$/\1/' | tr ':' '\n' | grep -vE '^(/System|/usr|/Developer/Link)(/|$)' | grep -q .; then
            echo "  RPATH/RUNPATH outside /System and /usr: $f"
            printf '%s\n' "$dyn" | grep -E '\((RPATH|RUNPATH)\)'
            bad=1
        fi
        for n in $(printf '%s\n' "$dyn" | sed -n 's/.*(NEEDED).*\[\(.*\)\]$/\1/p'); do
            found=
            for d in $libdirs; do
                [ -e "$d/$n" ] && { found=1; break; }
            done
            [ -n "$found" ] || [ -n "$(find "$SDK/System" "$DESTDIR" -name "$n" -print -quit)" ] && continue
            for r in $RUNTIME_ROOTS; do
                for d in lib usr/lib usr/lib/system usr/X11/lib; do
                    if [ -e "${r#*=}/$d/$n" ]; then
                        printf '%s\t/%s/%s\t%s\n' "${r%%=*}" "$d" "$n" "${f#"$DESTDIR"}" >> "$deps"
                        found=1
                        break 2
                    fi
                done
            done
            [ -n "$found" ] ||
                { echo "  ${f#"$DESTDIR"}: DT_NEEDED $n is in neither the SDK, the stage nor $RUNTIME_ROOTS"; bad=1; }
        done
    done < <(find "$DESTDIR" -type f -print0)
    note "$count ELF files are $WANT_MACHINE"
    if [ -s "$deps" ]; then
        note "libraries from packages outside the SDK (RUNTIME-DEPS-$T):"
        sort -u "$deps" | sed 's/^/        /'
    fi
    [ -z "$devlink" ] || note "RPATH/RUNPATH /Developer/Link (link-time only; nothing there at run time):$devlink"

    if grep -rIl -e "$SDK" -e "$BUILD" -e "$DESTDIR/" "$DESTDIR" 2>/dev/null | grep -q .; then
        echo "  files naming a build-host path:"
        grep -rIn -e "$SDK" -e "$BUILD" -e "$DESTDIR/" "$DESTDIR" | cut -c1-300 | sed 's/^/    /'
        bad=1
    fi

    while IFS= read -r -d '' f; do
        target=$(readlink "$f")
        case "$target" in
            "$SDK"*|"$BUILD"*|"$DESTDIR"*) echo "  symlink to a build-host path: ${f#"$DESTDIR"} -> $target"; bad=1; continue ;;
            /*) dir= ;;
            *) dir=$(dirname "${f#"$DESTDIR"}")/ ;;
        esac
        [ -e "$DESTDIR$dir$target" ] || [ -e "$SDK$dir$target" ] ||
            { echo "  dangling symlink: ${f#"$DESTDIR"} -> $target"; bad=1; }
    done < <(find "$DESTDIR" -type l -print0)

    [ "$bad" = 0 ] || fail "the staged desktop has problems (above)"
    note "no build-host paths; every DT_NEEDED resolves; no stray RPATH; no dangling symlink"
}

# What the desktop can't run without. A repository that loses files from its
# source still builds (nextbsd-theme #28 dropped the fonts and the step that
# installs its images, and every app then drew no text), so the stage is
# checked for them by name before anything is published.
REQUIRED_FILES="
/System/Library/Fonts/Inter-Regular.ttf
/System/Library/Fonts/Inter-Bold.ttf
/System/Library/Fonts/Inter-SemiBold.ttf
/System/Library/Fonts/JetBrainsMono-Regular.ttf
/System/Library/Fonts/JetBrainsMono-Bold.ttf
/System/Library/Themes/NextBSD.theme/NextBSD
/System/Library/Themes/NextBSD.theme/Resources/ThemeImages/Folder.png
/System/Library/Themes/NextBSD.theme/Resources/ThemeImages/common_Folder.png
/System/Library/Themes/NextBSD.theme/Resources/ThemeImages/NextBSDMenu.png
/System/Library/CoreServices/WindowServer
/System/Library/CoreServices/loginwindow.app/loginwindow
/System/Library/CoreServices/Workspace.app/Workspace
/System/Library/CoreServices/Dock.app/Dock
"

check_required() {
    comp "checking the desktop's required files"
    local f missing=
    for f in $REQUIRED_FILES; do
        [ -s "$DESTDIR$f" ] || missing="$missing $f"
    done
    [ -z "$missing" ] || fail "the stage is missing:$missing"
    note "$(echo $REQUIRED_FILES | wc -w | tr -d ' ') required files are there"
}

# Where each repository's things went: what it installed directly inside the
# folders the desktop shares with the system (one line per app, bundle, tool
# or library), and any other file it installed elsewhere.
write_locations() {
    local name out="$BUILD/LOCATIONS-$T"
    : > "$out"
    for name in $REPOS nextbsd-desktop; do
        [ -f "$FILES/$name.txt" ] || continue
        awk -v repo="$name" '
            BEGIN {
                n = split("/System/Library/CoreServices /System/Applications /System/Library/Bundles " \
                          "/System/Library/Themes /System/Library/Fonts /System/Library/InnerSpace " \
                          "/System/Library/DockExtras /System/Library/Tools /System/Library/LaunchDaemons " \
                          "/System/Library/LaunchAgents /System/Library/Preferences /usr/lib /usr/include " \
                          "/usr/libdata/pkgconfig /usr/libexec /etc/pam.d", c, " ")
                for (i = 1; i <= n; i++) shared[c[i]] = 1
            }
            {
                p = $0; parent = p; sub(/\/[^\/]*$/, "", parent)
                if (parent in shared) { print repo "\t" p; next }
                under = 0
                for (s in shared) if (index(p, s "/") == 1 || p == s) { under = 1; break }
                if (!under && system("test -f \"'"$DESTDIR"'" p "\"") == 0) print repo "\t" p
            }' "$FILES/$name.txt" >> "$out"
    done
    note "$(wc -l < "$out") entries in LOCATIONS-$T"
}

# Every staged path: path, type (f d l), octal mode, size, SHA-256 (files) or
# link target (symlinks), and the repository that installed it.
write_manifest() {
    local out="$BUILD/MANIFEST-$T.tsv" owners="$BUILD/owners-$T.tsv" name
    : > "$owners"
    for name in $REPOS nextbsd-desktop; do
        [ -f "$FILES/$name.txt" ] && sed "s#\$#\t$name#" "$FILES/$name.txt" >> "$owners"
    done
    (
        cd "$DESTDIR"
        find . -mindepth 1 -printf '%P\t%y\t%m\t%s\t%l\n' | LC_ALL=C sort
    ) | while IFS=$'\t' read -r p y m s l; do
        case "$y" in
            f) printf '/%s\tf\t%s\t%s\t%s\n' "$p" "$m" "$s" "$(sha256sum "$DESTDIR/$p" | cut -d' ' -f1)" ;;
            l) printf '/%s\tl\t%s\t%s\t%s\n' "$p" "$m" "$s" "$l" ;;
            *) printf '/%s\t%s\t%s\t-\t-\n' "$p" "$y" "$m" ;;
        esac
    done | awk -F'\t' 'NR == FNR { owner[$1] = $2; next } { print $0 "\t" (($1 in owner) ? owner[$1] : "-") }' \
        "$owners" - > "$out"
    note "MANIFEST-$T.tsv: $(grep -c . "$out") paths, $(awk -F'\t' '$2 == "f" { s += $4 } END { printf "%.1f MiB", s / 1048576 }' "$out") in files"
}

# ---- main --------------------------------------------------------------------

REPOS=$(awk '!/^#/ && NF >= 3 { print $1 }' "$ROOT/sources.lock" | tr '\n' ' ')
ALL_REPOS="$REPOS"
[ $# -gt 0 ] && REPOS="$*"

setup
total0=$(date +%s)
for repo in $REPOS; do
    case " $ALL_REPOS " in *" $repo "*) ;; *) fail "$repo is not in sources.lock" ;; esac
    comp "$repo"
    before="$FILES/.before-$repo"
    snapshot > "$before"
    t0=$(date +%s)
    ( "build_${repo//-/_}" ) 2>&1 | tee "$LOGS/$repo.log"
    t1=$(date +%s)
    snapshot | LC_ALL=C comm -13 "$before" - > "$FILES/$repo.txt"
    printf '%s\t%s\t%d\n' "$T" "$repo" "$((t1 - t0))" >> "$TIMES"
    note "$repo built in $((t1 - t0))s, installed $(grep -c . "$FILES/$repo.txt" || true) paths"
    collect_warnings "$repo"
done
total1=$(date +%s)
printf '%s\t%s\t%d\n' "$T" total "$((total1 - total0))" >> "$TIMES"

# BUILD-INFO: each repository's commit, then the GNUstep SDK's own (prefixed
# gnustep-sdk/) and where the SDK came from. It's installed as
# /System/Library/Preferences/nextbsd-desktop-BUILD-INFO.
if [ -f "$SDK/BUILD-INFO" ]; then
    sed 's#^#gnustep-sdk/#' "$SDK/BUILD-INFO" >> "$INFO"
fi
[ -n "${SDK_ORIGIN:-}" ] && printf 'gnustep-sdk\t%s\n' "$SDK_ORIGIN" >> "$INFO"
if [ "$REPOS" = "$ALL_REPOS" ]; then
    mkdir -p "$DESTDIR/System/Library/Preferences"
    install -m 644 "$INFO" "$DESTDIR/System/Library/Preferences/nextbsd-desktop-BUILD-INFO"
    echo /System/Library/Preferences/nextbsd-desktop-BUILD-INFO > "$FILES/nextbsd-desktop.txt"
    # The desktop's system-wide GNUstep defaults, from this repository's
    # System/Library/Preferences/GlobalDefaults (GSTheme NextBSD, ...).
    # libs-base merges each plist there below every user's own defaults.
    GD=/System/Library/Preferences/GlobalDefaults
    mkdir -p "$DESTDIR$GD"
    for f in "$ROOT$GD"/*.plist; do
        install -m 644 "$f" "$DESTDIR$GD/"
        echo "$GD/$(basename "$f")" >> "$FILES/nextbsd-desktop.txt"
    done
    grep -q '<key>GSTheme</key>' "$DESTDIR$GD/NSGlobalDomain.plist" || fail "no GSTheme in $GD/NSGlobalDomain.plist"
fi
[ ! -e "$DESTDIR/etc" ] || fail "the stage has /etc (it belongs to nextbsd-overlays): $(cd "$DESTDIR" && find etc -type f | tr '\n' ' ')"

check_stage
check_required
write_locations
write_manifest
comp "done in $((total1 - total0))s"
column -t "$TIMES" 2>/dev/null || cat "$TIMES"
column -t "$BUILD/warnings-$T.tsv" 2>/dev/null || cat "$BUILD/warnings-$T.tsv"
