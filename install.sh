#!/usr/bin/env bash
# ============================================================
#  HVPN installer  (Docker host-network + Caddy auto-TLS + `hvpn` CLI)
#
#  Fresh install (inside the project folder that has the Dockerfile):
#      bash install.sh
#  Upgrade an existing install to this version (keeps data/domain/users):
#      bash install.sh --upgrade
#  Without local files it clones REPO_URL:
#      REPO_URL=https://github.com/USER/HVPN.git bash install.sh
# ============================================================
set -euo pipefail

APP_DIR="/opt/hvpn"
SRC_DIR="${APP_DIR}/src"
DATA_DIR="${APP_DIR}/data"
ENV_FILE="${APP_DIR}/.env"
CLI="/usr/local/bin/hvpn"
REPO_URL="${REPO_URL:-https://github.com/Hohoseini/HVPN.git}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
UPGRADE=0
[[ "${1:-}" == "--upgrade" ]] && UPGRADE=1

R='\033[0;31m'; G='\033[0;32m'; Y='\033[1;33m'; C='\033[0;36m'; N='\033[0m'
info() { echo -e "${C}➜${N} $*"; }
ok()   { echo -e "${G}✔${N} $*"; }
warn() { echo -e "${Y}!${N} $*"; }
die()  { echo -e "${R}✘ $*${N}" >&2; exit 1; }

[[ $EUID -eq 0 ]] || die "Run as root:  sudo bash install.sh"
command -v apt-get >/dev/null 2>&1 || die "This installer supports Debian/Ubuntu only."

