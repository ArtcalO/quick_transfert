#!/usr/bin/env bash
#
# deploy_apache.sh — deploy this Django project on a Debian/Ubuntu VPS behind
# Apache + mod_wsgi, on its own custom port, isolated in its own virtualenv.
#
# Designed to be run FROM INSIDE the project's repo on the server, once the
# code has been uploaded/cloned there. It is generic: it reads manage.py to
# find the settings/wsgi package, so the same script can be reused (copied
# into another Django repo) to host several apps side by side on one Apache,
# each on its own port and its own venv.
#
# Usage (interactive):
#   sudo ./deploy_apache.sh
#
# Usage (non-interactive):
#   sudo ./deploy_apache.sh -p /var/www/quick_transfert -e /var/www/venvs -N quick_transfert -P 8081
#
# Flags:
#   -p, --project-dir DIR   Absolute path of the project on this server (default: this script's dir)
#   -e, --venv-dir DIR      Folder that will hold the virtualenv (e.g. /var/www/venvs)
#   -N, --venv-name NAME    Name of the virtualenv to create inside --venv-dir (default: app name)
#   -P, --port PORT         TCP port Apache will listen on for this app (required)
#   -n, --app-name NAME     Identifier for vhost/log/process names (default: basename of project dir)
#   -s, --server-name NAME  Apache ServerName (default: server public IP, falls back to "_")
#       --python BIN        Python interpreter used to create the venv (default: python3)
#       --no-firewall       Do not touch ufw even if it is active
#       --no-migrate        Skip "manage.py migrate"
#       --no-collectstatic  Skip "manage.py collectstatic"
#       --force             Overwrite an existing vhost/port conf without asking
#   -h, --help              Show this help
#
set -euo pipefail

# ---------------------------------------------------------------------------
# helpers
# ---------------------------------------------------------------------------
c_red=$'\033[0;31m'; c_grn=$'\033[0;32m'; c_yel=$'\033[0;33m'; c_blu=$'\033[0;34m'; c_rst=$'\033[0m'
info()  { echo "${c_blu}[*]${c_rst} $*"; }
ok()    { echo "${c_grn}[OK]${c_rst} $*"; }
warn()  { echo "${c_yel}[!]${c_rst} $*"; }
die()   { echo "${c_red}[ERROR]${c_rst} $*" >&2; exit 1; }

usage() { sed -n '2,31p' "$0"; }

ask() {
    # ask <prompt> <default> -> echoes the answer
    local prompt="$1" default="${2:-}" answer
    if [[ -n "$default" ]]; then
        read -r -p "$prompt [$default]: " answer || true
        echo "${answer:-$default}"
    else
        read -r -p "$prompt: " answer || true
        echo "$answer"
    fi
}

# ---------------------------------------------------------------------------
# arg parsing
# ---------------------------------------------------------------------------
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
PROJECT_DIR=""
VENV_PARENT_DIR=""
VENV_NAME=""
PORT=""
APP_NAME=""
SERVER_NAME=""
PYTHON_BIN="python3"
DO_FIREWALL=1
DO_MIGRATE=1
DO_COLLECTSTATIC=1
FORCE=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        -p|--project-dir) PROJECT_DIR="$2"; shift 2 ;;
        -e|--venv-dir) VENV_PARENT_DIR="$2"; shift 2 ;;
        -N|--venv-name) VENV_NAME="$2"; shift 2 ;;
        -P|--port) PORT="$2"; shift 2 ;;
        -n|--app-name) APP_NAME="$2"; shift 2 ;;
        -s|--server-name) SERVER_NAME="$2"; shift 2 ;;
        --python) PYTHON_BIN="$2"; shift 2 ;;
        --no-firewall) DO_FIREWALL=0; shift ;;
        --no-migrate) DO_MIGRATE=0; shift ;;
        --no-collectstatic) DO_COLLECTSTATIC=0; shift ;;
        --force) FORCE=1; shift ;;
        -h|--help) usage; exit 0 ;;
        *) die "Unknown argument: $1 (see --help)" ;;
    esac
done

[[ $EUID -eq 0 ]] || die "This script needs root (it edits /etc/apache2 and runs apt). Try: sudo $0 $*"

command -v apt-get >/dev/null 2>&1 || die "This script targets Debian/Ubuntu (apt-get not found)."

# ---------------------------------------------------------------------------
# step 1: project path on the server
# ---------------------------------------------------------------------------
if [[ -z "$PROJECT_DIR" ]]; then
    PROJECT_DIR="$(ask "Path of this project on the server" "$SCRIPT_DIR")"
