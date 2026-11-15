#!/bin/bash
# app-object-detection-novnc-pcmanfm - an object-detection desktop behind the
# token gate. No native URL-token auth, so the nginx gate owns the one TCP port
# and everything behind it is a Unix socket in the session's private directory.
#
#   $OSP_APP_BIND:$OSP_APP_PORT     nginx gate     <- the only TCP listener
#   $OSP_APP_SOCK_DIR/app.sock      websockify + noVNC static files
#   $OSP_APP_SOCK_DIR/vnc.sock      Xvnc (RFB); no TCP port, no abstract socket
#   $OSP_APP_SOCK_DIR/dbus.sock     the desktop's session bus (thumbnails)
#
# This is app-novnc's entrypoint with three additions: the desktop
# (fluxbox + PCManFM + a terminal), its session bus, and the seeding of the
# desktop configuration into the home directory. The session is several
# processes, so the entrypoint stays and supervises them (web/supervise.sh)
# rather than exec'ing any one of them. bash, not sh, for `wait -n`.
set -eu
umask 077

# Bulk scratch directory. The scheduler usually hands us a TMPDIR pointing at a
# host path like /scratch/$USER/job.12345 -- and Apptainer does not necessarily
# bind it. Inside the container that path may not exist and the root
# filesystem is read-only, so `mkdir -p "$TMPDIR"` would die with "Read-only
# file system". Try the candidates in order and use the first one we can
# actually write to. Under the OSP run profile the app definition sets
# TMPDIR=<job directory>/tmp, which is bound and writable.
#
# Only bulk data goes here (caches, thumbnails, the detector's settings).
# Secrets, sockets and session state go in $OSP_APP_SOCK_DIR (created by
# session-env.sh under the private /tmp).
_pick_tmpdir() {
    for _d in "${TMPDIR:-}" /tmp "${HOME:-}"; do
        [ -n "$_d" ] || continue
        mkdir -p "$_d" 2>/dev/null || continue
        [ -w "$_d" ] || continue
        printf '%s' "$_d"
        return 0
    done
    return 1
}
_tmpdir_was="${TMPDIR:-}"
TMPDIR="$(_pick_tmpdir)" || {
    echo "[app] no writable scratch directory (tried TMPDIR, /tmp, HOME)" >&2
    exit 1
}
export TMPDIR
if [ -n "$_tmpdir_was" ] && [ "$_tmpdir_was" != "$TMPDIR" ]; then
    echo "[app] TMPDIR=$_tmpdir_was is not writable in this container; using $TMPDIR" >&2
fi

. /app/web/session-env.sh       # OSP_APP_PORT, OSP_APP_BIND, OSP_APP_TOKEN*, OSP_APP_SOCK_DIR
. /app/web/supervise.sh         # installs the cleanup trap before anything starts

: "${VNC_GEOMETRY:=1920x1080}"
# What the gate's /healthz asks websockify for: noVNC's client page.
export OSP_APP_HEALTH_PATH="${OSP_APP_HEALTH_PATH:-vnc.html}"

VNC_SOCK="$OSP_APP_SOCK_DIR/vnc.sock"
APP_SOCK="$OSP_APP_SOCK_DIR/app.sock"
DBUS_SOCK="$OSP_APP_SOCK_DIR/dbus.sock"

# The session bus, PCManFM's single-instance socket, dconf and friends put
# their sockets here; it belongs to this session only.
XDG_RUNTIME_DIR="$OSP_APP_SOCK_DIR/run"
mkdir -p "$XDG_RUNTIME_DIR"
export XDG_RUNTIME_DIR

# The working directory: where the user's images are, where the Files window
# and the terminals open, and where `detect` writes. Under the run profile it
# is the job directory; the home directory is a small private one that does
# not outlive the session.
OSP_WORK_DIR="$PWD"
export OSP_WORK_DIR

