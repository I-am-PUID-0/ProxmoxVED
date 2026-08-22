#!/usr/bin/env bash

# Copyright (c) 2021-2026 community-scripts ORG
# Author: I-am-PUID-0
# License: MIT | https://github.com/community-scripts/ProxmoxVED/raw/main/LICENSE
# Source: https://github.com/I-am-PUID-0/DUMB

source /dev/stdin <<<"$FUNCTIONS_FILE_PATH"
color
verb_ip6
catch_errors
setting_up_container
network_check
update_os

msg_info "Installing DUMB System Dependencies"
$STD apt install -y \
  build-essential \
  pkg-config \
  libxml2-utils \
  libffi-dev \
  libpq-dev \
  libfuse-dev \
  libfuse3-dev \
  fuse3 \
  mesa-va-drivers \
  mesa-vulkan-drivers \
  vainfo \
  libcairo2-dev \
  libpango1.0-dev \
  libjpeg-dev \
  libgif-dev \
  libpixman-1-dev \
  librsvg2-dev \
  python3-dev \
  python3-venv
msg_ok "Installed DUMB System Dependencies"

setup_ffmpeg
NODE_VERSION="24" NODE_MODULE="pnpm@^10" setup_nodejs
setup_go
DOTNET_VERSION="10" DOTNET_TYPE="sdk" setup_dotnet
UV_PYTHON_INSTALL_DIR="/opt/dumb-python" PYTHON_VERSION="3.11" setup_uv

UV_PYTHON_INSTALL_DIR="/opt/dumb-python" PYTHON_VERSION="3.12" setup_uv
msg_info "Configuring DUMB Python Runtime Links"
PYTHON_311=$(find /opt/dumb-python -path '*/bin/python3.11' -type f -print -quit)
PYTHON_312=$(find /opt/dumb-python -path '*/bin/python3.12' -type f -print -quit)
[[ -n "$PYTHON_311" && -n "$PYTHON_312" ]]
ln -sfn "$PYTHON_311" /usr/local/bin/python3.11
ln -sfn "$PYTHON_312" /usr/local/bin/python3.12
msg_ok "Configured DUMB Python Runtime Links"

PG_VERSION="16" setup_postgresql
$STD apt install -y postgresql-server-dev-16 postgresql-contrib-16 pgagent
systemctl disable -q postgresql
if pg_lsclusters --no-header 2>/dev/null | awk '$1 == "16" && $2 == "main" { found=1 } END { exit !found }'; then
  systemctl stop postgresql postgresql@16-main.service
  for _ in {1..30}; do
    if ! pg_ctlcluster 16 main status &>/dev/null && [[ ! -e /var/lib/postgresql/16/main/postmaster.pid ]]; then
      break
    fi
    sleep 1
  done
  if pg_ctlcluster 16 main status &>/dev/null; then
    msg_error "The temporary PostgreSQL 16 cluster did not stop"
    exit 1
  fi
  $STD pg_dropcluster 16 main
fi

fetch_and_deploy_gh_release "system-stats" "EnterpriseDB/system_stats" "tarball" "latest" "/tmp/system_stats"
msg_info "Building PostgreSQL system_stats Extension"
cd /tmp/system_stats || exit 1
$STD make USE_PGXS=1
$STD make install USE_PGXS=1
msg_ok "Built PostgreSQL system_stats Extension"

fetch_and_deploy_gh_release "rclone" "rclone/rclone" "prebuild" "latest" "/opt/rclone" "rclone-v*-linux-$(arch_resolve amd64 arm64).zip"
install -m 0755 /opt/rclone/rclone /usr/local/bin/rclone

msg_info "Installing Zurg Support Files"
ZURG_SUPPORT_DIR="/tmp/dumb-zurg-support"
CLEAN_INSTALL=1 fetch_and_deploy_gh_branch "dumb-zurg-support" "debridmediamanager/zurg-public" "main" "$ZURG_SUPPORT_DIR"
[[ -s "$ZURG_SUPPORT_DIR/config.yml" && -s "$ZURG_SUPPORT_DIR/scripts/plex_update.sh" ]]
install -d -m 0755 /zurg
install -m 0644 "$ZURG_SUPPORT_DIR/config.yml" /zurg/config.yml
sed -i 's/^on_library_update: sh plex_update.sh.*$/# &/' /zurg/config.yml
install -m 0755 "$ZURG_SUPPORT_DIR/scripts/plex_update.sh" /zurg/plex_update.sh
rm -rf "$ZURG_SUPPORT_DIR"
msg_ok "Installed Zurg Support Files"

DUMB_CONTROLLER_BRANCH="${var_dumb_branch:-latest}"
case "${DUMB_CONTROLLER_BRANCH,,}" in
  "" | latest | release | stable)
    DUMB_CONTROLLER_BRANCH=""
    DUMB_CONTROLLER_SOURCE="release"
    ;;
  *)
    DUMB_CONTROLLER_BRANCH="${DUMB_CONTROLLER_BRANCH#branch:}"
    ensure_dependencies git
    if ! git check-ref-format --branch "$DUMB_CONTROLLER_BRANCH" >/dev/null 2>&1; then
      msg_error "Invalid DUMB controller branch: ${DUMB_CONTROLLER_BRANCH}"
      exit 1
    fi
    DUMB_CONTROLLER_SOURCE="branch:${DUMB_CONTROLLER_BRANCH}"
    ;;
