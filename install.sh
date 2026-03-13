#!/bin/bash
set -euo pipefail

# ========================
# Usage & Inputs
# ========================
if [ $# -ne 4 ]; then
  echo "Usage: sudo ./install.sh <domain> <ip> <email_prefix> <email_password>"
  exit 1
fi

DOMAIN="$1"
IP="$2"
EMAIL_PREFIX="$3"
EMAIL_PASSWORD="$4"
DKIM_SELECTOR="default"

CONFIG_TEMPLATE="./conf/config"
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
    apache2 php \
    mysql-server php-mysql php-gd php-imap \
    unzip curl ca-certificates net-tools openssl
}

pkg_install_redhat() {
  local PM=dnf
  is_cmd yum && PM=yum
  $PM -y install \
    opendkim \
    httpd php \
    mariadb-server php-mysqlnd php-gd php-imap \
    unzip curl ca-certificates net-tools openssl
  systemctl enable mariadb || true
}

systemd_try() {
  local action="$1"; shift

  if [[ "$action" == "daemon-reload" ]]; then
    echo "[TRY] systemctl daemon-reload"
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

    echo "[TRY] systemctl $action $alt"
    systemctl "$action" "$alt" 2>/dev/null || true

    if [[ "$action" == "restart" ]]; then
      if ! systemctl is-active --quiet "$alt" 2>/dev/null; then
        echo "[FALLBACK] systemctl start $alt"
        systemctl start "$alt" 2>/dev/null || true
      fi
    fi
  done
}

ensure_pmta_user() {
  getent group pmta >/dev/null 2>&1 || groupadd -r pmta
  id -u pmta >/dev/null 2>&1 || useradd -r -g pmta -d /etc/pmta -s /usr/sbin/nologin pmta
}

safe_replace_placeholders() {
  local file="$1"
  sed -i.bak \
    -e "s/admin@domain\.com/${EMAIL_PREFIX}@${DOMAIN}/g" \
    -e "s/domain\.com/${DOMAIN}/g" \
    -e "s/192\.168\.1\.13/${IP}/g" \
    -e "s/vip250/${EMAIL_PASSWORD}/g" \
    "$file"
}

pmta_config_test() {
  echo "[STEP] Config test"
  if pmta test config >/dev/null 2>&1; then
    if ! pmta test config; then
      echo "[ERR] pmta test config failed."
      return 1
    fi
  elif pmta --config-test >/dev/null 2>&1; then
    if ! pmta --config-test; then
      echo "[ERR] pmta --config-test failed."
      return 1
    fi
  else
    echo "[WARN] No known pmta config test command found; skipping."
  fi
}

# ========================
# Begin
# ========================
OS=$(detect_os)
echo "[INFO] Detected OS family: $OS"
[ "$OS" = "unknown" ] && { echo "[ERR] Unsupported OS."; exit 1; }

mkdir -p /etc/pmta
mkdir -p /etc/pmta/tls
mkdir -p /var/log/pmta/acct-archive
ensure_pmta_user

# Config template
if [ ! -f /etc/pmta/config ]; then
  [ -f "$CONFIG_TEMPLATE" ] || { echo "[ERR] Missing template $CONFIG_TEMPLATE"; exit 1; }
  echo "[STEP] Creating /etc/pmta/config from template"
  cp -f "$CONFIG_TEMPLATE" /etc/pmta/config
  safe_replace_placeholders /etc/pmta/config
else
  echo "[INFO] /etc/pmta/config exists; will NOT overwrite."
fi

# Dependencies
echo "[STEP] Installing dependencies"
if [ "$OS" = "debian" ]; then
  pkg_install_debian
else
  pkg_install_redhat
fi

# DKIM
echo "[STEP] Generating DKIM keys"
DKIM_DIR="/etc/pmta"
pushd "$DKIM_DIR" >/dev/null
rm -f "${DKIM_SELECTOR}.private" "${DKIM_SELECTOR}.txt" || true
opendkim-genkey -s "$DKIM_SELECTOR" -d "$DOMAIN"
mv "${DKIM_SELECTOR}.private" "${DOMAIN}-dkim.key"
mv "${DKIM_SELECTOR}.txt"     "${DOMAIN}-dkim.txt"
chmod 600 "${DOMAIN}-dkim.key"
popd >/dev/null
echo "[OK] DKIM key: ${DKIM_DIR}/${DOMAIN}-dkim.key"
echo "[OK] DKIM TXT: ${DKIM_DIR}/${DOMAIN}-dkim.txt"

