# The shared session files (web/: the session contract, the token gate, the
# supervisor) come from app-template's kit image rather than a copy kept in
# this repo: a fix to them reaches this image by bumping this line.
FROM ghcr.io/onescienceplace/app-kit:1.1.0@sha256:8be57aac17696826c15692cf256dc69681ecf7b6137021ebeef09e4776118368 AS kit

FROM ubuntu:26.04

ENV DEBIAN_FRONTEND=noninteractive

# Three groups, kept separate so it is obvious what each one is for.
#
# 1. The VNC stack, identical to app-novnc. feh is not optional scenery:
#    fluxbox's default style carries a `background:` directive, which makes it
#    shell out to fbsetbg, which needs one of feh / Esetroot / display /
#    hsetroot to exist. With none of them installed fbsetbg pops its complaint
#    up as an xmessage dialog ON THE DESKTOP -- the first thing a user sees.
#    bash is the entrypoint's shell (web/supervise.sh needs `wait -n`); it is
#    in the base image already and listed so that stays true.
#
# 2. The desktop: PCManFM draws the background and the icons AND provides the
#    file windows; tumbler is what puts image thumbnails in them (without it
#    every photo is a generic icon, which defeats the purpose); ristretto is
#    the viewer; dbus-daemon runs the session bus that tumbler and GTK's file
#    chooser talk over (the entrypoint starts it on a socket in the session
#    directory; dbus-x11 stays because packages here expect it).
#    An icon theme is not decoration either -- GTK apps with no icon theme
#    installed render as unlabelled blank squares. Nor is mousepad: with no
#    application on the system claiming text/plain, double-clicking a .txt or
#    the detections.json this app just wrote opens a "choose an application"
#    dialog with nothing useful in it. zenity is there for one dialog only --
#    the confirmation on Log out, which throws away every unsaved window and
#    stops the container, and so should not happen on a stray double-click.
#
# 3. Python, for the detector. Same CPU-only torch and ultralytics pins as
#    app-object-detection. libgl1/libglib2.0-0: opencv-python links libGL.
RUN apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates bash \
        tigervnc-standalone-server tigervnc-common xauth \
        novnc websockify \
        fluxbox xterm x11-utils \
        feh \
        nginx-light gettext-base \
        pcmanfm ristretto xfce4-terminal mousepad \
        tumbler tumbler-plugins-extra \
        dbus-daemon dbus-x11 shared-mime-info xdg-utils desktop-file-utils zenity \
        adwaita-icon-theme papirus-icon-theme gnome-themes-extra \
        librsvg2-common fonts-dejavu-core \
        python3 python3-venv \
        libgl1 libglib2.0-0 \
    && rm -rf /var/lib/apt/lists/*

# Fail the build, not the session, if a package lacks what the entrypoint
# depends on (what the gate and the supervisor need is checked by the kit's
# check-deps.sh, once web/ is in place below):
#   - Xvnc must listen for RFB on a Unix socket (rfbunixpath). TigerVNC's help
#     lists its parameters without the leading dash.
#   - websockify must listen on a Unix socket (--unix-listen).
#   - dbus-daemon runs the session bus on a socket the entrypoint names.
RUN set -e; \
    Xvnc -help 2>&1 | grep -q rfbunixpath \
        || { echo "Xvnc has no rfbunixpath option" >&2; exit 1; }; \
    websockify --help 2>&1 | grep -q -- '--unix-listen' \
        || { echo "websockify has no --unix-listen option" >&2; exit 1; }; \
    command -v dbus-daemon >/dev/null \
        || { echo "no dbus-daemon" >&2; exit 1; }; \
    echo "[build] Xvnc, websockify and dbus-daemon support what the entrypoint needs"

WORKDIR /app

# noVNC's landing page is vnc.html and it needs query parameters to connect on
# its own. The gate strips the query string after the token exchange, so bake
# the parameters into an index page instead of relying on the URL.
RUN printf '%s\n' \
      '<!doctype html><title>Object detection desktop</title>' \
      '<meta http-equiv="refresh" content="0; url=vnc.html?autoconnect=true&resize=remote&reconnect=true">' \
      > /usr/share/novnc/index.html

# The X server needs this to exist before it can create its socket, and it
# will not create it itself as a non-root user.
RUN mkdir -p /tmp/.X11-unix && chmod 1777 /tmp/.X11-unix

# A venv rather than `pip install --break-system-packages`: Ubuntu marks its
# system Python externally-managed (PEP 668), and a venv keeps the detector's
# pinned wheels from arguing with the apt-installed desktop's python bindings.
# Putting it first on PATH makes `python3` mean the venv's for the rest of the
# build; `detect` names /opt/venv/bin/python3 explicitly rather than trusting
# whatever PATH a user's shell ends up with.
RUN python3 -m venv /opt/venv
ENV PATH=/opt/venv/bin:$PATH

# CPU-only torch, installed before ultralytics so that ultralytics finds its
# torch/torchvision requirement already satisfied. PyPI's default torch wheel
# for Linux is the CUDA build: ~2.5 GB in the image, and every byte of it ends
# up in the .sif that gets copied to every compute node.
#
# For a GPU demo, delete this step and change the base image to
#   FROM nvidia/cuda:13.3.0-runtime-ubuntu24.04
# plus the desktop packages above -- pip will then pull the CUDA build of torch
# as an ordinary dependency of ultralytics.
RUN pip install --no-cache-dir \
        --index-url https://download.pytorch.org/whl/cpu \
        torch==2.13.0 torchvision==0.28.0

# Everything else is installed at build time too. Nothing may be fetched at
# run time: a .sif is read-only and compute nodes are often offline.
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

# The container user, created before the ENV block below so that HOME points at
# a directory that already exists during the rest of the build.
#
# 1777 rather than 0755: under `docker run --user <uid>` and under Apptainer the
# runtime uid is whatever the caller happens to be, not 1000, and the entrypoint
# has to be able to seed the desktop configuration into this directory. The
# sticky bit keeps one user from deleting another's files.
ARG OSP_UID=1000
# Ubuntu's base image has shipped a placeholder `ubuntu` account at uid 1000
# since 24.04, so a plain `useradd --uid 1000` dies with "UID 1000 is not
# unique". Debian-based images carry no such account, which is why
# app-object-detection-jupyter needs none of this.
#
# Take the uid over rather than moving ospuser up to 1001. 1000 is the first
# human-user id on a Linux host, so it is the one `--user "$(id -u)"` usually
# lines up with, and the placeholder account has no purpose in this image.
#
# The name is read out of the passwd database rather than assumed to be
# `ubuntu`, and the result is verified rather than the exit status trusted:
# `userdel -r` returns 12 when there is no mail spool to remove, which is the
# normal case in a container and is not a failure.
RUN set -eu; \
    existing="$(getent passwd ${OSP_UID} | cut -d: -f1)"; \
    if [ -n "$existing" ]; then \
        echo "[build] removing placeholder account '$existing' holding uid ${OSP_UID}"; \
        userdel -r "$existing" >/dev/null 2>&1 || true; \
        if getent passwd ${OSP_UID} >/dev/null; then \
            echo "[build] could not free uid ${OSP_UID}" >&2; \
            exit 1; \
        fi; \
    fi; \
    if getent group ${OSP_UID} >/dev/null; then \
        groupdel "$(getent group ${OSP_UID} | cut -d: -f1)"; \
    fi; \
    groupadd --gid ${OSP_UID} ospuser; \
    useradd --create-home --uid ${OSP_UID} --gid ${OSP_UID} --shell /bin/bash ospuser; \
    chmod 1777 /home/ospuser

# A .sif is mounted read-only, so every library scratch path has a fallback in
# /tmp and the model weights are baked in at a fixed absolute path. APP_MODEL
# is the same variable run.py reads, with the same default, so this image and
# the batch app resolve to identical weights.
#
# The /tmp fallbacks are never used as they are: at session start
# web/session-env.sh (XDG_CACHE_HOME) and entrypoint.sh (MPLCONFIGDIR,
# YOLO_CONFIG_DIR) move each one still in effect to a directory of the
# session's own under $TMPDIR. XDG_RUNTIME_DIR is not set here: the entrypoint
# puts it inside the session's private directory.
ENV HOME=/home/ospuser \
    XDG_CACHE_HOME=/tmp/.cache \
    MPLCONFIGDIR=/tmp/matplotlib \
    YOLO_CONFIG_DIR=/tmp/Ultralytics \
    APP_MODEL=/app/yolo11n.pt

# Downloaded at build time into WORKDIR, i.e. /app/yolo11n.pt = $APP_MODEL.
# Swap for yolo26n.pt (newest generation) or a larger size (s/m/l/x) freely --
# the API is identical, only the weights file changes. Keep it in step with
# app-object-detection so the two produce comparable results.
RUN python3 -c "from ultralytics import YOLO; YOLO('yolo11n.pt')"

# VNC has no URL-token auth, so the nginx gate owns OSP_APP_PORT and
# websockify sits behind it on a Unix socket in the session directory.
# OSP_APP_TOKEN_NAME is deliberately NOT an ENV here. Its value is a parameter
# name, not a secret, but BuildKit's SecretsUsedInArgOrEnv check matches on
# the word TOKEN and warns. web/session-env.sh already defaults it to `token`.
# OSP_APP_BIND defaults to 127.0.0.1 in web/session-env.sh; a local
# `docker run -p` needs -e OSP_APP_BIND=0.0.0.0.
ENV OSP_APP_PORT=6080 \
    VNC_GEOMETRY=1920x1080
# VNC_DISPLAY is deliberately unset: entrypoint.sh walks :1, :2, ... for a
# free one, because display numbers are global to the node when /tmp is
# shared. Set it at run time only to demand a specific number.
EXPOSE 6080

# /etc/passwd group-writable so entrypoint can add an entry for the runtime uid
# when run as `--user "$(id -u):0"`. Harmless otherwise, and read-only under
# Apptainer, which supplies the entry itself.
RUN chmod g=u /etc/passwd /etc/group

COPY run.py /app/run.py
COPY bin/ /app/bin/
COPY desktop/ /app/desktop/
COPY --from=kit /app/web/ /app/web/
RUN /app/web/check-deps.sh
COPY entrypoint.sh /app/entrypoint.sh

# The wallpaper is generated, not committed: Pillow is already here as an
# ultralytics dependency, and a repo of shell and Dockerfiles has no business
# carrying a 2 MB PNG.
RUN python3 /app/desktop/make-wallpaper.py /app/desktop/wallpaper.png

# `detect` on PATH, and the launchers where the desktop looks for them.
# Symlinks rather than copies for the commands, so /app stays the one place
# anything of ours actually lives; real copies for the .desktop files, because
# update-desktop-database builds a cache keyed on this directory.
RUN ln -s /app/bin/detect       /usr/local/bin/detect \
    && ln -s /app/bin/detect-shell /usr/local/bin/detect-shell \
    && ln -s /app/bin/end-session  /usr/local/bin/end-session \
    && cp /app/desktop/applications/*.desktop /usr/share/applications/ \
    && cp /app/desktop/mimeapps.list /usr/share/applications/mimeapps.list \
    && mkdir -p /etc/xdg/libfm \
    && cp /app/desktop/libfm.conf /etc/xdg/libfm/libfm.conf \
    && chmod 0644 /usr/share/applications/osp-*.desktop \
                  /usr/share/applications/mimeapps.list \
                  /etc/xdg/libfm/libfm.conf \
    && update-desktop-database /usr/share/applications
# Both of those files are system defaults, not seeded into the home directory,
# so they hold with OSP_SEED_DESKTOP=0, under any $HOME, and in a home carried
# over from an older image. A user changing either through the GUI gets their
# own copy under ~/.config, which is read afterwards and wins.
#
# /etc/xdg/libfm/libfm.conf is the path libfm actually reads:
# fm_config_load_from_file(cfg, NULL) hardcodes the name "libfm/libfm.conf" and
# searches XDG_CONFIG_DIRS then XDG_CONFIG_HOME. A libfm.conf sitting in
# ~/.config/pcmanfm/<profile>/ next to pcmanfm.conf is never opened -- which is
# why quick_exec, the thumbnail settings and `terminal=` all appeared to be set
# and none of them took effect.
#
# update-desktop-database builds mimeinfo.cache from the MimeType= lines, which
# is what populates "Open With". mimeapps.list only picks the winner.
# That chmod is not redundant with the `chmod -R a+rX /app` below: these copies
# live outside /app, so the recursive fix never reaches them, and a .desktop
# file the runtime user cannot read is a launcher that silently does not exist.

# Explicit modes. COPY preserves the build context's permissions, so a checkout
# made under a restrictive umask yields 0600/0700 files that the runtime user --
# `docker run --user`, or any user at all under Apptainer -- cannot even read.
# Git only tracks the exec bit, so this is not something the repo can guarantee.
# The kit's files arrive with their modes set.
RUN chmod -R a+rX /app /opt/venv \
    && chmod 0755 /app/entrypoint.sh \
                  /app/bin/detect /app/bin/detect-shell /app/bin/end-session \
                  /app/desktop/make-wallpaper.py

# No setuid or setgid files (plan S-7). /etc/passwd is group-writable above,
# and under Docker without no-new-privileges, that plus a setuid `su` is a way
# to root inside the container. Apptainer mounts the image nosuid anyway. Keep
# this after the last package install; the build fails if any are left.
RUN find / -xdev -perm /6000 -type f -exec chmod a-s {} + || true; \
    _left="$(find / -xdev -perm /6000 -type f 2>/dev/null | head -5)"; \
    if [ -n "$_left" ]; then printf '%s\n' "$_left" >&2; \
        echo "setuid/setgid files remain (above)" >&2; exit 1; fi

# The working directory is ospuser's home: it is where the desktop opens, where
# the Files window starts, and where run.py reads and writes. Docker gets it
# from WORKDIR; Apptainer ignores WORKDIR and uses the caller's directory,
# which comes to the same thing -- the session's working directory either way.
WORKDIR /home/ospuser
USER ospuser

ENTRYPOINT ["/app/entrypoint.sh"]
