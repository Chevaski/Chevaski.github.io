#!/usr/bin/env bash
# Downloads and runs 7 open-source "client finding" tools on a Mac.
#
#   bash setup-client-tools.sh          # install / update / start everything
#   bash setup-client-tools.sh stop     # stop everything
#
# Everything lives in ~/client-tools. Safe to run again: it updates the code
# and restarts whatever isn't already running.

set -u

BASE="$HOME/client-tools"
CREDS="$BASE/CREDENTIALS.txt"
RESULTS=()

say()  { printf "\n\033[1;34m==> %s\033[0m\n" "$*"; }
ok()   { RESULTS+=("OK    $1"); printf "\033[32m✓ %s\033[0m\n" "$1"; }
fail() { RESULTS+=("FAIL  $1"); printf "\033[31m✗ %s\033[0m\n" "$1"; }

# ---------------------------------------------------------------- stop mode
if [ "${1:-}" = "stop" ]; then
  say "Stopping everything"
  docker rm -f gmaps-scraper huginn reacher >/dev/null 2>&1
  (cd "$BASE/firecrawl" 2>/dev/null && docker compose down)
  (cd "$BASE/listmonk" 2>/dev/null && docker compose down)
  (cd "$BASE/twenty/packages/twenty-docker" 2>/dev/null && docker compose down)
  [ -f "$BASE/remote-jobs.pid" ] && kill "$(cat "$BASE/remote-jobs.pid")" 2>/dev/null
  rm -f "$BASE/remote-jobs.pid"
  echo "Stopped. Your data is kept; run the script again to start back up."
  exit 0
fi

# ---------------------------------------------------------------- checks
say "Checking your Mac"

if ! xcode-select -p >/dev/null 2>&1 || ! command -v git >/dev/null 2>&1; then
  echo "Git isn't installed. A window will pop up asking to install Apple's"
  echo "developer tools. Click Install, wait for it to finish, then run this script again."
  xcode-select --install 2>/dev/null
  exit 1
fi
echo "Git: $(git --version)"

if ! command -v docker >/dev/null 2>&1; then
  echo "Docker isn't installed."
  echo "Download Docker Desktop from https://www.docker.com/products/docker-desktop/"
  echo "(pick Apple Silicon or Intel to match your Mac), open it once, then run this script again."
  exit 1
fi

if ! docker info >/dev/null 2>&1; then
  echo "Docker is installed but not running. Starting Docker Desktop..."
  open -a Docker
  for _ in $(seq 1 60); do docker info >/dev/null 2>&1 && break; sleep 3; done
  if ! docker info >/dev/null 2>&1; then
    echo "Docker didn't start in 3 minutes. Open Docker Desktop yourself, wait for it, and run this again."
    exit 1
  fi
fi
echo "Docker: running"

MEM_GB=$(( $(docker info --format '{{.MemTotal}}') / 1024 / 1024 / 1024 ))
if [ "$MEM_GB" -lt 8 ]; then
  echo "Heads up: Docker only has ${MEM_GB}GB of memory. Firecrawl and Twenty are heavy."
  echo "If things crash, raise it in Docker Desktop > Settings > Resources > Memory (8GB+)."
fi

HAVE_NODE=0
if command -v node >/dev/null 2>&1 && [ "$(node -p 'process.versions.node.split(".")[0]')" -ge 22 ]; then
  HAVE_NODE=1
  echo "Node: $(node -v)"
else
  echo "Node 22+ not found. The Remote Jobs site needs it; everything else will still run."
  echo "Install it later from https://nodejs.org (LTS) and run this script again."
fi

# ---------------------------------------------------------------- passwords
mkdir -p "$BASE"
if [ ! -f "$CREDS" ]; then
  {
    echo "HUGINN_PASSWORD=$(openssl rand -hex 12)"
    echo "LISTMONK_PASSWORD=$(openssl rand -hex 12)"
    echo "TWENTY_PG_PASSWORD=$(openssl rand -hex 16)"
    echo "TWENTY_ENCRYPTION_KEY=$(openssl rand -base64 32)"
  } > "$CREDS"
  chmod 600 "$CREDS"
fi
# shellcheck disable=SC1090
source "$CREDS"

