#!/usr/bin/env bash
# Engine comes from community-scripts/core; this repo only ships the scripts.
# A local core checkout wins (COMMUNITY_SCRIPTS_CORE_DIR, else a sibling ../core),
# so a fork or branch of core can be tested without editing this file.
_cs_boot="${COMMUNITY_SCRIPTS_CORE_DIR:-$(dirname "${BASH_SOURCE[0]}")/../../core}/core/build.func"
source "$_cs_boot" 2>/dev/null || source <(curl -fsSL "${COMMUNITY_SCRIPTS_CORE_URL:-https://raw.githubusercontent.com/community-scripts/core/main}/core/build.func")

# Copyright (c) 2021-2026 community-scripts ORG
# Author: I-am-PUID-0
# License: MIT | https://github.com/community-scripts/ProxmoxVED/raw/main/LICENSE
# Source: https://github.com/I-am-PUID-0/DUMB

APP="DUMB"
var_tags="${var_tags:-media;arr;debrid;usenet}"
var_cpu="${var_cpu:-4}"
var_ram="${var_ram:-8192}"
var_disk="${var_disk:-40}"
var_os="${var_os:-debian}"
var_version="${var_version:-13}"
var_arm64="${var_arm64:-yes}"
var_unprivileged="${var_unprivileged:-1}"
var_fuse="${var_fuse:-yes}"
var_gpu="${var_gpu:-yes}"
export var_dumb_branch="${var_dumb_branch:-latest}"

header_info "$APP"
variables
color
catch_errors

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