# ---------------- helpers ----------------
get_ip() {
  local u ip
  for u in https://api.ipify.org https://ifconfig.me https://icanhazip.com; do
    ip=$(curl -4 -s --max-time 6 "$u" | tr -d '[:space:]' || true)
    if [[ $ip =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then echo "$ip"; return 0; fi
  done
  return 1
}

port_free() { ! ss -ltnH "( sport = :$1 )" 2>/dev/null | grep -q .; }

pick_port() {
  local p
  if port_free 8080; then echo 8080; return; fi
  while :; do
    p=$(shuf -i 20000-60000 -n 1)
    if port_free "$p"; then echo "$p"; return; fi
  done
}

wait_dns() {   # $1 domain  $2 server ip
  local d="$1" ip="$2" got a
  echo
  echo -e "${Y}Set this DNS record in your domain panel:${N}"
  echo -e "   Type: ${C}A${N}    Name: ${C}${d}${N}    Value: ${C}${ip}${N}"
  echo -e "   (Cloudflare users: set proxy to ${C}DNS only${N} / grey cloud)"
  echo -e "   Check link: ${C}https://dnschecker.org/#A/${d}${N}"
  echo
  while :; do
    got=$(dig +short A "$d" @1.1.1.1 | tail -n1 || true)
    if [[ "$got" == "$ip" ]]; then ok "DNS OK: ${d} → ${ip}"; return 0; fi
    warn "DNS not ready (got: ${got:-none})"
    read -rp "[Enter] check again, [s] skip: " a
    if [[ "$a" == "s" ]]; then warn "Skipped. HTTPS certificate will be issued once DNS is correct."; return 0; fi
  done
}

copy_sources() {
  local keep_url=""
  mkdir -p "$APP_DIR" "$DATA_DIR"
  rm -rf "$SRC_DIR"; mkdir -p "$SRC_DIR"
  if [[ -f "${SCRIPT_DIR}/Dockerfile" && -f "${SCRIPT_DIR}/package.json" ]]; then
    info "Using local project files from ${SCRIPT_DIR}"
    tar -C "$SCRIPT_DIR" --exclude=node_modules --exclude=.git --exclude=data -cf - . | tar -C "$SRC_DIR" -xf -
    # uploaded files may have lost their leading dots
    if [[ -f "$SRC_DIR/_dockerignore" && ! -f "$SRC_DIR/.dockerignore" ]]; then
      cp "$SRC_DIR/_dockerignore" "$SRC_DIR/.dockerignore"
    fi
    # remember where this project came from so `hvpn update` can pull it later
    keep_url=$(git -C "$SCRIPT_DIR" remote get-url origin 2>/dev/null || true)
  else
    info "Cloning ${REPO_URL}"
    git clone --depth 1 "$REPO_URL" "$SRC_DIR" >/dev/null 2>&1 || die "git clone failed."
    keep_url="$REPO_URL"
  fi
  [[ -f "$SRC_DIR/Dockerfile" ]] || die "Dockerfile not found in project."
  [[ -d "$SRC_DIR/apps/server" && -d "$SRC_DIR/apps/web" ]] || die "apps/server or apps/web is missing from the project."
  SOURCE_URL="$keep_url"
}

set_env() { # key value  (in ENV_FILE)
  if grep -q "^$1=" "$ENV_FILE" 2>/dev/null; then sed -i "s|^$1=.*|$1=$2|" "$ENV_FILE"; else echo "$1=$2" >> "$ENV_FILE"; fi
}

# ---------------- packages + docker ----------------
info "Installing base packages..."
export DEBIAN_FRONTEND=noninteractive
apt-get update -y >/dev/null
apt-get install -y curl git jq dnsutils iproute2 ca-certificates tar openssl >/dev/null

if ! command -v docker >/dev/null 2>&1; then
  info "Installing Docker..."
  curl -fsSL https://get.docker.com | sh >/dev/null
fi
systemctl enable --now docker >/dev/null 2>&1 || true
docker compose version >/dev/null 2>&1 || die "Docker Compose plugin missing. Install 'docker-compose-plugin' and retry."
ok "Docker ready"

# ============================================================
#  The `hvpn` CLI (also owns the compose/Caddy config + system tuning)
# ============================================================
install_cli() {
cat > "$CLI" <<'HVPN_CLI_EOF'
#!/usr/bin/env bash
APP_DIR="/opt/hvpn"
SRC_DIR="${APP_DIR}/src"
DATA_DIR="${APP_DIR}/data"
ENV_FILE="${APP_DIR}/.env"
CLI="/usr/local/bin/hvpn"
R='\033[0;31m'; G='\033[0;32m'; Y='\033[1;33m'; C='\033[0;36m'; N='\033[0m'

[[ $EUID -eq 0 ]] || { echo -e "${R}Run as root:  sudo hvpn${N}"; exit 1; }
[[ -f "$ENV_FILE" ]] || { echo -e "${R}HVPN is not installed.${N}"; exit 1; }

dc()   { docker compose -f "${APP_DIR}/docker-compose.yml" --project-directory "$APP_DIR" "$@"; }
load() { set -a; . "$ENV_FILE"; set +a; }
setenv() { # key value
  if grep -q "^$1=" "$ENV_FILE"; then sed -i "s|^$1=.*|$1=$2|" "$ENV_FILE"; else echo "$1=$2" >> "$ENV_FILE"; fi
}
port_free() { ! ss -ltnH "( sport = :$1 )" 2>/dev/null | grep -q .; }
pause() { read -rp "Press Enter..." _ || true; }

# ---------- config generation (single source of truth) ----------
write_config() {
  cat > "${APP_DIR}/Caddyfile" <<'EOF'
{$DOMAIN} {
	# compress text/JS/JSON/SVG only (VPN tunnel traffic is untouched)
	encode {
		zstd
		gzip
		match {
			header Content-Type text/*
			header Content-Type application/javascript*
			header Content-Type application/json*
			header Content-Type image/svg+xml*
		}
	}

	# hashed build files never change -> cache for a year
	@assets path /assets/*
	header @assets >Cache-Control "public, max-age=31536000, immutable"

	reverse_proxy 127.0.0.1:{$PANEL_PORT} {
		flush_interval -1
	}
}
EOF

  # Host networking = no Docker NAT/conntrack on the VPN data path (lower latency,
  # less CPU). The panel only listens on 127.0.0.1; Caddy is the only public entry.
  cat > "${APP_DIR}/docker-compose.yml" <<'EOF'
name: hvpn
services:
  hvpn:
    build: ./src
    container_name: hvpn
    restart: unless-stopped
    network_mode: host
    environment:
      - PORT=${PANEL_PORT}
      - HVPN_HOST=127.0.0.1
      - NODE_ENV=production
      - HVPN_DATA_DIR=/data
      - PUBLIC_DOMAIN=${DOMAIN}
      - XRAY_VERSION=${XRAY_VERSION}
    ulimits:
      nofile:
        soft: 1048576
        hard: 1048576
    volumes:
      - ./data:/data

  caddy:
    image: caddy:2
    container_name: hvpn-caddy
    restart: unless-stopped
    network_mode: host
    depends_on:
      - hvpn
    environment:
      - DOMAIN=${DOMAIN}
      - PANEL_PORT=${PANEL_PORT}
    ulimits:
      nofile:
        soft: 1048576
        hard: 1048576
    volumes:
      - ./Caddyfile:/etc/caddy/Caddyfile:ro
      - caddy_data:/data
      - caddy_config:/config

volumes:
  caddy_data:
  caddy_config:
EOF
}

# ---------- kernel / network tuning ----------
tune_system() {
  local cc="cubic"
  modprobe tcp_bbr 2>/dev/null || true
  if sysctl net.ipv4.tcp_available_congestion_control 2>/dev/null | grep -qw bbr; then cc="bbr"; fi
  rm -f /etc/sysctl.d/99-bbr.conf /etc/sysctl.d/99-hvpn-bbr.conf
  cat > /etc/sysctl.d/99-hvpn-tune.conf <<EOF
# HVPN network tuning
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=${cc}
net.core.rmem_max=33554432
net.core.wmem_max=33554432
net.ipv4.tcp_rmem=4096 262144 33554432
net.ipv4.tcp_wmem=4096 262144 33554432
net.ipv4.tcp_fastopen=3
net.ipv4.tcp_slow_start_after_idle=0
net.ipv4.tcp_mtu_probing=1
net.ipv4.tcp_notsent_lowat=131072
net.ipv4.tcp_max_syn_backlog=8192
net.core.somaxconn=4096
net.core.netdev_max_backlog=16384
net.ipv4.ip_local_port_range=10240 65000
net.ipv4.tcp_fin_timeout=15
fs.file-max=1048576
EOF
  sysctl --system >/dev/null 2>&1 || true
  echo -e "${G}Network tuned.${N} Congestion control: $(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)  Queue: $(sysctl -n net.core.default_qdisc 2>/dev/null)"
}

owner_name() {
  docker exec hvpn node --no-warnings -e '
    const {DatabaseSync}=require("node:sqlite");
    const db=new DatabaseSync("/data/hvpn.db");
    const r=db.prepare("SELECT username FROM admins WHERE role=\x27owner\x27 LIMIT 1").get();
    console.log(r?r.username:"-");' 2>/dev/null || echo "-"
}

show_info() {
  load
  local st; st=$(docker inspect -f '{{.State.Status}}' hvpn 2>/dev/null || echo "not found")
  echo -e "Status     : ${C}${st}${N}"
  echo -e "Panel URL  : ${C}https://${DOMAIN}${N}"
  echo -e "Server IP  : ${C}${SERVER_IP}${N}"
  echo -e "Local port : ${C}127.0.0.1:${PANEL_PORT}${N}"
  echo -e "TCP cc     : ${C}$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)${N}"
  echo -e "Owner user : ${C}$(owner_name)${N}"
}

do_restart() {
  dc restart && echo -e "${G}Restarted.${N}" || echo -e "${R}Restart failed.${N}"
}

do_update() {
  load
  local u tmp
  if [[ -d "${SRC_DIR}/.git" ]]; then
    git -C "$SRC_DIR" pull --ff-only || { echo -e "${R}git pull failed.${N}"; return 1; }
  else
    u="${REPO_URL:-}"
    if [[ -z "$u" ]]; then read -rp "Git URL to pull from (empty = just rebuild current files): " u; fi
    if [[ -n "$u" ]]; then
      tmp=$(mktemp -d)
      git clone --depth 1 "$u" "$tmp/src" || { echo -e "${R}clone failed.${N}"; rm -rf "$tmp"; return 1; }
      rm -rf "$SRC_DIR"; mv "$tmp/src" "$SRC_DIR"; rm -rf "$tmp"
      setenv REPO_URL "$u"
    fi
  fi
  write_config
  tune_system >/dev/null
  dc build --pull && dc up -d --remove-orphans && docker image prune -f >/dev/null
  echo -e "${G}Updated. Data was kept.${N}"
}

do_password() {
  docker inspect -f '{{.State.Running}}' hvpn 2>/dev/null | grep -q true || { echo -e "${R}Container is not running.${N}"; return 1; }
  local nu np np2 res
  read -rp "New owner username (empty = keep): " nu
  while :; do
    read -rsp "New password (empty = random): " np; echo
    if [[ -z "$np" ]]; then
      np=$(openssl rand -base64 12 | tr -d '/+=' | cut -c1-12)
      echo -e "Generated: ${C}${np}${N}"
      break
    fi
    read -rsp "Repeat password: " np2; echo
    if [[ "$np" == "$np2" && ${#np} -ge 6 ]]; then break; fi
    echo -e "${Y}Mismatch or shorter than 6 characters.${N}"
  done
  res=$(docker exec -e NEWPW="$np" -e NEWUSER="$nu" hvpn node --no-warnings -e '
    const bcrypt=require("bcryptjs");
    const {DatabaseSync}=require("node:sqlite");
    const db=new DatabaseSync("/data/hvpn.db");
    const hash=bcrypt.hashSync(process.env.NEWPW,10);
    const r=db.prepare("UPDATE admins SET password_hash=?, token_version=token_version+1 WHERE role=\x27owner\x27").run(hash);
    const u=(process.env.NEWUSER||"").trim();
    if(u && r.changes>0){ db.prepare("UPDATE admins SET username=? WHERE role=\x27owner\x27").run(u); }
    console.log(r.changes);' 2>&1)
  if [[ "$res" == "1" ]]; then
    echo -e "${G}Owner password changed. All old sessions were logged out.${N}"
  else
    echo -e "${R}Failed (is the panel set up yet?): ${res}${N}"
  fi
}

do_domain() {
  load
  local nd got a
  read -rp "New domain: " nd
  nd=$(echo "$nd" | tr 'A-Z' 'a-z' | sed 's#^https\?://##; s#/.*$##; s/[[:space:]]//g')
  [[ "$nd" =~ ^[a-z0-9.-]+\.[a-z]{2,}$ ]] || { echo -e "${R}Invalid domain.${N}"; return 1; }
  echo -e "\n${Y}Set this DNS record:${N}  A  ${C}${nd}${N}  →  ${C}${SERVER_IP}${N}"
  echo -e "Check: ${C}https://dnschecker.org/#A/${nd}${N}\n"
  while :; do
    got=$(dig +short A "$nd" @1.1.1.1 | tail -n1)
    if [[ "$got" == "$SERVER_IP" ]]; then echo -e "${G}DNS OK${N}"; break; fi
    echo -e "${Y}DNS not ready (got: ${got:-none})${N}"
    read -rp "[Enter] check again, [s] skip: " a
    [[ "$a" == "s" ]] && break
  done
  setenv DOMAIN "$nd"
  dc up -d && echo -e "${G}Domain changed to ${nd}. Client links now use the new domain.${N}"
}

do_port() {
  load
  local np
  read -rp "New local panel port (1024-65535): " np
  [[ "$np" =~ ^[0-9]+$ && $np -ge 1024 && $np -le 65535 ]] || { echo -e "${R}Invalid port.${N}"; return 1; }
  if [[ "$np" == "$PANEL_PORT" ]]; then echo "Same as current."; return 0; fi
  port_free "$np" || { echo -e "${R}Port ${np} is in use.${N}"; return 1; }
  setenv PANEL_PORT "$np"
  dc up -d && echo -e "${G}Local port is now ${np}. (Public access still goes through https://${DOMAIN})${N}"
}

do_logs() {
  local c
  echo "1) Panel   2) Caddy (HTTPS)"
  read -rp "Choose [1]: " c
  if [[ "$c" == "2" ]]; then docker logs --tail 80 -f hvpn-caddy; else docker logs --tail 80 -f hvpn; fi
}

do_uninstall() {
  local a d
  read -rp "Really uninstall HVPN? (yes/no): " a
  [[ "$a" == "yes" ]] || { echo "Cancelled."; return 0; }
  read -rp "Also DELETE all data (users, admins, settings)? (yes/no) [no]: " d
  dc down -v --rmi local 2>/dev/null
  if [[ "$d" == "yes" ]]; then
    rm -rf "$APP_DIR"
  else
    find "$APP_DIR" -mindepth 1 -maxdepth 1 ! -name data -exec rm -rf {} +
    echo -e "${Y}Data kept in ${DATA_DIR}${N}"
  fi
  rm -f "$CLI"
  echo -e "${G}HVPN uninstalled. (Docker and the network tuning were left in place.)${N}"
  exit 0
}

usage() {
  echo "Usage: hvpn [info|restart|update|password|domain|port|logs|tune|uninstall]"
  echo "       hvpn            (interactive menu)"
}

case "${1:-}" in
  info|status) show_info; exit 0 ;;
  restart)     do_restart; exit 0 ;;
  update)      do_update; exit 0 ;;
  password)    do_password; exit 0 ;;
  domain)      do_domain; exit 0 ;;
  port)        do_port; exit 0 ;;
  logs)        do_logs; exit 0 ;;
  tune)        tune_system; exit 0 ;;
  uninstall)   do_uninstall; exit 0 ;;
  _write-config) load; write_config; exit 0 ;;
  -h|--help|help) usage; exit 0 ;;
  "") ;;
  *) usage; exit 1 ;;
esac

while true; do
  clear
  echo -e "${C}============== HVPN PANEL ==============${N}"
  show_info
  echo -e "${C}----------------------------------------${N}"
  echo " 1) Restart"
  echo " 2) Update"
  echo " 3) Change owner password"
  echo " 4) Change domain"
  echo " 5) Change local port"
  echo " 6) View logs"
  echo " 7) Re-apply speed tuning (BBR / buffers)"
  echo " 8) Uninstall"
  echo " 0) Exit"
  read -rp "Choose: " c || exit 0
  case "$c" in
    1) do_restart;   pause ;;
    2) do_update;    pause ;;
    3) do_password;  pause ;;
    4) do_domain;    pause ;;
    5) do_port;      pause ;;
    6) do_logs ;;
    7) tune_system;  pause ;;
    8) do_uninstall; pause ;;
    0) exit 0 ;;
  esac
done
HVPN_CLI_EOF
chmod +x "$CLI"
}

# ============================================================
#  UPGRADE MODE: keep domain / port / data / users, apply new code + config
# ============================================================
if [[ $UPGRADE -eq 1 ]]; then
  [[ -f "$ENV_FILE" ]] || die "No existing install found (${ENV_FILE}). Run without --upgrade."
  info "Upgrading existing HVPN install (data is kept)..."
  set -a; . "$ENV_FILE"; set +a
  copy_sources
  [[ -n "${SOURCE_URL:-}" ]] && set_env REPO_URL "$SOURCE_URL"
  # stop old containers first (old compose still on disk) so ports are released
  if [[ -f "${APP_DIR}/docker-compose.yml" ]]; then
    docker compose -f "${APP_DIR}/docker-compose.yml" --project-directory "$APP_DIR" down --remove-orphans || true
  fi
  install_cli
  "$CLI" _write-config
  "$CLI" tune
  info "Building and starting..."
  docker compose -f "${APP_DIR}/docker-compose.yml" --project-directory "$APP_DIR" up -d --build
  up=0
  for _ in $(seq 1 90); do
    if curl -fs "http://127.0.0.1:${PANEL_PORT}/healthz" >/dev/null 2>&1; then up=1; break; fi
    sleep 2
  done
  [[ $up -eq 1 ]] || die "Panel did not start. Check logs:  docker logs hvpn"
  ok "Upgrade finished. Panel: https://${DOMAIN}   (manage with: hvpn)"
  exit 0
fi

# ============================================================
#  FRESH INSTALL
# ============================================================
SERVER_IP=$(get_ip) || die "Could not detect public IP."
ok "Server IP: ${SERVER_IP}"

echo
read -rp "Enter your domain (e.g. vpn.example.com): " DOMAIN
DOMAIN=$(echo "$DOMAIN" | tr 'A-Z' 'a-z' | sed 's#^https\?://##; s#/.*$##; s/[[:space:]]//g')
[[ "$DOMAIN" =~ ^[a-z0-9.-]+\.[a-z]{2,}$ ]] || die "Invalid domain."
wait_dns "$DOMAIN" "$SERVER_IP"

if [[ ! -f "${APP_DIR}/docker-compose.yml" ]]; then
  for p in 80 443; do
    port_free "$p" || die "Port ${p} is already in use (nginx/apache?). Check:  ss -ltnp | grep :${p}"
  done
  for p in 10085 20000 20001 20002 20003 20004; do
    port_free "$p" || warn "Port ${p} is in use — HVPN's internal Xray needs 10085 and 20000-20004 on 127.0.0.1."
  done
fi
PANEL_PORT=$(pick_port)
ok "Panel local port: ${PANEL_PORT} (127.0.0.1 only; public traffic goes through HTTPS 443)"

echo
read -rp "Owner username [owner]: " OWNER_USER
OWNER_USER=${OWNER_USER:-owner}
[[ ${#OWNER_USER} -ge 3 ]] || die "Username must be at least 3 characters."
while :; do
  read -rsp "Owner password (min 6): " OWNER_PASS; echo
  read -rsp "Repeat password: " OWNER_PASS2; echo
  if [[ "$OWNER_PASS" == "$OWNER_PASS2" && ${#OWNER_PASS} -ge 6 ]]; then break; fi
  warn "Passwords do not match or are too short."
done

copy_sources

cat > "$ENV_FILE" <<EOF
DOMAIN=${DOMAIN}
PANEL_PORT=${PANEL_PORT}
SERVER_IP=${SERVER_IP}
XRAY_VERSION=v26.9.9
EOF
[[ -n "${SOURCE_URL:-}" ]] && echo "REPO_URL=${SOURCE_URL}" >> "$ENV_FILE"
chmod 600 "$ENV_FILE"

if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "Status: active"; then
  ufw allow 80/tcp  >/dev/null
  ufw allow 443/tcp >/dev/null
  ufw allow 443/udp >/dev/null
  ok "ufw: opened 80 and 443"
fi

install_cli
"$CLI" _write-config
"$CLI" tune

info "Building and starting (first build takes a few minutes)..."
docker compose -f "${APP_DIR}/docker-compose.yml" --project-directory "$APP_DIR" up -d --build

info "Waiting for the panel to come up..."
up=0
for _ in $(seq 1 90); do
  if curl -fs "http://127.0.0.1:${PANEL_PORT}/healthz" >/dev/null 2>&1; then up=1; break; fi
  sleep 2
done
[[ $up -eq 1 ]] || die "Panel did not start. Check logs:  docker logs hvpn"

BODY=$(jq -n --arg u "$OWNER_USER" --arg p "$OWNER_PASS" '{username:$u,password:$p}')
RES=$(curl -s -X POST "http://127.0.0.1:${PANEL_PORT}/api/setup" -H 'Content-Type: application/json' -d "$BODY" || true)
if echo "$RES" | grep -q '"ok":true'; then
  ok "Owner account created"
elif echo "$RES" | grep -q 'already set up'; then
  warn "Panel was already set up (existing data kept). Use 'hvpn password' to reset the password."
else
  warn "Could not create owner automatically: ${RES}"
fi

echo
echo -e "${G}================ Installed ================${N}"
echo -e " Panel   : ${C}https://${DOMAIN}${N}"
echo -e " IP      : ${SERVER_IP}"
echo -e " User    : ${OWNER_USER}"
echo -e " Manage  : type ${C}hvpn${N}"
echo -e " Note    : the HTTPS certificate can take ~1 minute after DNS is correct."