# TLS Self-signed Certificate
echo "[STEP] Generating self-signed TLS certificate"
TLS_DIR="/etc/pmta/tls"
openssl req -new -x509 -nodes -days 3650 \
  -keyout "${TLS_DIR}/${DOMAIN}.key" \
  -out "${TLS_DIR}/${DOMAIN}.crt" \
  -subj "/CN=${DOMAIN}" 2>/dev/null
cat "${TLS_DIR}/${DOMAIN}.crt" "${TLS_DIR}/${DOMAIN}.key" > "${TLS_DIR}/${DOMAIN}.pem"
chmod 600 "${TLS_DIR}/${DOMAIN}.key" "${TLS_DIR}/${DOMAIN}.pem"
echo "[OK] TLS cert: ${TLS_DIR}/${DOMAIN}.pem"

# Permissions
chown -R pmta:pmta /etc/pmta || true

# Unzip PMTA
[ -f "$PMTA_ZIP" ] || { echo "[ERR] Missing $PMTA_ZIP"; exit 1; }
echo "[STEP] Unzipping $PMTA_ZIP"
rm -rf "$PMTA_EXTRACT_DIR"
unzip -q "$PMTA_ZIP"

# Stop services
systemd_try stop pmta pmtahttp pmtahttpd

# Install PowerMTA
echo "[STEP] Installing PowerMTA"
pushd "$PMTA_EXTRACT_DIR" >/dev/null
if [ "$OS" = "debian" ]; then
  DEB_FILE=$(ls -1 *.deb 2>/dev/null | head -n1 || true)
  if [ -n "${DEB_FILE:-}" ]; then
    echo "[INFO] Installing $DEB_FILE (keep existing /etc/pmta/config)"
    apt-get install -y -o Dpkg::Options::="--force-confold" "./$DEB_FILE"
  else
    RPM_FILE=$(ls -1 *.rpm 2>/dev/null | head -n1 || true)
    if [ -n "${RPM_FILE:-}" ]; then
      echo "[WARN] No .deb found; converting rpm via alien (keep config)"
      apt-get install -y alien
      alien -i "$RPM_FILE"
    else
      echo "[ERR] No PowerMTA package (*.deb or *.rpm) found."
      exit 1
    fi
  fi
else
  local_pm=dnf
  is_cmd yum && local_pm=yum
  RPM_FILE=$(ls -1 *.rpm 2>/dev/null | head -n1 || true)
  [ -n "${RPM_FILE:-}" ] || { echo "[ERR] No RPM found for RHEL/CentOS."; exit 1; }
  $local_pm -y install "./$RPM_FILE"
fi

[ -f usr/sbin/pmtad ]     && cp -f usr/sbin/pmtad /usr/sbin/pmtad
[ -f usr/sbin/pmtahttpd ] && cp -f usr/sbin/pmtahttpd /usr/sbin/pmtahttpd
popd >/dev/null

cp -f "${PMTA_EXTRACT_DIR}/license" /etc/pmta/license 2>/dev/null || true
chown pmta:pmta /etc/pmta/license 2>/dev/null || true
chmod 600 /etc/pmta/license 2>/dev/null || true

# Permissions & config test
chown -R pmta:pmta /etc/pmta || true
if is_cmd pmta; then
  pmta_config_test || true
fi

# Start
echo "[STEP] Starting PMTA services"
systemd_try daemon-reload
systemd_try enable pmta pmtahttp pmtahttpd
systemd_try restart pmta pmtahttp pmtahttpd

# Status
echo "[STEP] Service status"
systemctl --no-pager --full status pmta || true
echo "[STEP] Listening ports"
is_cmd netstat && netstat -tulnp | grep -E ":25|:587|:2525" || true

echo
echo "============================ DKIM TXT (add to DNS) ============================"
cat "${DKIM_DIR}/${DOMAIN}-dkim.txt" || true
echo "==============================================================================="
echo "[DONE] PowerMTA installation finished."
echo "[INFO] Config : /etc/pmta/config"
echo "[INFO] License: /etc/pmta/license"
echo "[INFO] TLS    : ${TLS_DIR}/${DOMAIN}.pem"