function update_script() {
  header_info
  check_container_storage
  check_container_resources

  local backup_dir="/opt/dumb-update-backup"
  local candidate_dir="/opt/dumb.candidate"
  local controller_source_file="/etc/dumb/controller-source"
  local controller_source="release"
  local controller_branch=""
  local source_changed=0
  local update_available=0
  local update_check_status=0
  local marker_created=0
  local activated=0
  local ready=0
  BACKUP_DIR="$backup_dir"
  export BACKUP_DIR

  configure_native_supervision() {
    install -d -m 0755 /etc/systemd/logind.conf.d
    cat <<'EOF' >/etc/systemd/logind.conf.d/dumb.conf
[Login]
# DUMB-managed services run as the configured PUID, which is normally a
# regular login UID. Keep systemd-logind from deleting PostgreSQL POSIX shared
# memory when a transient setup session for that UID ends.
RemoveIPC=no
EOF
    systemctl reload systemd-logind
    local unit unit_path dropin_dir
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
  }

  reconcile_pgadmin_runtime() {
    local passlib_pwd
    if [[ ! -x /pgadmin/venv/bin/python ]]; then
      return
    fi
    passlib_pwd=$(find /pgadmin/venv/lib -path '*/site-packages/passlib/pwd.py' -type f -print -quit)
    if [[ -z "$passlib_pwd" ]]; then
      msg_error "The pgAdmin Passlib runtime was not found"
      exit 1
    fi
    if grep -qxF 'import pkg_resources' "$passlib_pwd"; then
      sed -i \
        -e 's/^import pkg_resources$/from importlib import resources/' \
        -e 's/return pkg_resources\.resource_stream(package, subpath)/return resources.files(package).joinpath(subpath).open("rb")/' \
        "$passlib_pwd"
    fi
    if grep -qF 'pkg_resources' "$passlib_pwd"; then
      msg_error "Failed to apply the pgAdmin Passlib compatibility fix"
      exit 1
    fi
    $STD /pgadmin/venv/bin/python -c 'from passlib.pwd import genword; assert genword(entropy=12)'
  }

  reconcile_zurg_support_files() {
    local source_dir="/tmp/dumb-zurg-support"
    if [[ -s /zurg/config.yml && -s /zurg/plex_update.sh ]]; then
      return
    fi

    CLEAN_INSTALL=1 fetch_and_deploy_gh_branch "dumb-zurg-support" "debridmediamanager/zurg-public" "main" "$source_dir"
    if [[ ! -s "$source_dir/config.yml" || ! -s "$source_dir/scripts/plex_update.sh" ]]; then
      msg_error "The Zurg support files were not found in the downloaded source"
      exit 1
    fi

    install -d -m 0755 /zurg
    if [[ ! -s /zurg/config.yml ]]; then
      install -m 0644 "$source_dir/config.yml" /zurg/config.yml
      sed -i 's/^on_library_update: sh plex_update.sh.*$/# &/' /zurg/config.yml
    fi
    if [[ ! -s /zurg/plex_update.sh ]]; then
      install -m 0755 "$source_dir/scripts/plex_update.sh" /zurg/plex_update.sh
    fi
    rm -rf "$source_dir"
  }

  resolve_controller_source() {
    local requested="${1:-latest}"
    case "${requested,,}" in
      "" | latest | release | stable)
        controller_source="release"
        controller_branch=""
        ;;
      *)
        controller_branch="${requested#branch:}"
        ensure_dependencies git
        if ! git check-ref-format --branch "$controller_branch" >/dev/null 2>&1; then
          msg_error "Invalid DUMB controller branch: ${controller_branch}"
          return 1
        fi
        controller_source="branch:${controller_branch}"
        ;;
    esac
  }

  persist_controller_source() {
    install -d -m 0755 /etc/dumb
    cat <<EOF >"$controller_source_file"
${controller_source}
EOF
    chmod 0644 "$controller_source_file"
  }

  rollback_dumb_update() {
    local reason="$1"
    msg_warn "$reason"
    rm -rf "$candidate_dir"

    if ((activated)); then
      systemctl stop dumb 2>/dev/null || true
    fi
    restore_backup
    ((marker_created)) && rm -f /root/.dumb

    if ((activated)); then
      msg_info "Starting previous DUMB controller"
      if ! systemctl start dumb; then
        msg_error "Rollback restored the previous files but DUMB did not start"
        exit 1
      fi
      ready=0
      for _ in {1..90}; do
        if ! systemctl is-active --quiet dumb; then
          break
        fi
        if curl -fsS http://127.0.0.1:8000/health 2>/dev/null | jq -e '.status == "healthy"' >/dev/null; then
          ready=1
          break
        fi
        sleep 2
      done
      if ((ready)); then
        msg_ok "Rolled back to the previous DUMB controller"
      else
        msg_error "Rollback restored the previous files but health verification failed"
      fi
    else
      msg_ok "Kept the running DUMB controller unchanged"
    fi
    exit 1
  }

  if [[ ! -d /opt/dumb ]]; then
    msg_error "No ${APP} Installation Found!"
    exit
  fi

  msg_info "Reconciling DUMB Native Service Supervision"
  configure_native_supervision
  msg_ok "Reconciled DUMB Native Service Supervision"

  msg_info "Reconciling pgAdmin Runtime"
  reconcile_pgadmin_runtime
  msg_ok "Reconciled pgAdmin Runtime"

  msg_info "Reconciling Zurg Support Files"
  reconcile_zurg_support_files
  msg_ok "Reconciled Zurg Support Files"

  if [[ -f "$backup_dir/.manifest" ]]; then
    msg_warn "Recovering an interrupted DUMB controller update"
    if grep -qxF /opt/dumb "$backup_dir/.manifest"; then
      systemctl stop dumb 2>/dev/null || true
      restore_backup
      systemctl start dumb
    else
      restore_backup
    fi
    rm -rf "$candidate_dir"
    msg_ok "Recovered the previous DUMB controller state"
  fi

  local configured_source="release"
  if [[ -f "$controller_source_file" ]]; then
    IFS= read -r configured_source <"$controller_source_file" || configured_source="release"
  fi
  if ! resolve_controller_source "$configured_source"; then
    exit 1
  fi
  configured_source="$controller_source"

  if [[ -v DUMB_CONTROLLER_BRANCH ]]; then
    if ! resolve_controller_source "$DUMB_CONTROLLER_BRANCH"; then
      exit 1
    fi
  fi
  [[ "$controller_source" != "$configured_source" ]] && source_changed=1

  if [[ -n "$controller_branch" ]]; then
    if check_for_gh_branch "dumb" "I-am-PUID-0/DUMB" "$controller_branch"; then
      update_available=1
    else
      update_check_status=$?
    fi
  elif check_for_gh_release "dumb" "I-am-PUID-0/DUMB"; then
    update_available=1
  else
    update_check_status=$?
  fi

  if ((update_check_status != 0 && update_check_status != 1)); then
    exit 1
  fi
  ((source_changed)) && update_available=1

  if ((update_available)); then
    msg_info "Reconciling DUMB System Dependencies"
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
      python3-venv \
      postgresql-server-dev-16 \
      postgresql-contrib-16 \
      pgagent
    msg_ok "Reconciled DUMB System Dependencies"

    # Reuse the engine's vendor-specific drivers and Debian non-free setup.
    ENABLE_GPU="${ENABLE_GPU:-yes}" setup_hwaccel
    setup_ffmpeg
    NODE_VERSION="24" NODE_MODULE="pnpm@^10" setup_nodejs
    setup_go
    setup_dumb_dotnet
    UV_PYTHON_INSTALL_DIR="/opt/dumb-python" PYTHON_VERSION="3.11" setup_uv

    UV_PYTHON_INSTALL_DIR="/opt/dumb-python" PYTHON_VERSION="3.12" setup_uv
    msg_info "Reconciling DUMB Python Runtime Links"
    local python_311 python_312
    python_311=$(find /opt/dumb-python -path '*/bin/python3.11' -type f -print -quit)
    python_312=$(find /opt/dumb-python -path '*/bin/python3.12' -type f -print -quit)
    if [[ -z "$python_311" || -z "$python_312" ]]; then
      msg_error "Required DUMB Python runtimes were not found"
      exit 1
    fi
    ln -sfn "$python_311" /usr/local/bin/python3.11
    ln -sfn "$python_312" /usr/local/bin/python3.12
    msg_ok "Reconciled DUMB Python Runtime Links"

    if [[ ! -e /root/.dumb ]]; then
      touch /root/.dumb
      marker_created=1
    fi
    create_backup /root/.dumb

    rm -rf "$candidate_dir"
    if ! (
      set -e
      if [[ -n "$controller_branch" ]]; then
        CLEAN_INSTALL=1 fetch_and_deploy_gh_branch "dumb" "I-am-PUID-0/DUMB" "$controller_branch" "$candidate_dir"
      else
        CLEAN_INSTALL=1 fetch_and_deploy_gh_release "dumb" "I-am-PUID-0/DUMB" "tarball" "latest" "$candidate_dir"
      fi

      $STD uv venv --seed --python 3.11 "$candidate_dir/venv"
      if [[ ! -x /opt/poetry/bin/poetry ]]; then
        $STD uv venv --seed --python 3.11 /opt/poetry
      fi
      $STD uv pip install --python /opt/poetry/bin/python --upgrade poetry
      cd "$candidate_dir"
      $STD env \
        VIRTUAL_ENV="$candidate_dir/venv" \
        POETRY_VIRTUALENVS_CREATE=false \
        /opt/poetry/bin/poetry install --only main --no-root --sync --no-interaction
      $STD "$candidate_dir/venv/bin/python" -m pip check
      $STD /opt/poetry/bin/poetry check
      $STD "$candidate_dir/venv/bin/python" -m compileall -q -x '/tests/' "$candidate_dir"
      $STD "$candidate_dir/venv/bin/python" -c 'import fastapi, jsonschema, psutil, uvicorn'
      [[ -s "$candidate_dir/main.py" ]]
      [[ -s "$candidate_dir/healthcheck.py" ]]
      [[ -s "$candidate_dir/utils/dumb_config.json" ]]
      [[ -s "$candidate_dir/utils/dumb_config_schema.json" ]]
    ); then
      rollback_dumb_update "The DUMB controller candidate failed validation"
    fi

    create_backup /opt/dumb

    trap 'rollback_dumb_update "The DUMB controller update was interrupted"' INT TERM
    msg_info "Activating DUMB controller update"
    systemctl stop dumb
    if ! rm -rf /opt/dumb || ! mv "$candidate_dir" /opt/dumb; then
      activated=1
      rollback_dumb_update "Failed to activate the DUMB controller candidate"
    fi
    activated=1
    msg_ok "Activated DUMB controller update"

    msg_info "Starting updated DUMB controller"
    if ! systemctl start dumb; then
      rollback_dumb_update "The updated DUMB controller did not start"
    fi
    for _ in {1..90}; do
      if ! systemctl is-active --quiet dumb; then
        break
      fi
      if curl -fsS http://127.0.0.1:8000/health 2>/dev/null | jq -e '.status == "healthy"' >/dev/null; then
        ready=1
        break
      fi
      sleep 2
    done
    if ((!ready)); then
      rollback_dumb_update "The updated DUMB controller failed health verification"
    fi
    if ! persist_controller_source; then
      rollback_dumb_update "The updated DUMB controller source selection could not be saved"
    fi
    trap - INT TERM
    rm -rf "$backup_dir"
    msg_ok "Started and verified updated DUMB controller"
    msg_ok "Updated Successfully!"
  elif ! persist_controller_source; then
    msg_error "The DUMB controller source selection could not be saved"
    exit 1
  fi
  exit
}

start
build_container
description

msg_ok "Completed Successfully!\n"
echo -e "${CREATING}${GN}${APP} setup has been successfully initialized!${CL}"
echo -e "${INFO}${YW} DUMB may need several minutes to install and start its frontend on first boot.${CL}"
echo -e "${INFO}${YW} Access it using the following URL:${CL}"
echo -e "${TAB}${GATEWAY}${BGN}http://${IP}:3005${CL}"