fi
PROJECT_DIR="$(cd -- "$PROJECT_DIR" &>/dev/null && pwd)" || die "Project dir does not exist: $PROJECT_DIR"
[[ -f "$PROJECT_DIR/manage.py" ]] || die "No manage.py found in $PROJECT_DIR — is this a Django project root?"
ok "Project dir: $PROJECT_DIR"

# Detect the settings/wsgi package from manage.py, e.g. 'converter.settings' -> 'converter'
DJANGO_SETTINGS_MODULE="$(grep -oP "DJANGO_SETTINGS_MODULE['\"],\s*['\"]\K[^'\"]+" "$PROJECT_DIR/manage.py" || true)"
[[ -n "$DJANGO_SETTINGS_MODULE" ]] || die "Could not detect DJANGO_SETTINGS_MODULE from manage.py"
PACKAGE_NAME="${DJANGO_SETTINGS_MODULE%.settings}"
[[ -f "$PROJECT_DIR/$PACKAGE_NAME/wsgi.py" ]] || die "Expected $PROJECT_DIR/$PACKAGE_NAME/wsgi.py, not found"
ok "Detected Django package: $PACKAGE_NAME (wsgi: $PACKAGE_NAME/wsgi.py)"

APP_NAME="${APP_NAME:-$(basename "$PROJECT_DIR" | tr -c 'a-zA-Z0-9_' '-')}"

# ---------------------------------------------------------------------------
# step 2: virtualenv folder + name
# ---------------------------------------------------------------------------
if [[ -z "$VENV_PARENT_DIR" ]]; then
    VENV_PARENT_DIR="$(ask "Folder that will hold the virtualenv" "$PROJECT_DIR")"
fi
if [[ -z "$VENV_NAME" ]]; then
    VENV_NAME="$(ask "Name of the virtualenv to create" "$APP_NAME-venv")"
fi
VENV_NAME="$(echo "$VENV_NAME" | tr -c 'a-zA-Z0-9_.-' '-')"
mkdir -p "$VENV_PARENT_DIR"
VENV_PARENT_DIR="$(cd -- "$VENV_PARENT_DIR" &>/dev/null && pwd)" || die "Could not create/access venv folder: $VENV_PARENT_DIR"
VENV_DIR="$VENV_PARENT_DIR/$VENV_NAME"

# ---------------------------------------------------------------------------
# step 3: port
# ---------------------------------------------------------------------------
if [[ -z "$PORT" ]]; then
    PORT="$(ask "Port for Apache to serve this app on" "8080")"
fi
[[ "$PORT" =~ ^[0-9]+$ ]] || die "Port must be numeric: $PORT"

if [[ -z "$SERVER_NAME" ]]; then
    SERVER_NAME="$(curl -fsS -m 3 https://ifconfig.me 2>/dev/null || curl -fsS -m 3 https://api.ipify.org 2>/dev/null || echo "")"
    SERVER_NAME="${SERVER_NAME:-_}"
fi

info "Summary:"
echo "    App name     : $APP_NAME"
echo "    Project dir  : $PROJECT_DIR"
echo "    Venv folder  : $VENV_PARENT_DIR"
echo "    Venv name    : $VENV_NAME"
echo "    Venv path    : $VENV_DIR"
echo "    Port         : $PORT"
echo "    Server name  : $SERVER_NAME"
echo "    Python       : $PYTHON_BIN"
echo

# ---------------------------------------------------------------------------
# system packages
# ---------------------------------------------------------------------------
info "Installing/checking system packages (apache2, mod_wsgi, venv)..."
apt-get update -qq
apt-get install -y -qq apache2 libapache2-mod-wsgi-py3 "${PYTHON_BIN}-venv" "${PYTHON_BIN}-pip" >/dev/null
a2enmod wsgi >/dev/null
ok "System packages ready."

# ---------------------------------------------------------------------------
# virtualenv + dependencies
# ---------------------------------------------------------------------------
if [[ -d "$VENV_DIR" ]]; then
    info "Reusing existing virtualenv at $VENV_DIR"
else
    info "Creating virtualenv at $VENV_DIR"
    "$PYTHON_BIN" -m venv "$VENV_DIR"
fi

info "Installing requirements.txt into the venv..."
"$VENV_DIR/bin/pip" install --upgrade pip -q
if [[ -f "$PROJECT_DIR/requirements.txt" ]]; then
    "$VENV_DIR/bin/pip" install -q -r "$PROJECT_DIR/requirements.txt"
else
    warn "No requirements.txt found in $PROJECT_DIR, skipping pip install."
fi
ok "Virtualenv ready."

# ---------------------------------------------------------------------------
# django management commands
# ---------------------------------------------------------------------------
export DJANGO_SETTINGS_MODULE
if [[ $DO_MIGRATE -eq 1 ]]; then
    info "Running migrations..."
    (cd "$PROJECT_DIR" && "$VENV_DIR/bin/python" manage.py migrate --noinput)
