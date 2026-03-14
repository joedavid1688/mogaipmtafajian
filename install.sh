#!/bin/bash
set -euo pipefail

# ========================
# Usage
# ========================
# install2.sh <domain> <internal_ip> <password> <dkim_selector> <panel_port|0> <tls:yes|no>
#
# panel_port=0  -> panel disabled
# panel_port=N  -> panel enabled on port N
# tls=yes       -> generate TLS cert, use-starttls yes
# tls=no        -> skip TLS cert, use-starttls no

if [ $# -ne 6 ]; then
  echo "Usage: bash install2.sh <domain> <internal_ip> <password> <dkim_selector> <panel_port|0> <tls:yes|no>"
  exit 1
fi

DOMAIN="$1"
INTERNAL_IP="$2"
PASSWORD="$3"
DKIM_SELECTOR="$4"
PANEL_PORT="$5"
USE_TLS="$6"

CONFIG_TEMPLATE="./conf/config2"
PMTA_ZIP="./pmta5.0r3.zip"
PMTA_EXTRACT_DIR="pmta5.0r3"

export DEBIAN_FRONTEND=noninteractive

# ========================
# Helpers
# ========================
is_cmd() { command -v "$1" >/dev/null 2>&1; }

detect_os() {
  if [ -f /etc/debian_version ] && is_cmd apt-get; then
    echo "debian"
  elif [ -f /etc/redhat-release ] && (is_cmd yum || is_cmd dnf); then
    echo "redhat"
  else
    echo "unknown"
  fi
}

pkg_install_debian() {
  apt-get update
  apt-get install -y --no-install-recommends \
    opendkim opendkim-tools \
    unzip curl ca-certificates net-tools openssl
}

pkg_install_redhat() {
  local PM=dnf
  is_cmd yum && PM=yum
  $PM -y install \
    opendkim \
    unzip curl ca-certificates net-tools openssl
}

systemd_try() {
  local action="$1"; shift

  if [[ "$action" == "daemon-reload" ]]; then
    systemctl daemon-reload 2>/dev/null || true
    return 0
  fi

  if [[ "$action" == "enable" ]]; then
    systemctl daemon-reload 2>/dev/null || true
  fi

  local svc alt
  for svc in "$@"; do
    alt="$svc"
    [[ "$svc" == "pmtahttp" ]] && alt="pmtahttpd"
    systemctl "$action" "$alt" 2>/dev/null || true
    if [[ "$action" == "restart" ]]; then
      if ! systemctl is-active --quiet "$alt" 2>/dev/null; then
        systemctl start "$alt" 2>/dev/null || true
      fi
    fi
  done
}

ensure_pmta_user() {
  getent group pmta >/dev/null 2>&1 || groupadd -r pmta
  id -u pmta >/dev/null 2>&1 || useradd -r -g pmta -d /etc/pmta -s /usr/sbin/nologin pmta
}

# ========================
# Begin
# ========================
OS=$(detect_os)
echo "[INFO] OS: $OS"
[ "$OS" = "unknown" ] && { echo "[ERR] Unsupported OS."; exit 1; }

mkdir -p /etc/pmta/dkim
mkdir -p /etc/pmta/tls
mkdir -p /var/log/pmta
mkdir -p /var/spool/pmta
ensure_pmta_user

# ========================
# Config from template
# ========================
if [ ! -f /etc/pmta/config ]; then
  [ -f "$CONFIG_TEMPLATE" ] || { echo "[ERR] Missing $CONFIG_TEMPLATE"; exit 1; }
  echo "[STEP] Creating /etc/pmta/config from config2 template"
  cp -f "$CONFIG_TEMPLATE" /etc/pmta/config

  # Panel toggle
  if [ "$PANEL_PORT" = "0" ]; then
    # Panel disabled: comment out http-access line
    sed -i "s|__HTTP_PORT__|8937|g" /etc/pmta/config
    sed -i "s|#__PANEL_TOGGLE__||g" /etc/pmta/config
    sed -i "s|^http-access|#http-access|g" /etc/pmta/config
  else
    # Panel enabled: set port and uncomment
    sed -i "s|__HTTP_PORT__|${PANEL_PORT}|g" /etc/pmta/config
    sed -i "s|#__PANEL_TOGGLE__||g" /etc/pmta/config
  fi

  # TLS toggle
  if [ "$USE_TLS" = "yes" ]; then
    sed -i "s|__USE_STARTTLS__|yes|g" /etc/pmta/config
  else
    sed -i "s|__USE_STARTTLS__|no|g" /etc/pmta/config
  fi

  # Core replacements
  sed -i "s|__DOMAIN__|${DOMAIN}|g" /etc/pmta/config
  sed -i "s|__INTERNAL_IP__|${INTERNAL_IP}|g" /etc/pmta/config
  sed -i "s|__PASSWORD__|${PASSWORD}|g" /etc/pmta/config
  sed -i "s|__DKIM_SELECTOR__|${DKIM_SELECTOR}|g" /etc/pmta/config
else
  echo "[INFO] /etc/pmta/config already exists, skipping."
fi

# ========================
# Dependencies
# ========================
echo "[STEP] Installing dependencies"
if [ "$OS" = "debian" ]; then
  pkg_install_debian
else
  pkg_install_redhat
fi

# ========================
# DKIM
# ========================
echo "[STEP] Generating DKIM key (selector: ${DKIM_SELECTOR})"
DKIM_DIR="/etc/pmta/dkim"
pushd "$DKIM_DIR" >/dev/null
rm -f "${DKIM_SELECTOR}.private" "${DKIM_SELECTOR}.txt" || true
opendkim-genkey -s "$DKIM_SELECTOR" -d "$DOMAIN"
mv "${DKIM_SELECTOR}.private" "${DOMAIN}.pem"
mv "${DKIM_SELECTOR}.txt"     "${DOMAIN}-dkim.txt"
chmod 600 "${DOMAIN}.pem"
popd >/dev/null
echo "[OK] DKIM key: ${DKIM_DIR}/${DOMAIN}.pem"
echo "[OK] DKIM TXT: ${DKIM_DIR}/${DOMAIN}-dkim.txt"

# ========================
# TLS Certificate (optional)
# ========================
if [ "$USE_TLS" = "yes" ]; then
  echo "[STEP] Generating self-signed TLS certificate"
  TLS_DIR="/etc/pmta/tls"
  openssl req -new -x509 -nodes -days 3650 \
    -keyout "${TLS_DIR}/${DOMAIN}.key" \
    -out "${TLS_DIR}/${DOMAIN}.crt" \
    -subj "/CN=${DOMAIN}" 2>/dev/null
  cat "${TLS_DIR}/${DOMAIN}.crt" "${TLS_DIR}/${DOMAIN}.key" > "${TLS_DIR}/${DOMAIN}.pem"
  chmod 600 "${TLS_DIR}/${DOMAIN}.key" "${TLS_DIR}/${DOMAIN}.pem"
  echo "[OK] TLS cert: ${TLS_DIR}/${DOMAIN}.pem"
else
  echo "[SKIP] TLS certificate generation (disabled)"
fi

# ========================
# Permissions
# ========================
chown -R pmta:pmta /etc/pmta || true

# ========================
# Unzip & Install PMTA
# ========================
[ -f "$PMTA_ZIP" ] || { echo "[ERR] Missing $PMTA_ZIP"; exit 1; }
echo "[STEP] Unzipping $PMTA_ZIP"
rm -rf "$PMTA_EXTRACT_DIR"
unzip -q "$PMTA_ZIP"

systemd_try stop pmta pmtahttp pmtahttpd

echo "[STEP] Installing PowerMTA"
pushd "$PMTA_EXTRACT_DIR" >/dev/null
if [ "$OS" = "debian" ]; then
  DEB_FILE=$(ls -1 *.deb 2>/dev/null | head -n1 || true)
  if [ -n "${DEB_FILE:-}" ]; then
    apt-get install -y -o Dpkg::Options::="--force-confold" "./$DEB_FILE"
  else
    RPM_FILE=$(ls -1 *.rpm 2>/dev/null | head -n1 || true)
    if [ -n "${RPM_FILE:-}" ]; then
      apt-get install -y alien
      alien -i "$RPM_FILE"
    else
      echo "[ERR] No PowerMTA package found."; exit 1
    fi
  fi
else
  local_pm=dnf
  is_cmd yum && local_pm=yum
  RPM_FILE=$(ls -1 *.rpm 2>/dev/null | head -n1 || true)
  [ -n "${RPM_FILE:-}" ] || { echo "[ERR] No RPM found."; exit 1; }
  $local_pm -y install "./$RPM_FILE"
fi

[ -f usr/sbin/pmtad ]     && cp -f usr/sbin/pmtad /usr/sbin/pmtad
[ -f usr/sbin/pmtahttpd ] && cp -f usr/sbin/pmtahttpd /usr/sbin/pmtahttpd
popd >/dev/null

cp -f "${PMTA_EXTRACT_DIR}/license" /etc/pmta/license 2>/dev/null || true
chown pmta:pmta /etc/pmta/license 2>/dev/null || true
chmod 600 /etc/pmta/license 2>/dev/null || true
chown -R pmta:pmta /etc/pmta || true

# ========================
# Start services
# ========================
echo "[STEP] Starting PMTA"
systemd_try daemon-reload
systemd_try enable pmta

if [ "$PANEL_PORT" != "0" ]; then
  systemd_try enable pmtahttp pmtahttpd
  systemd_try restart pmta pmtahttp pmtahttpd
else
  systemd_try restart pmta
fi

# ========================
# Status
# ========================
echo "[STEP] Service status"
systemctl --no-pager --full status pmta || true
echo "[STEP] Listening ports"
is_cmd netstat && netstat -tulnp | grep -E ":25|:2525|:${PANEL_PORT:-8937}" || true

echo
echo "============================ DKIM TXT ============================"
cat "${DKIM_DIR}/${DOMAIN}-dkim.txt" || true
echo "=================================================================="
echo "[DONE] PowerMTA installed."
echo "[INFO] Config : /etc/pmta/config"
echo "[INFO] DKIM   : ${DKIM_DIR}/${DOMAIN}.pem (selector: ${DKIM_SELECTOR})"
[ "$USE_TLS" = "yes" ] && echo "[INFO] TLS    : /etc/pmta/tls/${DOMAIN}.pem"
[ "$PANEL_PORT" != "0" ] && echo "[INFO] Panel  : http://<IP>:${PANEL_PORT}"
