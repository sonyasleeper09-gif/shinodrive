#!/usr/bin/env bash
# ♥ SHINODRIVE installer ♥  —  self-hosted menhera NAS file manager
# Usage:  ./install.sh          (interactive)
#         SHINODRIVE_PASSWORD=xxx SHINODRIVE_ROOT=/srv/nas ./install.sh   (non-interactive)
set -euo pipefail

BIN_DIR="${SHINODRIVE_BIN:-/usr/local/bin}"
DATA_DIR="${SHINODRIVE_ROOT:-/srv/shinodrive}"
PORT="${SHINODRIVE_PORT:-8090}"
SVC_USER="${SHINODRIVE_USER:-$USER}"
CFG_DIR="/home/${SVC_USER}/.config/shinodrive"

say(){ printf '\033[38;5;211m%s\033[0m\n' "$*"; }

say "♥ SHINODRIVE installer ♥"

command -v go >/dev/null || { echo "✗ Go가 필요해요.  Arch: sudo pacman -S go   /   Debian: sudo apt install golang"; exit 1; }
command -v ffmpeg >/dev/null || echo "⚠ ffmpeg 없음 — 영상 미리보기/트랜스코딩이 안 돼요 (sudo pacman -S ffmpeg)"

cd "$(dirname "$0")"

if [ -t 0 ]; then
  read -rp "공유 폴더 경로 [$DATA_DIR]: " x; DATA_DIR="${x:-$DATA_DIR}"
  read -rp "포트 [$PORT]: " x; PORT="${x:-$PORT}"
  read -rsp "비밀번호 [menhera]: " PW; echo; PW="${PW:-menhera}"
else
  PW="${SHINODRIVE_PASSWORD:-menhera}"
fi

say "→ 빌드 중..."
CGO_ENABLED=0 go build -trimpath -ldflags="-s -w" -o shinodrive .

say "→ 설치 (sudo 필요)"
sudo install -Dm755 shinodrive "$BIN_DIR/shinodrive"
sudo mkdir -p "$DATA_DIR"
sudo chown "$SVC_USER:$SVC_USER" "$DATA_DIR"

mkdir -p "$CFG_DIR"
printf '%s\n' "$PW" > "$CFG_DIR/password.txt"
chmod 600 "$CFG_DIR/password.txt"

say "→ systemd 서비스 등록"
sudo tee /etc/systemd/system/shinodrive.service >/dev/null <<EOF
[Unit]
Description=SHINODRIVE menhera file manager
After=network.target

[Service]
User=${SVC_USER}
Environment=SHINODRIVE_ROOT=${DATA_DIR}
Environment=SHINODRIVE_ADDR=:${PORT}
Environment=SHINODRIVE_CFG=${CFG_DIR}
ExecStart=${BIN_DIR}/shinodrive
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable --now shinodrive

IP=$(ip -4 -o addr show scope global 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -1)
say ""
say "♥ 설치 완료!"
echo "   접속:   http://${IP:-<이 서버 IP>}:${PORT}"
echo "   비번:   (방금 설정한 것)  ·  바꾸려면: ${CFG_DIR}/password.txt 수정 후 sudo systemctl restart shinodrive"
echo "   공유:   ${DATA_DIR}"
echo "   상태:   systemctl status shinodrive"