# HOME and XDG_CACHE_HOME: web/session-env.sh has already moved the image's
# /tmp defaults per session (a value the job set is kept). The detector's two
# settings directories get the same treatment here: while the image's /tmp
# fallbacks (Dockerfile) are still in effect, each session gets its own under
# $TMPDIR, beside the cache. Nothing secret is written to any of them.
_bulk="$TMPDIR/${OSP_APP_SOCK_DIR##*/}"
if [ "${MPLCONFIGDIR:-/tmp/matplotlib}" = /tmp/matplotlib ]; then
    MPLCONFIGDIR="$_bulk/matplotlib"
fi
if [ "${YOLO_CONFIG_DIR:-/tmp/Ultralytics}" = /tmp/Ultralytics ]; then
    YOLO_CONFIG_DIR="$_bulk/Ultralytics"
fi
export MPLCONFIGDIR YOLO_CONFIG_DIR
mkdir -p "$MPLCONFIGDIR" "$YOLO_CONFIG_DIR" 2>/dev/null || true

# GTK's accessibility bridge would start a second D-Bus daemon of its own
# (at-spi), outside the session bus below. Nothing in this desktop needs it.
export NO_AT_BRIDGE=1

# Every service below starts without OSP_APP_TOKEN in its environment
# (env -u): only the gate needs it, so the desktop, its terminals, the session
# bus and anything they or the user start never hold it.

# ---------------------------------------------------------------------------
# The session home.
#
# GTK, PCManFM and fluxbox all read their configuration from $HOME and there is
# no settings daemon in this image to tell them otherwise, so the desktop needs
# a writable home. Under the run profile (--contain) the home Apptainer
# provides is private, empty and small (~64 MB), and starts fresh every
# session. Under Docker it is /home/ospuser (mode 1777, from the Dockerfile).
#
# If neither is writable (--no-home, an unwritable mount) fall back to one in
# the session directory rather than letting every GTK app fail separately.
_pick_home() {
    for _d in "${OSP_HOME:-}" "${HOME:-}" "$OSP_APP_SOCK_DIR/home"; do
        [ -n "$_d" ] || continue
        mkdir -p "$_d" 2>/dev/null || continue
        [ -w "$_d" ] || continue
        printf '%s' "$_d"
        return 0
    done
    return 1
}
_home_was="${HOME:-}"
HOME="$(_pick_home)" || {
    echo "[app] no writable home directory for the desktop" >&2
    exit 1
}
export HOME
if [ -n "$_home_was" ] && [ "$_home_was" != "$HOME" ]; then
    echo "[app] HOME=$_home_was is not usable in this container; using $HOME" >&2
fi

# Seed the desktop configuration: GTK theme, PCManFM's desktop and thumbnail
# settings, the fluxbox menu, the Desktop launchers and the README.
#
# Copied in rather than baked into the home directory at build time: /app is
# inside the .sif and mounted read-only, and under Apptainer $HOME is not the
# image's. Under the run profile the home is empty at every start, so this
# runs every session.
#
# Nothing is ever overwritten. Where the home persists (a bind-mounted home, a
# reused Docker container), your gtk settings and your edited launchers
# survive a restart. Set OSP_SEED_DESKTOP=0 to add nothing at all -- the
# defaults are then whatever your home directory already has.
: "${OSP_SEED_DESKTOP:=1}"

