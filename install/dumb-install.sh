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

# Keep this wrapper identical in ct/dumb.sh and install/dumb-install.sh.
# The subshell limits the probe override to DUMB's .NET setup only.
setup_dumb_dotnet() (
  local -A dumb_verified_repos=()
  local distro_id distro_version distro_codename repo_url

  verify_repo_available() {
    local repo_url="$1" suite="$2" cache_key="$1|$2"
    [[ "${dumb_verified_repos[$cache_key]:-}" == "yes" ]] && return 0
    if curl -fsSL --retry 2 --retry-connrefused --max-time 15 --connect-timeout 5 \
      "${repo_url}/dists/${suite}/Release" >/dev/null; then
      dumb_verified_repos[$cache_key]="yes"
      return 0
    fi
    return 1
  }

  distro_id=$(get_os_info id)
  distro_version=$(get_os_info version_id)
  distro_codename=$(get_os_info codename)
  if [[ "$distro_id" == "debian" ]]; then
    repo_url="https://packages.microsoft.com/${distro_id}/${distro_version}/prod"
    # Core removes existing sources before its probe. Check first and reuse
    # this success within this invocation, preserving sources on probe failure.
    if ! verify_repo_available "$repo_url" "$distro_codename"; then
      msg_error "Unable to reach the Microsoft .NET feed for ${distro_id} ${distro_version} (${distro_codename}); existing repository configuration was preserved"
      return 100
    fi
  fi

  DOTNET_VERSION="10" DOTNET_TYPE="sdk" setup_dotnet
)