fi
if [[ $DO_COLLECTSTATIC -eq 1 ]]; then
    info "Collecting static files..."
    (cd "$PROJECT_DIR" && "$VENV_DIR/bin/python" manage.py collectstatic --noinput) || warn "collectstatic failed, continuing"
fi

mkdir -p "$PROJECT_DIR/media" "$PROJECT_DIR/static"

# ---------------------------------------------------------------------------
# permissions: www-data needs to run the app and write to media/db
# ---------------------------------------------------------------------------
info "Fixing ownership for www-data..."
chown -R www-data:www-data "$PROJECT_DIR/media" "$PROJECT_DIR/static" 2>/dev/null || true
[[ -f "$PROJECT_DIR/db.sqlite3" ]] && chown www-data:www-data "$PROJECT_DIR/db.sqlite3"
# www-data needs to traverse into the project dir
chmod o+x "$PROJECT_DIR" 2>/dev/null || true

# ---------------------------------------------------------------------------
# Listen <port> — one small conf per port, only added once
# ---------------------------------------------------------------------------
PORT_CONF="/etc/apache2/conf-available/listen-${PORT}.conf"
if grep -RqsE "^[[:space:]]*Listen[[:space:]]+${PORT}([[:space:]]|$)" /etc/apache2/ports.conf /etc/apache2/conf-enabled/*.conf 2>/dev/null; then
    info "Port $PORT is already declared to Apache, skipping Listen directive."
else
    info "Registering 'Listen $PORT' with Apache."
    echo "Listen ${PORT}" > "$PORT_CONF"
    a2enconf "listen-${PORT}" >/dev/null
fi

# ---------------------------------------------------------------------------
# vhost
# ---------------------------------------------------------------------------
VHOST_FILE="/etc/apache2/sites-available/${APP_NAME}.conf"
if [[ -f "$VHOST_FILE" && $FORCE -ne 1 ]]; then
    ans="$(ask "Vhost $VHOST_FILE already exists. Overwrite? (y/N)" "N")"
    [[ "$ans" =~ ^[Yy]$ ]] || die "Aborted: not overwriting existing vhost. Re-run with --force to skip this prompt."
fi

cat > "$VHOST_FILE" <<EOF
<VirtualHost *:${PORT}>
    ServerName ${SERVER_NAME}

    WSGIDaemonProcess ${APP_NAME} python-home=${VENV_DIR} python-path=${PROJECT_DIR}
    WSGIProcessGroup ${APP_NAME}
    WSGIScriptAlias / ${PROJECT_DIR}/${PACKAGE_NAME}/wsgi.py process-group=${APP_NAME}

    <Directory ${PROJECT_DIR}/${PACKAGE_NAME}>
        <Files wsgi.py>
            Require all granted
        </Files>
    </Directory>

    Alias /static/ ${PROJECT_DIR}/static/
    <Directory ${PROJECT_DIR}/static>
        Require all granted
    </Directory>

    Alias /media/ ${PROJECT_DIR}/media/
    <Directory ${PROJECT_DIR}/media>
        Require all granted
    </Directory>

    ErrorLog \${APACHE_LOG_DIR}/${APP_NAME}_error.log
    CustomLog \${APACHE_LOG_DIR}/${APP_NAME}_access.log combined
</VirtualHost>
EOF
ok "Wrote vhost: $VHOST_FILE"

a2ensite "${APP_NAME}" >/dev/null
apache2ctl configtest || die "Apache config test failed — check $VHOST_FILE"
systemctl reload apache2
ok "Apache reloaded, site enabled."

# ---------------------------------------------------------------------------
# firewall
# ---------------------------------------------------------------------------
if [[ $DO_FIREWALL -eq 1 ]] && command -v ufw >/dev/null 2>&1; then
    if ufw status | grep -q "Status: active"; then
        info "Opening port $PORT in ufw..."
        ufw allow "${PORT}/tcp" >/dev/null
    fi
fi

echo
ok "Deployed. App should be reachable at: http://${SERVER_NAME}:${PORT}/"
echo
echo "Next steps:"
echo "  - Create a Django superuser if needed:"
echo "      sudo -u www-data ${VENV_DIR}/bin/python ${PROJECT_DIR}/manage.py createsuperuser"
echo "  - settings.py currently has DEBUG = True and a hardcoded SECRET_KEY;"
echo "    for a real production deployment, flip DEBUG to False and move"
echo "    SECRET_KEY/EMAIL credentials to environment variables."
echo "  - To host another app on this same server, copy this script into that"
echo "    app's repo and run it again with a different --venv-name and --port."
