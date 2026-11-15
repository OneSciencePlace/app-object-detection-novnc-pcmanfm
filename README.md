# app-object-detection-novnc-pcmanfm

The desktop version of
[`app-object-detection`](https://github.com/OneSciencePlace/app-object-detection).
Same `run.py`, same weights, same outputs — but you get a terminal to run it
from and a file browser to look at the results in, both in a browser tab.

The desktop is fluxbox plus PCManFM: one package for the background, the
icons and the file windows, and five ini files of configuration. (An XFCE
version, `app-object-detection-novnc-xfce`, was dropped in 2026-11: a full
session manager was more to configure and secure than it was worth here.)

```
app-object-detection          app-object-detection-jupyter      this repo
run.py --image photo.jpg  ──▶  a notebook, cell by cell    ──▶  a desktop:
     one shot, batch                with a slider               detect + Files
              │                            │                          │
              └──── yolo11n.pt, <stem>_detected.jpg, detections.json ──┘
```

It is built on `app-novnc`: VNC has no URL-token auth, so the nginx gate owns
the one TCP port and everything behind it is a Unix socket in the session's
private directory.

```
browser ──https──▶ Satellite ──ssh tunnel──▶ 127.0.0.1:OSP_APP_PORT   nginx gate
                                                    │  cookie / 403
                                                    ▼
                                    $OSP_APP_SOCK_DIR/app.sock        websockify
                                                    │  + noVNC static files
                                                    ▼
                                    $OSP_APP_SOCK_DIR/vnc.sock        Xvnc + fluxbox
                                                                      + PCManFM + ristretto
```

## Contents

| File | Purpose |
|---|---|
| `Dockerfile` | The image. Weights at `/app/yolo11n.pt`; user `ospuser`, home `/home/ospuser`. |
| `run.py` | The program — **byte-for-byte** `app-object-detection`'s. |
| `bin/detect` | The wrapper users actually type. Adds a bare-filename form and `--open`. |
| `bin/detect-shell` | What the desktop's *Object detection* launcher opens: a terminal that has already printed the help. |
| `bin/end-session` | Logs out: asks the session leader (fluxbox) to quit; the supervisor then stops everything else. |
| `requirements.txt` | Pinned Python deps, held in step with the batch app. |
| `desktop/skel/` | Desktop configuration seeded into the session home at startup. |
| `desktop/applications/` | The `.desktop` launchers, installed to `/usr/share/applications`. |
| `desktop/make-wallpaper.py` | Generates the background at build time. |
| `entrypoint.sh` | The image ENTRYPOINT. Starts Xvnc, the session bus, the desktop, websockify and the gate, and supervises them. |

`web/` (the session contract, the token gate, the supervisor) is not in this
repository: the build copies it from the kit image named at the top of the
`Dockerfile` (`ghcr.io/onescienceplace/app-kit`), pinned by digest.
| `.github/workflows/build-and-push.yml` | Build + push both artifacts. App-agnostic — copy as-is. |

## Run it

The token is never put on a command line: `ps` shows command lines to every
user on a node. Pass it through the environment.

```bash
export OSP_APP_TOKEN=$(openssl rand -hex 32)

# Docker (local). -e OSP_APP_TOKEN with no "=value" copies it from your
# environment. OSP_APP_BIND=0.0.0.0 because `-p` cannot reach a container's
# loopback; the host side is still published on 127.0.0.1 only.
docker run --rm --user "$(id -u):$(id -g)" \
  -p 127.0.0.1:6080:6080 -v "$PWD:/home/ospuser" \
  -e OSP_APP_PORT=6080 -e OSP_APP_BIND=0.0.0.0 -e OSP_APP_TOKEN \
  ghcr.io/onescienceplace/app-object-detection-novnc-pcmanfm:latest

# Apptainer, under the OSP interactive run profile.
# APPTAINERENV_<NAME> reaches the container as <NAME>, even with --cleanenv.
apptainer pull oras://ghcr.io/onescienceplace/app-object-detection-novnc-pcmanfm-sif:latest   # production pins <version>@sha256:<digest>
export APPTAINERENV_OSP_APP_TOKEN="$OSP_APP_TOKEN"
apptainer run \
  --contain --pid --ipc --cleanenv --no-mount bind-paths,cwd \
  --pwd "$PWD" --bind "$PWD:$PWD" \
  --env OSP_APP_PORT=6080 --env TMPDIR="$PWD/tmp" \
  app-object-detection-novnc-pcmanfm-sif_latest.sif
```

Through OSP, open `https://<session-label>.<sat-id>.sat.<domain>/?token=<token>`.
Locally, `http://localhost:6080/?token=$OSP_APP_TOKEN` (Docker), or forward the
port first for Apptainer on a cluster node: `ssh -L 6080:127.0.0.1:6080 <node>`.
A desktop comes up with a Files window and a terminal already open on your
working directory.

| Variable | Default | Meaning |
|---|---|---|
| `OSP_APP_PORT` | `6080` | the one TCP port — the nginx gate |
| `OSP_APP_BIND` | `127.0.0.1` | address the gate listens on; `0.0.0.0` only for local `docker run -p` |
| `OSP_APP_TOKEN` | generated | per-session secret; environment only, never a command-line argument |
| `OSP_APP_TOKEN_NAME` | `token` | query parameter the token arrives in (`[A-Za-z0-9_]`) |
| `VNC_DISPLAY` | auto | X display number. Unset by default — see below |
| `VNC_GEOMETRY` | `1920x1080` | desktop size |
| `OSP_APP_HEALTH_PATH` | `vnc.html` | what the gate's `/healthz` asks websockify for |
| `APP_MODEL` | `/app/yolo11n.pt` | the baked-in weights; same variable `run.py` reads |
| `OSP_HOME` | `$HOME` | where the desktop configuration is seeded |
| `OSP_SEED_DESKTOP` | `1` | set `0` to add nothing to the home directory |

`OSP_APP_SOCK_DIR` is set by `web/session-env.sh`, never by the caller: a fresh
`0700` directory under `/tmp` that holds every secret, socket and rendered
config of the session. `OSP_WORK_DIR` is set by the entrypoint: the working
directory the session started in, where the Files window, the terminals and
`detect` work.

## `detect`

The command the desktop exists to make easy:

```bash
detect photo.jpg                    # the short form
detect --open photo.jpg             # ...and show the result when it finishes
detect photo.jpg --conf 0.4         # run.py's own flags, unchanged
detect --image photo.jpg --output-dir results
detect --help
```

It writes exactly what the batch app writes, into the current directory:
`<stem>_detected.jpg` and `detections.json`.

The wrapper adds precisely two things — the bare-filename shorthand and
`--open` — and hands everything else to `run.py` untouched. So a command you
worked out here runs unchanged against the batch container:

```bash
apptainer run app-object-detection-sif_latest.sif --image photo.jpg --conf 0.4
```

`--open` starts ristretto on the annotated image. Ristretto loads the whole
containing folder into its thumbnail strip, so the original is one arrow key
away at the same zoom — which is the comparison worth making, and the reason
the viewer is ristretto rather than the `feh` already in the base image.

## The desktop

fluxbox is the window manager, unchanged from `app-novnc`. On top of it:

- **PCManFM** does two jobs: `pcmanfm --desktop` draws the wallpaper, the
  Desktop icons and the right-click menu; a second invocation provides the file
  windows. The icon view has thumbnails on, so `photo.jpg` and
  `photo_detected.jpg` sit next to each other and the difference is visible
  before you open either.
- **tumbler** is what makes those thumbnails exist. It is D-Bus-activated,
  which is why `entrypoint.sh` starts a session bus, on a socket in the
  session directory (see *Design notes*). Without one you get generic file
  icons and no explanation.
- **ristretto** is the image viewer and **mousepad** the text editor, wired to
  every image and text type through `/usr/share/applications/mimeapps.list`.
  An editor is not a luxury: with no application on the system claiming
  `text/plain`, double-clicking a `.txt` — or the `detections.json` the app
  just wrote — opens a "choose an application" dialog with nothing useful in
  it.
- **`quick_exec=1`** in `/etc/xdg/libfm/libfm.conf`. Without it,
  double-clicking a launcher on the desktop pops *This file is an executable…
  Open / Execute / Cancel* instead of starting the application. libfm's name
  for it is "don't ask user for action on executable launch", and it is off by
  default. It is the only switch for this, and the consequence is that an
  executable script double-clicked in a file window now runs rather than
  asking — which is what every other desktop does. Making a launcher
  executable (the entrypoint does) is necessary but not sufficient; both are
  required.
- **xfce4-terminal**, started `--disable-server` so it does not depend on the
  session bus at all. `xterm` is still installed as a fallback.
- **Papirus-Dark** icons and Adwaita GTK, with animations off: every frame of a
  fade is a full framebuffer update pushed down the websocket.

Six launchers ship in `/usr/share/applications` and are seeded onto the
Desktop: *Files*, *Terminal*, *Image Viewer*, *Text Editor*, *Object detection*
(which opens `detect-shell` — a terminal that prints the help and lists the
images in the directory before handing you a prompt), and *Log out*.

## Ending a session

**Closing the browser tab only detaches.** Xvnc runs `-AlwaysShared`, so
reopening the URL puts you back in the same desktop with the windows where you
left them. That is deliberate: a dropped link should not cost you your work.

Ending the session is therefore something you ask for: *Log out* on the
desktop or in the fluxbox menu, `end-session` in a terminal, or
Ctrl+Alt+Delete. Each one makes fluxbox, the session leader, quit; the
supervisor sees it go and stops the rest. Under Docker the container then
stops; under Apptainer `apptainer run` returns.

`end-session` asks for confirmation through zenity when there is a display, and
takes `--force` when there is not. From a headless `docker exec` it does not
ask, on the grounds that whoever typed it meant it.

### Supervision

The session is several processes, so the entrypoint does not `exec` any of
them; it stays and supervises them through `web/supervise.sh` (from the kit),
the same supervisor as `app-novnc`. Each service runs in its own process
group, so stopping it stops what it started too:

| Service | Kind | If it exits |
|---|---|---|
| Xvnc | critical | the session ends (`1`) |
| fluxbox | leader | a normal exit is a log-out (`0`); anything else `1` |
| websockify | critical | the session ends (`1`): without it the gate would answer 502 |
| the gate (nginx) | critical | the session ends (`1`) |
| the session bus, PCManFM's desktop, the terminal | helper | nothing; the desktop carries on without it |

A canceled job or `docker stop` (SIGTERM) ends it with `143`. Cleanup stops
everything in reverse start order — the gate and websockify first, so nothing
new lands on a desktop that is going away; then the applications; the X server
last, because killing X first turns every application into a crash — and then
removes the session directory.

Every service except the gate starts without `OSP_APP_TOKEN` in its
environment, so the desktop, its terminals, the session bus and whatever the
user runs never hold the token. Service output reaches the job's stderr with a
`[name] ` prefix; fluxbox's own chatter goes to `fluxbox.log` in the session
directory.

### Where the desktop configuration lives, and why it is split

Two files are **system defaults baked into the image**, not seeded into the
home directory:

| File | Installed to | Holds |
|---|---|---|
| `desktop/mimeapps.list` | `/usr/share/applications/mimeapps.list` | which app opens which file type |
| `desktop/libfm.conf` | `/etc/xdg/libfm/libfm.conf` | `quick_exec`, thumbnails, `terminal=` |

Both are XDG locations for distribution defaults, so they hold with
`OSP_SEED_DESKTOP=0`, under any `$HOME`, and in a home directory carried over
from an older image. A user who changes either through the GUI gets their own
copy under `~/.config`, which is read afterwards and wins. Seeding them into
the home instead would make the image's defaults a user *override* that then
survived every subsequent image update.

**`/etc/xdg/libfm/libfm.conf` is not a stylistic choice.** libfm loads its
config with `fm_config_load_from_file(cfg, NULL)`, which hardcodes the name
`libfm/libfm.conf` and searches `XDG_CONFIG_DIRS` then `XDG_CONFIG_HOME`. It
never reads `~/.config/pcmanfm/<profile>/libfm.conf` — that directory is for
pcmanfm's own `pcmanfm.conf`, and a `libfm.conf` placed beside it is silently
ignored. This image shipped one there at first, which is why `quick_exec`, the
thumbnail settings and `terminal=` all looked set and none of them took effect.
The tell is that the desktop icons appeared correctly (that is `pcmanfm.conf`,
read from the profile directory) while nothing libfm owned worked.

Every mimeapps entry names our own desktop id (`osp-image-viewer.desktop`, not
`org.xfce.ristretto.desktop`). XFCE renamed ristretto's desktop file to a
reverse-DNS id at some point; ours will not be renamed underneath us.

### Why the configuration is seeded rather than baked

There is no settings daemon in this image, so GTK, PCManFM and fluxbox each
read their configuration from `$HOME`. `/app` is inside the `.sif` and mounted
read-only, and under Apptainer `$HOME` is not the image's, so the only moment
the configuration can be put in place is startup.

`entrypoint.sh` copies `desktop/skel/` into the session home and **never
overwrites an existing file**. What it adds is
`~/.config/gtk-3.0/settings.ini`, `~/.config/pcmanfm/default/pcmanfm.conf`,
`~/.fluxbox/menu`, `~/Desktop/osp-*.desktop` and
`~/README-object-detection.txt`. If you would rather it added nothing, set
`OSP_SEED_DESKTOP=0`. Note what is *not* in that list: the two system defaults
above, precisely so that fixing one of them reaches an existing home.

Under the run profile (`--contain`) the home is private to the session, small
(about 64 MB) and empty at every start, so seeding runs every session and
nothing saved in `~` survives it. Save your work in the working directory.

**Where a home does persist** — a bind mount you keep, or a Docker container
you reuse — it keeps the configuration of the image version that seeded it, so
a fixed default never reaches you. The entrypoint says so on startup
(`N file(s) seeded, M already yours`) and prints what to remove:

```bash
rm -rf ~/.config/pcmanfm ~/.config/gtk-3.0 ~/.fluxbox/menu ~/Desktop
```

### Home versus working directory

Under Docker they are the same: `USER ospuser`, `WORKDIR /home/ospuser`, and
that home is mode 1777 so the runtime uid — whatever `--user` you pass — can
write to it.

Under Apptainer they differ, and that is deliberate. `$HOME` holds the desktop
configuration and, under the run profile, is the session's own and gone at
the end. The working directory — the job directory, or wherever you ran
`apptainer run` — is where your images are and where results belong. The Files
window, the terminals, the *Object detection* launcher and the other Desktop
launchers all open on it, and `run.py` reads and writes relative paths, so
results land beside their inputs.

## Design notes

Inherited from `app-novnc`, where they are explained at more length:

**One TCP listener, on loopback.** Only the gate has a TCP port, and it binds
`127.0.0.1` — the launcher's reverse SSH tunnel connects there. websockify and
Xvnc have no TCP port at all: under Apptainer the container shares the node's
network, so a loopback port would be reachable by every other process on the
node, token or no token.

**Behind the gate, Unix sockets only.** Xvnc listens for RFB on
`$OSP_APP_SOCK_DIR/vnc.sock` (`-rfbunixpath`, `-rfbport -1`), websockify on
`$OSP_APP_SOCK_DIR/app.sock` (`--unix-listen`), both `0600` in a `0700`
directory. Xvnc runs `-nolisten tcp -nolisten local`: the second removes the X
server's *abstract* socket, which lives in the shared network namespace. Xvnc
has no VNC password (`-SecurityTypes None`): no socket anyone outside the
session can reach, and the gate is the authentication.

**The session directory.** `$OSP_APP_SOCK_DIR` is created under `/tmp`, never
under `$TMPDIR` (the job directory on shared storage under the run profile).
The rendered `nginx.conf` (which holds the token), the X cookie, the sockets,
`XDG_RUNTIME_DIR`, the supervisor's `leader.pid` and the seeding list all live
there, and it is removed when the session ends. websockify's own temporary
files go there too: since Python 3.14 its multiprocessing listens on a Unix
socket in the temporary directory, which must not be the job directory.

**Display numbers, `/tmp/.X11-unix`, the autoconnect page, websockets,
scratch paths.** As in `app-novnc`: the entrypoint walks `:1, :2, …` when
`/tmp` is shared; creates `/tmp/.X11-unix` mode `1777` and stops with a clear
message if it is not writable; the image bakes an `index.html` that redirects
to `vnc.html?autoconnect=true…`; and it probes `$TMPDIR`, `/tmp`, `$HOME` for
bulk scratch rather than trusting an inherited `$TMPDIR`. Never bind a scratch
*parent* (`/scratch`) to fix a missing `$TMPDIR`: it exposes every other job's
directory to the same uid.

**Readiness.** `GET /healthz` is ungated and returns `ok` (200) once websockify
answers on its socket, 503 before.

Added here:

**The session bus on a filesystem socket.** `dbus-launch`'s default address,
`unix:tmpdir=/tmp`, can give an *abstract* socket, and D-Bus lets any process
of the same uid in — so on a shared account, any other session on the node.
The entrypoint runs `dbus-daemon --session` on
`$OSP_APP_SOCK_DIR/dbus.sock` instead, and exports that address even if the
bus fails to start, so nothing "autolaunches" a bus of its own. GTK's
accessibility bridge, which would start a second bus, is off (`NO_AT_BRIDGE=1`).

**Caches per session, under `$TMPDIR`.** `XDG_CACHE_HOME` (thumbnails),
`MPLCONFIGDIR` and `YOLO_CONFIG_DIR` hold nothing secret and can grow, so they
go under `$TMPDIR/<session directory name>/`, not in the small private `/tmp`.
The image's `/tmp/...` values are fallbacks, replaced at start while still in
effect; a value the job sets is kept.

**No setuid or setgid files.** The build strips them and fails if any remain:
`/etc/passwd` is group-writable (for `--user "$(id -u):0"`), and under Docker
without `no-new-privileges` that plus a setuid `su` is a way to root.

**A venv rather than `--break-system-packages`.** Ubuntu marks its system
Python externally-managed (PEP 668). `/opt/venv` keeps the detector's pinned
wheels from arguing with the apt-installed desktop's Python bindings, and goes
first on `PATH`. `detect` names `/opt/venv/bin/python3` explicitly rather than
trusting whatever `PATH` a user's shell ends up with.

## Pinned versions

| What | Version | Where |
|---|---|---|
| Base image | `ubuntu:26.04` | `Dockerfile` |
| Ultralytics | `8.4.131` | `requirements.txt` |
| torch / torchvision | `2.13.0` / `0.28.0`, CPU-only | `Dockerfile` |
| Model weights | `yolo11n.pt` | baked in at build time |
| Apptainer | `1.5.2` | `APPTAINER_VERSION` in the workflow |
| Actions | checkout v6, buildx v4, login v4, metadata v6, build-push v7 | the workflow |

The base is `ubuntu:26.04`, matching `app-novnc`, because the VNC and desktop
half is the finicky half and is worth keeping identical to the app that is
known to work. The consequence is that Python comes from Ubuntu rather than
from `python:3.14-slim`, so the interpreter's minor version may differ from
`app-object-detection`'s. The wheels are pinned identically, which is what
determines the results.

The image is CPU-only: PyPI's default torch wheel is the CUDA build, which adds
roughly 2 GB the `.sif` then carries to every compute node.

**One package name to watch.** XFCE's image viewer is `ristretto` on current
Ubuntu; it was `xfce4-ristretto` before 20.04. If the `apt-get install` line
fails, that is the name to check first.

## Build and test locally

Skip GitHub and the registry entirely:

```bash
bash -n entrypoint.sh                        # syntax, before anything else
# web/ is not in this repository: the build copies it from the kit image named
# at the top of the Dockerfile (ghcr.io/onescienceplace/app-kit).
docker build -t app-object-detection-novnc-pcmanfm:dev .   # --platform linux/amd64 on Apple Silicon
docker run --rm --user "$(id -u):$(id -g)" \
  -p 127.0.0.1:6080:6080 -v "$PWD:/home/ospuser" \
  -e OSP_APP_PORT=6080 -e OSP_APP_BIND=0.0.0.0 -e OSP_APP_TOKEN=localdev \
  app-object-detection-novnc-pcmanfm:dev

docker save app-object-detection-novnc-pcmanfm:dev -o aodnp.tar
apptainer build aodnp.sif docker-archive://aodnp.tar
export APPTAINERENV_OSP_APP_TOKEN=localdev
apptainer run --contain --pid --ipc --cleanenv --no-mount bind-paths,cwd \
  --pwd "$PWD" --bind "$PWD:$PWD" --env OSP_APP_PORT=6080 --env TMPDIR="$PWD/tmp" aodnp.sif
```

(`localdev` on the command line is fine for a throwaway local token; never do
it with a real one.)

Open `http://localhost:6080/?token=localdev`. Use *localhost*, not the host's
IP: the gate's cookie is marked `Secure`, and browsers make an exception for
`http://localhost` but not for any other plain-http origin, where the cookie is
dropped and every page load needs `?token=` again.

Worth checking specifically, and only the `.sif` exercises them: that the
desktop configuration was seeded into a writable home rather than failing
silently; that thumbnails appear in the Files window (if they do not, the
session bus did not come up — the entrypoint says so on stderr); and that
`detect` runs with no network at all.

Isolation between two sessions of the same account is checked per system and
per image, before interactive apps are offered there (OSP's internal
validation procedure).

### Why `--user`

The image already sets `USER ospuser` (uid 1000), so a bare `docker run` does
not write root-owned files. But uid 1000 is probably not *you*: on Linux,
anything the container writes into a bind mount still comes out owned by 1000,
and if the mounted directory is yours the container may not be able to write to
it at all. `--user "$(id -u):$(id -g)"` fixes both and matches how Apptainer
runs it — Apptainer is always the invoking user.

To reclaim files a previous run left behind:

```bash
sudo chown -R "$(id -u):$(id -g)" .
```

That uid has no `/etc/passwd` entry inside the container, so `whoami` fails and
`ls -l` shows bare numbers. Nothing actually breaks — only code calling
`getpwuid()` notices — and Apptainer generates the entry itself. If you want a
name locally:

```bash
# 1. Let the entrypoint add one. /etc/passwd is group-writable in this image,
#    so running with group 0 is enough. You become `ospuser`.
docker run --rm --user "$(id -u):0" ...

# 2. Or show the container your real identity, keeping your own gid.
docker run --rm --user "$(id -u):$(id -g)" \
  -v /etc/passwd:/etc/passwd:ro -v /etc/group:/etc/group:ro ...
```

Set `OSP_APP_USER` to change the name option 1 uses.

`apptainer build` from a local archive needs no root and no fakeroot. Test the
`.sif` and not just the image: read-only-filesystem bugs never show up under
`docker run`.