# Keep this wrapper identical in ct/dumb.sh and install/dumb-install.sh.
# Core's Gen9+ group also contains newer UHD/Iris GPUs. Install both supported
# OpenCL families for that selected Intel stack instead of guessing its generation.
setup_dumb_hwaccel() (
  local dumb_opencl_probe=no dumb_legacy_preflight=no dumb_opencl_metadata_dir=""

  _dumb_preflight_legacy_opencl_release() {
    local repository="$1" tag="$2" metadata
    shift 2
    if [[ -z "$dumb_opencl_metadata_dir" ]]; then
      dumb_opencl_metadata_dir=$(mktemp -d) || return 100
      trap 'rm -rf -- "$dumb_opencl_metadata_dir"' EXIT
    fi
    metadata="$dumb_opencl_metadata_dir/${repository##*/}.json"
    if ! _forge_release_json github "$repository" "$tag" "" "$metadata" ||
      ! jq -e --arg tag "$tag" --arg repository "$repository" --args \
        '. as $release | .tag_name == $tag and
         all($ARGS.positional[]; . as $name |
           any($release.assets[]?; .name == $name and
             .browser_download_url == ("https://github.com/" + $repository +
               "/releases/download/" + $tag + "/" + $name)))' "$@" <"$metadata" >/dev/null; then
      msg_error "Required Intel legacy release assets are unavailable; Intel driver update stopped"
      return 100
    fi
  }

  _dumb_install_legacy_opencl_package() {
    local package="$1" version="$2" repository="$3" tag="$4" asset="$5"
    local installed
    installed=$(dpkg-query -W -f='${db:Status-Status} ${Version}' "$package" 2>/dev/null) || installed=""
    [[ "$installed" == "installed $version" ]] && return 0

    # Core's binary helper can fall back to another .deb. Check every required
    # exact asset before installing the first missing compatibility package.
    if [[ "$dumb_legacy_preflight" != yes ]]; then
      _dumb_preflight_legacy_opencl_release "intel/intel-graphics-compiler" "igc-1.0.17537.24" \
        "intel-igc-core_1.0.17537.24_amd64.deb" \
        "intel-igc-opencl_1.0.17537.24_amd64.deb" || return "$?"
      _dumb_preflight_legacy_opencl_release "intel/compute-runtime" "24.35.30872.36" \
        "intel-opencl-icd-legacy1_24.35.30872.36_amd64.deb" || return "$?"
      dumb_legacy_preflight=yes
    fi

    # Separate markers from core's IGC2 packages. A DUMB version override must
    # never replace the explicitly compatible Intel legacy release.
    FORCE_UPDATE=1 var_appversion="" fetch_and_deploy_gh_release "${package}-dumb-legacy" \
      "$repository" "binary" "$tag" "" "$asset" || {
      msg_error "Could not install $package $version; Intel driver update stopped before the current runtime was changed"
      return 100
    }
    installed=$(dpkg-query -W -f='${db:Status-Status} ${Version}' "$package" 2>/dev/null) || installed=""
    if [[ "$installed" != "installed $version" ]]; then
      msg_error "$package $version was not installed; Intel driver update stopped before the current runtime was changed"
      return 100
    fi
  }

  _dumb_prepare_legacy_opencl() {
    [[ "$1" == "debian" && ("$2" == "trixie" || "$2" == "sid") ]] || return 0
    if [[ "$(dpkg --print-architecture)" != "amd64" ]]; then
      msg_warn "Intel legacy OpenCL packages are only available for amd64; OpenCL tone mapping was not verified"
      return 0
    fi

    $STD apt install -y ocl-icd-libopencl1 clinfo || {
      msg_error "Could not prepare Intel OpenCL dependencies; Intel driver update stopped"
      return 100
    }
    # Intel maintains Gen8/9/11 support in the 24.35 legacy family. These
    # compatible releases also ship together in Jellyfin's official image.
    # https://github.com/intel/compute-runtime/blob/master/documentation/LEGACY_PLATFORMS.md
    _dumb_install_legacy_opencl_package "intel-igc-core" "1.0.17537.24" \
      "intel/intel-graphics-compiler" "igc-1.0.17537.24" \
      "intel-igc-core_1.0.17537.24_amd64.deb" || return "$?"
    _dumb_install_legacy_opencl_package "intel-igc-opencl" "1.0.17537.24" \
      "intel/intel-graphics-compiler" "igc-1.0.17537.24" \
      "intel-igc-opencl_1.0.17537.24_amd64.deb" || return "$?"
    _dumb_install_legacy_opencl_package "intel-opencl-icd-legacy1" "24.35.30872.36" \
      "intel/compute-runtime" "24.35.30872.36" \
      "intel-opencl-icd-legacy1_24.35.30872.36_amd64.deb" || return "$?"
    dumb_opencl_probe=yes
  }

  _dumb_probe_intel_opencl() {
    local platforms
    if platforms=$(timeout 20 clinfo -l 2>&1) &&
      awk '/^Platform #[0-9]+:/ { intel = tolower($0) ~ /intel.*graphics/ }
           intel && /Device #[0-9]+:/ { found = 1 }
           END { exit !found }' <<<"$platforms"; then
      msg_ok "Intel OpenCL GPU detected; HDR tone mapping still needs a Jellyfin playback test"
    else
      msg_warn "Intel OpenCL did not enumerate a GPU. QSV/VAAPI may still work; leave OpenCL tone mapping disabled until clinfo -l detects the passed-through Intel GPU"
    fi
  }

  # Scope the override to the selected core handler and this invocation. Disabled
  # passthrough, other vendors and the separate Gen6-8 handler keep core behavior.
  if ! declare -F _setup_intel_modern >/dev/null || ! declare -F _forge_release_json >/dev/null; then
    msg_error "The shared GPU helper has changed; Intel compatibility setup could not be verified"
    return 100
  fi
  eval "$(declare -f _setup_intel_modern | sed '1s/_setup_intel_modern/_dumb_core_setup_intel_modern/')"
  _setup_intel_modern() {
    _dumb_prepare_legacy_opencl "$@" || exit "$?"
    _dumb_core_setup_intel_modern "$@" || return "$?"
    if [[ "$dumb_opencl_probe" == yes ]]; then
      _dumb_probe_intel_opencl
    fi
  }

  setup_hwaccel "$@"
)

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

# Reuse core GPU selection and preserve Intel legacy OpenCL during updates.
setup_dumb_hwaccel
setup_ffmpeg
NODE_VERSION="24" NODE_MODULE="pnpm@^10" setup_nodejs
setup_go
setup_dumb_dotnet
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
# Keep package-owned Plex and Jellyfin supervisors inactive while allowing
# their Debian packages to install and update their supported unit files.
for unit in plexmediaserver.service jellyfin.service; do
  unit_path="/etc/systemd/system/${unit}"
  if [[ -L "$unit_path" && "$(readlink "$unit_path")" == "/dev/null" ]]; then
    rm -f "$unit_path"
  fi
  dropin_dir="/etc/systemd/system/${unit}.d"
  install -d -m 0755 "$dropin_dir"
  cat <<'EOF' >"${dropin_dir}/dumb-native-supervision.conf"
[Unit]
# Package maintainer scripts may enable or start this unit. Keep the
# package-owned supervisor inactive because DUMB launches the binary directly.
ConditionPathExists=/run/dumb-allow-package-services
EOF
done
systemctl daemon-reload
systemctl disable --now -q \
  plexmediaserver.service \
  jellyfin.service \
  postgresql.service 2>/dev/null || true
for unit in postgresql.service 'postgresql@.service'; do
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
