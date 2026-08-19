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

header_info "$APP"
variables
color
catch_errors

function update_script() {
  header_info
  check_container_storage
  check_container_resources

  local backup_dir="/opt/dumb-update-backup"
  local candidate_dir="/opt/dumb.candidate"
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
    systemctl disable --now -q \
      plexmediaserver.service \
      jellyfin.service \
      postgresql.service 2>/dev/null || true
    local unit
    for unit in plexmediaserver.service jellyfin.service postgresql.service 'postgresql@.service'; do
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

  if check_for_gh_release "dumb" "I-am-PUID-0/DUMB"; then
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

    setup_ffmpeg
    NODE_VERSION="24" NODE_MODULE="pnpm@^10" setup_nodejs
    setup_go
    DOTNET_VERSION="10" DOTNET_TYPE="sdk" setup_dotnet
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
      CLEAN_INSTALL=1 fetch_and_deploy_gh_release "dumb" "I-am-PUID-0/DUMB" "tarball" "latest" "$candidate_dir"

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
    trap - INT TERM
    rm -rf "$backup_dir"
    msg_ok "Started and verified updated DUMB controller"
    msg_ok "Updated Successfully!"
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