# ---------------------------------------------------------------- download
say "Downloading the 7 repos into $BASE"
REPOS=(
  gosom/google-maps-scraper
  huginn/huginn
  firecrawl/firecrawl
  reacherhq/check-if-email-exists
  remoteintech/remote-jobs
  knadh/listmonk
  twentyhq/twenty
)
for r in "${REPOS[@]}"; do
  dir="$BASE/${r#*/}"
  if [ -d "$dir/.git" ]; then
    echo "Updating $r"
    git -C "$dir" pull --ff-only -q || echo "  (couldn't update $r, keeping the copy you have)"
  else
    echo "Cloning $r"
    git clone -q --depth 1 "https://github.com/$r.git" "$dir" || fail "download $r"
  fi
done

# Start a single-container tool, or restart it if it already exists.
run_container() {
  local name=$1; shift
  if docker ps -a --format '{{.Names}}' | grep -qx "$name"; then
    docker start "$name" >/dev/null
  else
    docker run -d --name "$name" --restart unless-stopped "$@" >/dev/null
  fi
}

# ---------------------------------------------------------------- run
say "1/7 Google Maps Scraper"
mkdir -p "$BASE/google-maps-scraper/gmapsdata"
run_container gmaps-scraper -p 8080:8080 \
  -v "$BASE/google-maps-scraper/gmapsdata:/gmapsdata" \
  gosom/google-maps-scraper -data-folder /gmapsdata \
  && ok "Google Maps Scraper   http://localhost:8080" || fail "Google Maps Scraper"

say "2/7 Huginn"
run_container huginn -p 3001:3000 \
  -e SEED_USERNAME=admin -e SEED_PASSWORD="$HUGINN_PASSWORD" \
  ghcr.io/huginn/huginn \
  && ok "Huginn                http://localhost:3001  (admin / see CREDENTIALS.txt)" || fail "Huginn"

say "3/7 Firecrawl (first build takes 10-20 minutes)"
(
  cd "$BASE/firecrawl" || exit 1
  [ -f .env ] || printf "USE_DB_AUTHENTICATION=false\n" > .env
  docker compose up -d --build
) && ok "Firecrawl API         http://localhost:3002" || fail "Firecrawl"

say "4/7 Check If Email Exists"
run_container reacher -p 8081:8080 reacherhq/backend:latest \
  && ok "Email checker API     http://localhost:8081/v0/check_email" || fail "Email checker"

say "5/7 Remote Jobs"
if [ "$HAVE_NODE" = 1 ]; then
  if [ -f "$BASE/remote-jobs.pid" ] && kill -0 "$(cat "$BASE/remote-jobs.pid")" 2>/dev/null; then
    ok "Remote Jobs           http://localhost:8090"
  else
    (
      cd "$BASE/remote-jobs" || exit 1
      npm install --no-audit --no-fund >/dev/null 2>&1 || exit 1
      ELEVENTY_ENV=development nohup npx eleventy --serve --port=8090 \
        > "$BASE/remote-jobs.log" 2>&1 &
      echo $! > "$BASE/remote-jobs.pid"
    ) && ok "Remote Jobs           http://localhost:8090  (takes ~1 min to build)" || fail "Remote Jobs"
  fi
else
  fail "Remote Jobs (needs Node 22+)"
fi

say "6/7 Listmonk"
(
  cd "$BASE/listmonk" || exit 1
  LISTMONK_ADMIN_USER=admin LISTMONK_ADMIN_PASSWORD="$LISTMONK_PASSWORD" docker compose up -d
) && ok "Listmonk              http://localhost:9000  (admin / see CREDENTIALS.txt)" || fail "Listmonk"

say "7/7 Twenty CRM"
(
  cd "$BASE/twenty/packages/twenty-docker" || exit 1
  if [ ! -f .env ]; then
    cat > .env <<EOF
TAG=latest
PG_DATABASE_PASSWORD=$TWENTY_PG_PASSWORD
SERVER_URL=http://localhost:3000
ENCRYPTION_KEY=$TWENTY_ENCRYPTION_KEY
STORAGE_TYPE=local
EOF
  fi
  docker compose up -d
) && ok "Twenty CRM            http://localhost:3000  (create your account on first visit)" || fail "Twenty CRM"

# ---------------------------------------------------------------- summary
say "Done"
printf "%s\n" "${RESULTS[@]}"
echo
echo "Passwords:  $CREDS"
echo "Stop all:   bash $0 stop"
echo "Give each tool 1-3 minutes to finish booting before opening its link."