esac

if [[ -n "$DUMB_CONTROLLER_BRANCH" ]]; then
  fetch_and_deploy_gh_branch "dumb" "I-am-PUID-0/DUMB" "$DUMB_CONTROLLER_BRANCH" "/opt/dumb"
else
  fetch_and_deploy_gh_release "dumb" "I-am-PUID-0/DUMB" "tarball" "latest" "/opt/dumb"
fi

msg_info "Setting up DUMB Controller Environment"
$STD uv venv --seed --python 3.11 /opt/poetry
$STD uv pip install --python /opt/poetry/bin/python poetry
$STD uv venv --seed --python 3.11 /opt/dumb/venv
cd /opt/dumb || exit 1
$STD env \
  VIRTUAL_ENV=/opt/dumb/venv \
  POETRY_VIRTUALENVS_CREATE=false \
  /opt/poetry/bin/poetry install --only main --no-root --sync --no-interaction
$STD /opt/dumb/venv/bin/python -m pip check
msg_ok "Set up DUMB Controller Environment"

install -d -m 0755 /etc/dumb
cat <<EOF >/etc/dumb/controller-source
${DUMB_CONTROLLER_SOURCE}
EOF
chmod 0644 /etc/dumb/controller-source

msg_info "Setting up pgAdmin Environment"
$STD uv venv --seed --python 3.11 /pgadmin/venv
$STD uv pip install --python /pgadmin/venv/bin/python pgadmin4
$STD uv pip check --python /pgadmin/venv/bin/python
PASSLIB_PWD=$(find /pgadmin/venv/lib -path '*/site-packages/passlib/pwd.py' -type f -print -quit)
[[ -n "$PASSLIB_PWD" ]]
if grep -qxF 'import pkg_resources' "$PASSLIB_PWD"; then
  sed -i \
    -e 's/^import pkg_resources$/from importlib import resources/' \
    -e 's/return pkg_resources\.resource_stream(package, subpath)/return resources.files(package).joinpath(subpath).open("rb")/' \
    "$PASSLIB_PWD"
fi
if grep -qF 'pkg_resources' "$PASSLIB_PWD"; then
  msg_error "Failed to apply the pgAdmin Passlib compatibility fix"
  exit 1
fi
$STD /pgadmin/venv/bin/python -c 'from passlib.pwd import genword; assert genword(entropy=12)'
msg_ok "Set up pgAdmin Environment"

msg_info "Configuring DUMB"
install -d -m 0755 \
  /config \
  /data \
  /log \
  /mnt/debrid \
  /riven/backend/data \
  /zilean/app/data \
  /cli_debrid/data \
  /cli_debrid/utilities \
  /dumb/frontend
install -d -m 0755 /etc/systemd/logind.conf.d
cat <<'EOF' >/etc/systemd/logind.conf.d/dumb.conf
[Login]
# DUMB-managed services run as the configured PUID, which is normally a
# regular login UID. Keep systemd-logind from deleting PostgreSQL POSIX shared
# memory when a transient setup session for that UID ends.
RemoveIPC=no
EOF
systemctl reload systemd-logind
# These packages normally register and start their own systemd units. DUMB is
# the process supervisor inside this dedicated LXC, so mask the distro units
# before onboarding can install them and compete for the same ports/data.
systemctl disable --now -q \
  plexmediaserver.service \
  jellyfin.service \
  postgresql.service 2>/dev/null || true
for unit in plexmediaserver.service jellyfin.service postgresql.service 'postgresql@.service'; do
  ln -sfn /dev/null "/etc/systemd/system/${unit}"
done
systemctl daemon-reload
if [[ -f /etc/fuse.conf ]]; then
  sed -i 's/^#user_allow_other/user_allow_other/' /etc/fuse.conf
  if ! grep -qxF 'user_allow_other' /etc/fuse.conf; then
    cat <<'EOF' >>/etc/fuse.conf
user_allow_other
EOF
  fi
fi
cat <<'EOF' >/etc/profile.d/dumb.sh
export PATH="/opt/dumb/venv/bin:/usr/lib/postgresql/16/bin:/usr/local/go/bin:$PATH"
EOF
msg_ok "Configured DUMB"

msg_info "Creating DUMB Service"
cat <<'EOF' >/etc/systemd/system/dumb.service
[Unit]
Description=Distributed Unlimited Media Bridge
Documentation=https://dumbarr.com
Wants=network-online.target
After=network-online.target

[Service]
Type=simple
User=root
WorkingDirectory=/opt/dumb
Environment=DUMB_PROJECT_ROOT=/opt/dumb
Environment=XDG_CONFIG_HOME=/config
Environment=TERM=xterm
Environment=LANG=C.UTF-8
Environment=LC_ALL=C.UTF-8
Environment=PATH=/opt/dumb/venv/bin:/usr/lib/postgresql/16/bin:/usr/local/go/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
ExecStart=/opt/dumb/venv/bin/python /opt/dumb/main.py
Restart=on-failure
RestartSec=5
TimeoutStopSec=180
KillMode=mixed
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF
systemctl enable -q --now dumb
msg_ok "Created DUMB Service"

motd_ssh
# DUMB is an application container. Keep the generic customizer from using the
# Debian base-image name for /usr/bin/update; it must call ct/dumb.sh so the
# controller updater (including branch selection) remains reachable.
var_os="" customize
cleanup_lxc
