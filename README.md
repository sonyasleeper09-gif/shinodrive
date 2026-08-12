# ♥ SHINODRIVE

**A self-hosted, mobile-first file manager for your NAS — in a single Go binary.**
病みかわ NAS ・ prettier and friendlier than a raw Samba share, especially on your phone.

SHINODRIVE turns any folder on your home server into a slick web drive you can open from
any device — no SMB client, no cloud, just your own box. Upload from your phone, stream
videos in the browser, and share a file with a link like it's Google Drive.

---

## ✨ Features

- 📁 **Browse** files & folders — list or thumbnail grid view
- ⬆️ **Upload** with drag-and-drop (desktop) or the file picker (mobile), with progress
- ⬇️ **Download** files, or a whole folder as a **ZIP**
- ▶️ **Preview in-browser** — images, audio, and **video** (mkv/avi/etc. transcoded on the fly via ffmpeg)
- 🔗 **Share links** — public read-only links for a file or folder, no login needed (Google-Drive style)
- 🔍 **Search** recursively by filename
- ✏️ Rename · new folder · delete
- 📊 Live **storage + CPU/RAM/temperature** readout
- 🔐 Password login (HMAC-signed token; works as cookie for the web and `Bearer`/`?t=` for apps)
- 📱 Installable as a **PWA** (Add to Home Screen) — plus an optional native iOS client
- 🎀 Menhera / pixel aesthetic, fully responsive

## 🧱 Tech

- **Pure Go, standard library only** — no web framework, no external Go deps
- **Single static binary** with all web assets embedded (`go:embed`)
- Optional `ffmpeg` / `ffprobe` for video thumbnails & transcoding
- ~7 MB binary, sips RAM — happy on an old NAS box

---

## 🚀 Quick start

```sh
git clone https://github.com/sonyasleeper09-gif/shinodrive.git
cd shinodrive
./install.sh
```

The installer builds the binary, asks for a **share folder / port / password**, installs a
`systemd` service, and starts it. Then open `http://<server-ip>:8090` and log in.

> Requires **Go** to build, and **ffmpeg** for video features.
> Arch: `sudo pacman -S go ffmpeg` · Debian/Ubuntu: `sudo apt install golang ffmpeg`

### Build only

```sh
CGO_ENABLED=0 go build -trimpath -ldflags="-s -w" -o shinodrive .
SHINODRIVE_ROOT=/srv/nas ./shinodrive        # then open :8090
```

---

## ⚙️ Configuration

Everything is via environment variables (the `systemd` unit sets them for you):

| Variable | Default | Meaning |
|---|---|---|
| `SHINODRIVE_ROOT` | `/home/nas` | folder to serve |
| `SHINODRIVE_ADDR` | `:8090` | listen address |
| `SHINODRIVE_CFG` | `$HOME/.config/shinodrive` | where secrets live |

Secrets/state created automatically in `$SHINODRIVE_CFG`: `secret` (cookie signing key),
`shares.json` (active share links), and **`users.json`** (accounts).

## 👥 Users, home folders & permissions

SHINODRIVE is multi-user. On first run it migrates the old single password into an **`admin`**
account (login `admin` / your password). The admin can then add users from **☰ → 유저 관리**:

| Role | Can do |
|---|---|
| **admin** | everything + manage users; sees the whole share root |
| **editor** | read **and write** inside their own home folder |
| **reader** | read-only (browse / download / share) inside their home |

Each non-admin user gets a **private home folder** `SHINODRIVE_ROOT/<username>` and only ever sees
inside it — path traversal out is blocked. Users can change their own password from the account menu.
`users.json` stores `{username: {pass(sha256), role, home}}`.

---

## 🔗 Share links

Hit the ⋮ menu on any file/folder → **Share** → copy the link. Anyone with the link can
view/download it at `/(s)/<token>` — no account needed. Manage or revoke links from the
**＋ → Share management** sheet.

## 📱 On your phone

- **PWA**: open the site in Safari/Chrome → *Add to Home Screen* → it launches fullscreen like an app.
- **Native iOS**: a Flutter client exists (browse / upload / preview / share) that talks to the
  same backend — point it at your server URL + password.

---

## ⚠️ Notes

- Serve on your LAN, or reach it from anywhere via **Tailscale** / a reverse proxy. It speaks
  plain HTTP; put TLS in front of it if you expose it to the internet.
- Path traversal is blocked (everything is resolved under the share root).
- Multi-user with roles + per-user home folders (see above). Still personal-scale — no quotas or 2FA.

## 📄 License

MIT © 2026 shino