_seed_home() {
    if [ "$OSP_SEED_DESKTOP" = "0" ]; then
        echo "[app] OSP_SEED_DESKTOP=0; leaving $HOME alone."
        return 0
    fi
    [ -d /app/desktop/skel ] || return 0
    if [ ! -w "$HOME" ]; then
        echo "[app] $HOME is not writable; desktop configuration not seeded." >&2
        return 0
    fi

    # The walks are redirected from a file rather than piped in. A `find |
    # while` runs the loop body in a subshell, where the counters below would
    # be incremented and then thrown away -- and the counts are the whole point
    # of the message at the end. Both walks are relative to skel, so no path is
    # ever built from a name we did not put there ourselves. The list is
    # session state, so it lives in the session directory.
    local _list="$OSP_APP_SOCK_DIR/seed-list" _d _f _rel _new=0 _kept=0

    # -type d first, so the destinations exist before the files arrive.
    (cd /app/desktop/skel && find . -mindepth 1 -type d -print) > "$_list"
    while IFS= read -r _d; do
        mkdir -p "$HOME/${_d#./}" 2>/dev/null || true
    done < "$_list"

    (cd /app/desktop/skel && find . -type f -print) > "$_list"
    while IFS= read -r _f; do
        _rel="${_f#./}"
        if [ -e "$HOME/$_rel" ]; then
            _kept=$((_kept + 1))
            continue
        fi
        cp "/app/desktop/skel/$_rel" "$HOME/$_rel" 2>/dev/null || continue
        chmod u+w "$HOME/$_rel" 2>/dev/null || true
        _new=$((_new + 1))
    done < "$_list"
    rm -f "$_list"

    # PCManFM will not launch a .desktop file on the desktop unless it is
    # executable -- it shows it as a text file instead. (Even then it asks what
    # to do with it, unless quick_exec=1 is set in libfm.conf; both are
    # required.)
    chmod u+x "$HOME"/Desktop/*.desktop 2>/dev/null || true

    echo "[app] desktop config: ${_new} file(s) seeded, ${_kept} already yours"
    if [ "$_kept" -gt 0 ]; then
        # Only a home that outlives the session gets here. Never overwriting
        # is what protects a user's edits, but it also means a home carried
        # over from an older image keeps that image's defaults.
        echo "[app] existing files are never overwritten. To take this image's"
        echo "[app] defaults instead, remove them and restart:"
        echo "[app]   rm -rf ~/.config/pcmanfm ~/.config/gtk-3.0 ~/.fluxbox/menu ~/Desktop"
    fi
    return 0
}
_seed_home

# Versions of this image before the fix seeded a libfm.conf into the pcmanfm
# profile directory, where libfm never looks for it. Only a home carried over
# from such a version has it.
if [ -f "$HOME/.config/pcmanfm/default/libfm.conf" ]; then
    echo "[app] note: ~/.config/pcmanfm/default/libfm.conf is left over from an" >&2
    echo "[app] older image. libfm does not read that path; the settings now come" >&2
    echo "[app] from /etc/xdg/libfm/libfm.conf. The file is safe to delete." >&2
fi

mkdir -p "$HOME/Desktop" 2>/dev/null || true

# X only creates /tmp/.X11-unix when it is running as root, which we never
# are. Under Docker the Dockerfile pre-creates it; under Apptainer /tmp is the
# session's own (with the run profile) or the node's (without), and this is
# the line that matters. 1777 explicitly: umask 077 would otherwise make it
# 0700, and on a node-shared /tmp that would lock every other user's X server
# out of it.
[ -d /tmp/.X11-unix ] || mkdir -m 1777 /tmp/.X11-unix 2>/dev/null || true
# If another user made it with a narrower mode, every display would fail and
# the walk below would end in a misleading "no free X display". Say why now.
if [ ! -w /tmp/.X11-unix ]; then
    echo "[novnc] /tmp/.X11-unix is not writable for uid $(id -u); the X server cannot start." >&2
    ls -ld /tmp/.X11-unix >&2 2>/dev/null || true
    exit 1
fi

# The MIT-MAGIC-COOKIE, in the session directory (0600 under umask 077).
XAUTHORITY="$OSP_APP_SOCK_DIR/Xauthority"
export XAUTHORITY
: > "$XAUTHORITY"
XAUTH_COOKIE="$(od -An -tx1 -N16 /dev/urandom | tr -d ' \n')"

# Try one display number. Returns 0 and sets VNC_DISPLAY on success, with Xvnc
# registered as the first (stopped-last) critical service.
#
# Xvnc listens for RFB only on $VNC_SOCK (0600, in a 0700 directory):
# -rfbport -1 turns the TCP listener off. -nolisten tcp and -nolisten local
# turn off the X server's own TCP and *abstract* sockets; the abstract one
# lives in the network namespace, which every session on the node shares, so
# a private /tmp would not hide it. X clients use the filesystem socket
# /tmp/.X11-unix/X<n> and the cookie.
#
# -SecurityTypes None and no VNC password: there is no socket anyone outside
# this session can reach, and a password file would be readable by the same
# uid that could read the token anyway. The gate is the authentication.
try_display() {
    local d=":$1" i
    xauth -f "$XAUTHORITY" add "$d" . "$XAUTH_COOKIE" 2>/dev/null || return 1
    rm -f "$VNC_SOCK"

    osp_start Xvnc -- env -u OSP_APP_TOKEN Xvnc "$d" \
        -rfbunixpath "$VNC_SOCK" -rfbunixmode 0600 \
        -rfbport -1 \
        -nolisten tcp -nolisten local \
        -SecurityTypes None \
        -geometry "$VNC_GEOMETRY" \
        -depth 24 \
        -auth "$XAUTHORITY" \
        -AlwaysShared \
        -desktop "app-object-detection-novnc-pcmanfm"
    local pid=$OSP_PID

    # Wait for the display and the RFB socket rather than sleeping and hoping.
    # Bail out early if Xvnc has already died -- the "display taken" case.
    for (( i = 0; i < 100; i++ )); do
        if DISPLAY="$d" xdpyinfo >/dev/null 2>&1 && [ -S "$VNC_SOCK" ]; then
            VNC_DISPLAY="$d"
            osp_register critical Xvnc "$pid" Xvnc
            return 0
        fi
        osp_alive "$pid" || break
        sleep 0.1
    done
    kill -TERM -- "-$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
    return 1
}

# X display numbers are global to the node unless /tmp is private: the lock
# (/tmp/.X<n>-lock) and the socket (/tmp/.X11-unix/X<n>) live in /tmp. Walk
# :1, :2, ... until one takes. Under the run profile the first one always
# does. Setting VNC_DISPLAY explicitly demands that exact number.
if [ -n "${VNC_DISPLAY:-}" ]; then
    try_display "${VNC_DISPLAY#:}" || {
        echo "[novnc] display ${VNC_DISPLAY} is not available" >&2
        exit 1
    }
else
    _n=1
    until try_display "$_n"; do
        _n=$((_n + 1))
        [ "$_n" -le 64 ] || {
            echo "[novnc] no free X display between :1 and :64" >&2
            exit 1
        }
    done
fi

export DISPLAY="$VNC_DISPLAY"
echo "[novnc] Xvnc ready on $VNC_DISPLAY (rfb unix:$VNC_SOCK)"

# The session bus. tumbler -- the thumbnailer that puts pictures on the file
# icons instead of generic placeholders -- is D-Bus-activated and does nothing
# without one; GTK's file chooser uses it too. On a filesystem socket in the
# session directory, never `dbus-launch`'s default (`unix:tmpdir=/tmp`), which
# can be an *abstract* socket: those live in the network namespace that every
# session on the node shares, and D-Bus lets in any process of the same uid.
# Started after DISPLAY and the variables above are set, because services it
# activates take their environment from it. A helper: without it the desktop
# still works, with generic icons.
osp_spawn helper dbus dbus-daemon -- env -u OSP_APP_TOKEN dbus-daemon --session --nofork \
    --address="unix:path=$DBUS_SOCK"
for (( _i = 0; _i < 50; _i++ )); do
    [ -S "$DBUS_SOCK" ] && break
    sleep 0.1
done
# The address is exported even if the bus did not come up: with no address at
# all, GLib and libdbus would "autolaunch" a bus of their own through
# dbus-launch, on exactly the kind of socket avoided above.
DBUS_SESSION_BUS_ADDRESS="unix:path=$DBUS_SOCK"
export DBUS_SESSION_BUS_ADDRESS
if [ -S "$DBUS_SOCK" ]; then
    echo "[desktop] session bus on unix:$DBUS_SOCK (thumbnails enabled)"
else
    echo "[desktop] no session bus; thumbnails will be generic icons" >&2
fi

# The window manager, then the desktop, then the two windows the user needs.
#
# fluxbox first so that everything opened after it gets a title bar. It is
# this desktop's session leader: quitting it -- the Log out icon, the menu's
# Log out, Ctrl+Alt+Delete -- is a normal log-out and ends the session with
# status 0. There is no session manager in this desktop, so the window
# manager stands in. Its own
# chatter (on a fresh home it lists every default it fills in, about 150
# lines, every session under the run profile) goes to a file in the session
# directory, not the job log. end-session finds it through leader.pid.
osp_spawn leader fluxbox fluxbox -- env -u OSP_APP_TOKEN fluxbox -log "$OSP_APP_SOCK_DIR/fluxbox.log"
printf '%s\n' "$OSP_PID" > "$OSP_APP_SOCK_DIR/leader.pid"

# PCManFM draws the wallpaper and the Desktop icons. It is also the single
# instance every later `pcmanfm` hands its window to, over a socket in
# $XDG_RUNTIME_DIR; so the file window below, and every one the user opens,
# belongs to this process.
osp_spawn helper desktop pcmanfm -- env -u OSP_APP_TOKEN pcmanfm --desktop --profile default

# Wait for that socket before asking for a window, so the request is handed
# over instead of starting a second instance.
for (( _i = 0; _i < 50; _i++ )); do
    compgen -G "$XDG_RUNTIME_DIR/pcmanfm-socket-*" >/dev/null && break
    sleep 0.1
done

# Open a file window. The file manager's command normally hands the window to
# the instance already running and exits at once, so it is a one-off, not a
# service. If it is still running after a few seconds it found no instance to
# hand over to and is the file manager itself: then it is supervised like the
# other helpers, so the session's end stops it too.
_files_window() {
    local pid i
    osp_start files -- env -u OSP_APP_TOKEN "$@"
    pid=$OSP_PID
    for (( i = 0; i < 30; i++ )); do
        if ! osp_alive "$pid"; then
            wait "$pid" 2>/dev/null || true
            return 0
        fi
        sleep 0.1
    done
    osp_register helper files "$pid"
}

# The file window and the terminal open on the working directory, not on
# $HOME: under the run profile $HOME holds the configuration and the working
# directory holds the user's images, which are what they came for.
_files_window pcmanfm "$OSP_WORK_DIR"

osp_spawn helper terminal xfce4-terminal -- env -u OSP_APP_TOKEN xfce4-terminal --disable-server \
    --title="Object detection" \
    --working-directory="$OSP_WORK_DIR" \
    --geometry=104x30+90+70 \
    --command=detect-shell

echo "[desktop] working directory: $OSP_WORK_DIR (save your work here)"
echo "[desktop] home             : $HOME (settings only; under the run profile it is"
echo "[desktop]                    private to this session and empty at the next start)"
echo "[app]     model            : ${APP_MODEL:-/app/yolo11n.pt}"
echo "[app]     run detection with: detect --open <image>"

# websockify serves the noVNC client AND bridges the websocket to Xvnc, Unix
# socket to Unix socket. Everything the browser fetches comes through the gate.
# It is critical: without it the gate would answer 502 for the rest of the
# session.
#
# Its TMPDIR is the session directory, not the job directory: websockify is
# Python and uses multiprocessing, whose default start method since Python
# 3.14 is a "forkserver" listening on a Unix socket in Python's temporary
# directory -- which follows TMPDIR, the job directory on shared storage under
# the run profile (plan NEW-17). websockify keeps no bulk data, so nothing is
# lost by keeping its temporary files in the private /tmp.
osp_spawn critical websockify websockify -- env -u OSP_APP_TOKEN TMPDIR="$OSP_APP_SOCK_DIR" websockify \
    --web=/usr/share/novnc \
    --unix-listen="$APP_SOCK" --unix-listen-mode=0600 \
    --unix-target="$VNC_SOCK"

# Do not start the gate until websockify is accepting connections, or the first
# request gets a 502.
_i=0
until [ -S "$APP_SOCK" ] && python3 -c '
import socket, sys
s = socket.socket(socket.AF_UNIX)
s.settimeout(1)
s.connect(sys.argv[1])' "$APP_SOCK" 2>/dev/null; do
    _i=$((_i + 1))
    [ "$_i" -lt 100 ] || { echo "[novnc] websockify did not start" >&2; exit 1; }
    sleep 0.1
done
echo "[novnc] websockify on unix:$APP_SOCK -> unix:$VNC_SOCK"

# The gate. token-gate.sh execs nginx, so the registered pid is nginx's.
osp_spawn critical gate nginx -- /app/web/token-gate.sh

osp_supervise
