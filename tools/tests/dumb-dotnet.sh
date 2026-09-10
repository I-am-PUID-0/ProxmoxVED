#!/usr/bin/env bash
set -euo pipefail
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
core_root="$(cd "${1:-$repo_root/../core}" && pwd)"
fixture_dir=$(mktemp -d)
trap 'rm -rf "$fixture_dir"' EXIT
fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}
_cs_source_func() { source "$core_root/$1"; }
source "$core_root/lib/tools.func"
original_probe=$(declare -f verify_repo_available)

for script in ct/dumb.sh install/dumb-install.sh; do
  sed -n '/^setup_dumb_dotnet() (/,/^)/p' "$repo_root/$script" >"$fixture_dir/$(basename "$script").func"
done
cmp "$fixture_dir/dumb.sh.func" "$fixture_dir/dumb-install.sh.func" || fail 'install/update wrappers differ'
source "$fixture_dir/dumb.sh.func"

msg_info() { :; }
msg_ok() { :; }
msg_error() { printf 'error: %s\n' "$*" >>"$fixture_dir/events"; }
get_os_info() {
  case "$1" in
    id) echo debian ;;
    codename) echo trixie ;;
    version_id) echo 13 ;;
  esac
}
probe_status=0
package_installed=no
curl() {
  printf 'curl %s\n' "$*" >>"$fixture_dir/events"
  return "$probe_status"
}
prepare_repository_setup() { printf 'prepare\n' >>"$fixture_dir/events"; }
setup_deb822_repo() {
  [[ "$3" == https://packages.microsoft.com/debian/13/prod && "$4" == trixie ]] || fail 'wrong Debian feed'
  printf 'repository\n' >>"$fixture_dir/events"
}
ensure_apt_working() { :; }
apt-cache() { :; }
dpkg-query() {
  [[ "$package_installed" == yes ]] || return 1
  echo 'install ok installed'
}
install_packages_with_retry() {
  [[ "$1" == dotnet-sdk-10.0 ]] || fail 'wrong SDK package'
  printf 'install\n' >>"$fixture_dir/events"
}
upgrade_packages_with_retry() {
  [[ "$1" == dotnet-sdk-10.0 ]] || fail 'wrong SDK package'
  printf 'upgrade\n' >>"$fixture_dir/events"
}
cache_installed_version() { :; }

# A cached successful probe in unchanged core would be interpreted backwards.
_REPO_CACHE['https://packages.microsoft.com/debian/13/prod|trixie']="$(date +%s)|0"
setup_dumb_dotnet || fail 'fresh Debian 13 SDK setup failed'
[[ $(grep -c '^curl ' "$fixture_dir/events") == 1 ]] || fail 'core did not reuse preflight success'
grep -qx install "$fixture_dir/events" || fail 'SDK was not installed'
grep -q -- '--retry 2 --retry-connrefused' "$fixture_dir/events" || fail 'retry options missing'
[[ "$(declare -f verify_repo_available)" == "$original_probe" ]] || fail 'probe override escaped subshell'
[[ "${dumb_verified_repos+x}" != x ]] || fail 'local cache escaped subshell'

: >"$fixture_dir/events"
package_installed=yes
setup_dumb_dotnet || fail 'SDK update failed'
grep -qx upgrade "$fixture_dir/events" || fail 'SDK was not upgraded'
[[ $(grep -c '^curl ' "$fixture_dir/events") == 1 ]] || fail 'new invocation reused stale reachability'

: >"$fixture_dir/events"
probe_status=28
status=0
setup_dumb_dotnet || status=$?
[[ $status == 100 ]] || fail 'unreachable feed did not stop setup'
if grep -Eq '^(prepare|repository|install|upgrade)$' "$fixture_dir/events"; then
  fail 'unreachable feed mutated repository or packages'
fi
[[ "$(declare -f verify_repo_available)" == "$original_probe" ]] || fail 'failed setup leaked override'
printf 'PASS: DUMB-local .NET install/update, preflight preservation, and subshell isolation against unchanged core\n'
