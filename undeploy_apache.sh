#!/usr/bin/env bash
#
# undeploy_apache.sh — remove an app previously deployed with deploy_apache.sh
# (disables + deletes its Apache vhost, drops the port's Listen directive if
# nothing else still needs it, and optionally deletes its virtualenv).
#
# It only needs the app name: it reads the vhost file deploy_apache.sh wrote
# to figure out which port and which venv belong to it. Project code and the
# database are never touched — this only undoes the Apache/venv wiring, so
# you can safely run deploy_apache.sh again afterwards to recreate it.
#
# Usage:
#   sudo ./undeploy_apache.sh --list                 # show apps this tool manages
#   sudo ./undeploy_apache.sh -n quicktransfert       # un-host it (keeps the venv)
#   sudo ./undeploy_apache.sh -n quicktransfert --purge-venv --close-firewall
#
# Flags:
#   -n, --app-name NAME   App/vhost name to remove (as used in --app-name at deploy time)
#       --list            List apps currently managed (sites-available with a WSGIDaemonProcess)
#       --purge-venv       Also delete the app's virtualenv directory
#       --close-firewall   Also remove the ufw rule for the port, if any
#       --keep-listen      Never remove the port's Listen conf, even if unused afterwards
#   -f, --force            Skip confirmation prompt
#   -h, --help             Show this help
#
set -euo pipefail
[ -n "${BASH_VERSION:-}" ] || exec bash "$0" "$@"

c_red=$'\033[0;31m'; c_grn=$'\033[0;32m'; c_yel=$'\033[0;33m'; c_blu=$'\033[0;34m'; c_rst=$'\033[0m'
info()  { echo "${c_blu}[*]${c_rst} $*"; }
ok()    { echo "${c_grn}[OK]${c_rst} $*"; }
warn()  { echo "${c_yel}[!]${c_rst} $*"; }
die()   { echo "${c_red}[ERROR]${c_rst} $*" >&2; exit 1; }
usage() { sed -n '2,20p' "$0"; }

APP_NAME=""
DO_LIST=0
PURGE_VENV=0
CLOSE_FIREWALL=0
KEEP_LISTEN=0
FORCE=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        -n|--app-name) APP_NAME="$2"; shift 2 ;;
        --list) DO_LIST=1; shift ;;
        --purge-venv) PURGE_VENV=1; shift ;;
        --close-firewall) CLOSE_FIREWALL=1; shift ;;
        --keep-listen) KEEP_LISTEN=1; shift ;;
        -f|--force) FORCE=1; shift ;;
        -h|--help) usage; exit 0 ;;
        *) die "Unknown argument: $1 (see --help)" ;;
    esac
done

SITES_DIR="/etc/apache2/sites-available"

list_apps() {
    local f name port venv domain
    info "Apps managed by deploy_apache.sh:"
    for f in "$SITES_DIR"/*.conf; do
        [[ -f "$f" ]] || continue
        grep -q "WSGIDaemonProcess" "$f" || continue
        name="$(basename "$f" .conf)"
        port="$(grep -oP '<VirtualHost \*:\K[0-9]+' "$f" | head -1)"
        domain="$(grep -oP '^\s*ServerName\s+\K\S+' "$f" | head -1)"
        venv="$(grep -oP 'python-home=\K\S+' "$f" | head -1)"
        printf "  - %-25s domain=%-30s port=%-6s venv=%s\n" "$name" "$domain" "$port" "$venv"
    done
}

if [[ $DO_LIST -eq 1 ]]; then
    list_apps
    exit 0
fi

[[ $EUID -eq 0 ]] || die "This script needs root. Try: sudo $0 $*"
[[ -n "$APP_NAME" ]] || { list_apps; die "Pass -n/--app-name (see the list above), or use --list."; }

VHOST_FILE="$SITES_DIR/${APP_NAME}.conf"
[[ -f "$VHOST_FILE" ]] || die "No vhost found at $VHOST_FILE. Use --list to see known apps."

PORT="$(grep -oP '<VirtualHost \*:\K[0-9]+' "$VHOST_FILE" | head -1)"
DOMAIN="$(grep -oP '^\s*ServerName\s+\K\S+' "$VHOST_FILE" | head -1)"
VENV_DIR="$(grep -oP 'python-home=\K\S+' "$VHOST_FILE" | head -1)"

info "About to un-host '${APP_NAME}':"
echo "    Vhost file   : $VHOST_FILE"
echo "    Domain       : ${DOMAIN:-unknown}"
echo "    Port         : ${PORT:-unknown}"
echo "    Venv path    : ${VENV_DIR:-unknown}"
echo "    Purge venv?  : $([[ $PURGE_VENV -eq 1 ]] && echo yes || echo no)"
echo "    Close port?  : $([[ $CLOSE_FIREWALL -eq 1 ]] && echo yes || echo no)"
echo "    (project code and database are never touched)"
echo

if [[ $FORCE -ne 1 ]]; then
    read -r -p "Proceed? (y/N): " ans || true
    [[ "$ans" =~ ^[Yy]$ ]] || die "Aborted."
fi

info "Disabling site..."
a2dissite "${APP_NAME}" >/dev/null 2>&1 || warn "a2dissite failed or site was already disabled"
rm -f "$VHOST_FILE"
ok "Removed vhost: $VHOST_FILE"

if [[ -n "$PORT" && $KEEP_LISTEN -ne 1 ]]; then
    if grep -RqsE "<VirtualHost \*:${PORT}>" /etc/apache2/sites-enabled/*.conf 2>/dev/null; then
        info "Port $PORT is still used by another enabled site, leaving its Listen directive in place."
    else
        PORT_CONF="/etc/apache2/conf-available/listen-${PORT}.conf"
        if [[ -f "$PORT_CONF" ]]; then
            a2disconf "listen-${PORT}" >/dev/null 2>&1 || true
            rm -f "$PORT_CONF"
            ok "Removed Listen directive for port $PORT (no longer used)."
        fi
    fi
fi

apache2ctl configtest || die "Apache config test failed after removal — check manually before reloading."
systemctl reload apache2
ok "Apache reloaded."

if [[ $CLOSE_FIREWALL -eq 1 && -n "$PORT" ]] && command -v ufw >/dev/null 2>&1; then
    if ufw status | grep -q "Status: active"; then
        ufw delete allow "${PORT}/tcp" >/dev/null 2>&1 || warn "No matching ufw rule for ${PORT}/tcp"
        ok "Closed port $PORT in ufw."
    fi
fi

if [[ $PURGE_VENV -eq 1 && -n "$VENV_DIR" ]]; then
    if [[ -d "$VENV_DIR" ]]; then
        rm -rf "$VENV_DIR"
        ok "Deleted virtualenv: $VENV_DIR"
    else
        warn "Venv path $VENV_DIR not found, nothing to delete."
    fi
else
    [[ -n "$VENV_DIR" ]] && info "Venv kept at: $VENV_DIR (pass --purge-venv to delete it too)"
fi

echo
ok "'${APP_NAME}' is un-hosted."
echo "To recreate it, run deploy_apache.sh again from the project's directory:"
echo "  sudo ./deploy_apache.sh -p <project-dir> -e <venv-parent-dir> -N <venv-name> -d ${DOMAIN:-<domain>} -n ${APP_NAME}"
