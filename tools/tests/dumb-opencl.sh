#!/usr/bin/env bash
set -euo pipefail
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
core_root="$(cd "${1:-$repo_root/../core}" && pwd)"
fixture_dir=$(mktemp -d)
trap 'rm -rf "$fixture_dir"' EXIT
fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }
_cs_source_func() { source "$core_root/$1"; }
source "$core_root/lib/tools.func"
original_modern=$(declare -f _setup_intel_modern)
original_hwaccel=$(declare -f setup_hwaccel)

for script in ct/dumb.sh install/dumb-install.sh; do
  sed -n '/^setup_dumb_hwaccel() (/,/^)/p' "$repo_root/$script" >"$fixture_dir/$(basename "$script").func"
done
cmp "$fixture_dir/dumb.sh.func" "$fixture_dir/dumb-install.sh.func" || fail 'install/update wrappers differ'
source "$fixture_dir/dumb.sh.func"

# Exercise core's real GPU selection and Intel handler. Redirect only its fixed
# device-node boundary into the fixture; no host /dev nodes or packages change.
fixture_hwaccel="${original_hwaccel//\/dev\/dri/$fixture_dir/dri}"
fixture_hwaccel="${fixture_hwaccel//\/dev\/nvidia0/$fixture_dir/nvidia0}"
fixture_hwaccel="${fixture_hwaccel//\/dev\/kfd/$fixture_dir/kfd}"
eval "$fixture_hwaccel"
STD=""
ENABLE_GPU=yes
INSTALL_NVIDIA_DRIVERS=no
CTTYPE=0
var_appversion="v2.23.0"
fixture_os_id=debian
fixture_os_codename=trixie
fixture_arch=amd64
gpu_lines='00:02.0 VGA compatible controller: Intel Corporation CometLake-U GT2 [UHD Graphics] [8086:9b41] (rev 02)'
clinfo_text=$'Platform #0: Intel(R) OpenCL Graphics\n `-- Device #0: Intel(R) UHD Graphics'
fetch_failure=""
wrong_version=""
dependency_failure=no
preflight_missing=no

msg_info() { printf 'info %s\n' "$*" >>"$fixture_dir/events"; }
msg_ok() { printf 'ok %s\n' "$*" >>"$fixture_dir/events"; }
msg_warn() { printf 'warn %s\n' "$*" >>"$fixture_dir/events"; }
msg_custom() { :; }
_cs_drop_silent_record() { :; }
YW="" GN=""
msg_error() { printf 'error %s\n' "$*" >>"$fixture_dir/events"; }
get_os_info() {
  case "$1" in id) echo "$fixture_os_id";; codename) echo "$fixture_os_codename";; *) echo 13;; esac
}
lspci() { printf '%s\n' "$gpu_lines"; }
lscpu() { echo 'Vendor ID: GenuineIntel'; }
dpkg() { [[ "$1" == --print-architecture ]] || fail 'unexpected dpkg mutation'; echo "$fixture_arch"; }
dpkg-query() {
  [[ "$1" == -W ]] || fail 'unexpected dpkg-query arguments'
  local package="${*: -1}"
  [[ -f "$fixture_dir/packages/$package" ]] || return 1
  cat "$fixture_dir/packages/$package"
}
apt() {
  printf 'apt %s\n' "$*" >>"$fixture_dir/events"
  [[ "$*" != *clinfo* || "$dependency_failure" != yes ]]
}
apt-cache() { return 1; }
_add_debian_nonfree() { printf 'nonfree %s\n' "$*" >>"$fixture_dir/events"; }
_setup_gpu_permissions() { printf 'permissions %s\n' "$*" >>"$fixture_dir/events"; }
cache_installed_version() { :; }
_resolve_igc_tag() { local -n out="$1"; out=v2.42.6; }
_setup_amd_gpu() { printf 'amd\n' >>"$fixture_dir/events"; }
_setup_nvidia_gpu() { printf 'nvidia\n' >>"$fixture_dir/events"; }
timeout() {
  [[ "$1" == 20 && "$2" == clinfo && "$3" == -l ]] || fail 'OpenCL probe is not bounded'
  printf 'probe\n' >>"$fixture_dir/events"
  printf '%s\n' "$clinfo_text"
}
_forge_release_json() {
  printf 'preflight %s %s\n' "$2" "$3" >>"$fixture_dir/events"
  local assets='["intel-igc-core_1.0.17537.24_amd64.deb","intel-igc-opencl_1.0.17537.24_amd64.deb"]'
  [[ "$2" != intel/compute-runtime ]] || assets='["intel-opencl-icd-legacy1_24.35.30872.36_amd64.deb"]'
  [[ "$preflight_missing" != yes ]] || assets='[]'
  jq -n --arg repository "$2" --arg tag "$3" --argjson names "$assets" \
    '{tag_name:$tag,assets:[$names[] | {name:.,browser_download_url:("https://github.com/"+$repository+"/releases/download/"+$tag+"/"+.)}]}' >"$5"
}
fetch_and_deploy_gh_release() {
  printf 'fetch %s %s %s %s %s\n' "$1" "$2" "$3" "$4" "$6" >>"$fixture_dir/events"
  if [[ "$1" == *-dumb-legacy ]]; then
    [[ "${var_appversion:-}" == "" && "${FORCE_UPDATE:-}" == 1 ]] || fail 'DUMB app version leaked into GPU pin'
    local package="${1%-dumb-legacy}" version=1.0.17537.24
    [[ "$package" != intel-opencl-icd-legacy1 ]] || version=24.35.30872.36
    [[ "$fetch_failure" != "$package" ]] || return 22
    [[ "$wrong_version" != "$package" ]] || version=0.0
    printf 'installed %s' "$version" >"$fixture_dir/packages/$package"
  fi
}
reset_fixture() {
  rm -rf "$fixture_dir/packages" "$fixture_dir/dri"
  mkdir -p "$fixture_dir/packages" "$fixture_dir/dri"
  : >"$fixture_dir/events"
  fetch_failure=""
  wrong_version=""
  dependency_failure=no
  preflight_missing=no
  ENABLE_GPU=yes
  fixture_arch=amd64
  fixture_os_id=debian
  fixture_os_codename=trixie
  gpu_lines='00:02.0 VGA compatible controller: Intel Corporation CometLake-U GT2 [UHD Graphics] [8086:9b41] (rev 02)'
  clinfo_text=$'Platform #0: Intel(R) OpenCL Graphics\n `-- Device #0: Intel(R) UHD Graphics'
}
assert_no_legacy() {
  ! grep -q -- '-dumb-legacy\|^probe$\|clinfo' "$fixture_dir/events" || fail "$1 changed legacy OpenCL"
}
assert_stopped_before_current() {
  ! grep -qE '^fetch (libigdgmm12|intel-opencl-icd) ' "$fixture_dir/events" || fail 'current Intel runtime changed after legacy failure'
}

reset_fixture
setup_dumb_hwaccel || fail 'Gen9 Debian 13 setup failed'
[[ $(grep -c -- '-dumb-legacy ' "$fixture_dir/events") == 3 ]] || fail 'legacy package family incomplete'
grep -q 'intel-igc-core-dumb-legacy intel/intel-graphics-compiler binary igc-1.0.17537.24 intel-igc-core_1.0.17537.24_amd64.deb' "$fixture_dir/events" || fail 'wrong IGC1 selection'
grep -q 'intel-opencl-icd-legacy1-dumb-legacy intel/compute-runtime binary 24.35.30872.36 intel-opencl-icd-legacy1_24.35.30872.36_amd64.deb' "$fixture_dir/events" || fail 'wrong legacy runtime selection'
first_legacy=$(grep -n '^fetch .*legacy' "$fixture_dir/events" | tail -1 | cut -d: -f1)
first_current=$(grep -n '^fetch libigdgmm12 ' "$fixture_dir/events" | head -1 | cut -d: -f1)
((first_legacy < first_current)) || fail 'current runtime updated before legacy support'
grep -q '^fetch intel-igc-core .*intel-igc-core-2_' "$fixture_dir/events" || fail 'IGC2 was not preserved'
grep -q '^fetch intel-opencl-icd .* latest ' "$fixture_dir/events" || fail 'current runtime no longer follows core'
grep -q '^ok Intel OpenCL GPU detected' "$fixture_dir/events" || fail 'Intel device confirmation absent'
[[ "$(declare -f _setup_intel_modern)" == "$original_modern" ]] || fail 'core handler override escaped subshell'
[[ "$var_appversion" == v2.23.0 && "${dumb_opencl_probe+x}" != x ]] || fail 'GPU state escaped subshell'
! declare -F _dumb_core_setup_intel_modern >/dev/null || fail 'saved handler leaked'

: >"$fixture_dir/events"
setup_dumb_hwaccel || fail 'existing legacy runtime reconciliation failed'
! grep -q -- '-dumb-legacy ' "$fixture_dir/events" || fail 'verified installed legacy packages downloaded again'

# A stale marker cannot stand in for an actually installed package.
rm "$fixture_dir/packages/intel-opencl-icd-legacy1"
: >"$fixture_dir/events"
setup_dumb_hwaccel || fail 'missing legacy package was not repaired'
[[ $(grep -c -- '-dumb-legacy ' "$fixture_dir/events") == 1 ]] || fail 'missing package was not individually reinstalled'

reset_fixture
preflight_missing=yes
status=0
setup_dumb_hwaccel || status=$?
[[ "$status" == 100 ]] || fail 'missing exact release assets accepted'
! grep -q '^fetch ' "$fixture_dir/events" || fail 'asset preflight allowed package mutation'

for package in intel-igc-core intel-igc-opencl intel-opencl-icd-legacy1; do
  reset_fixture
  fetch_failure="$package"
  status=0
  setup_dumb_hwaccel || status=$?
  [[ "$status" == 100 ]] || fail "$package failure did not stop setup"
  assert_stopped_before_current
done

reset_fixture
wrong_version=intel-opencl-icd-legacy1
status=0
setup_dumb_hwaccel || status=$?
[[ "$status" == 100 ]] || fail 'wrong installed legacy version accepted'
assert_stopped_before_current

reset_fixture
dependency_failure=yes
status=0
setup_dumb_hwaccel || status=$?
[[ "$status" == 100 ]] || fail 'failed OpenCL dependencies accepted'
assert_stopped_before_current

for probe_result in "" "Platform #0: Intel(R) OpenCL Graphics" $'Platform #0: Other OpenCL\n `-- Device #0: Other GPU' $'Platform #0: Intel(R) OpenCL CPU Runtime\n `-- Device #0: Intel(R) CPU'; do
  reset_fixture
  clinfo_text="$probe_result"
  setup_dumb_hwaccel || fail 'missing runtime platform should warn, not disable VAAPI'
  grep -q '^warn Intel OpenCL did not enumerate a GPU' "$fixture_dir/events" || fail 'missing OpenCL platform was silent'
  ! grep -q '^ok Intel OpenCL GPU detected' "$fixture_dir/events" || fail 'package presence claimed GPU success'
done

reset_fixture
gpu_lines=$'00:02.0 VGA compatible controller: Intel Corporation CometLake-U GT2 [UHD Graphics] [8086:9b41]\n00:03.0 Display controller: Intel Corporation TigerLake-LP GT2 [Iris Xe Graphics] [8086:9a49]'
setup_dumb_hwaccel || fail 'mixed Intel generations failed'
[[ $(grep -c -- '-dumb-legacy ' "$fixture_dir/events") == 3 ]] || fail 'mixed Intel GPUs did not reuse legacy family'

for scenario in disabled no-device amd nvidia arc old-intel bookworm ubuntu arm64; do
  reset_fixture
  case "$scenario" in
    disabled) ENABLE_GPU=no ;;
    no-device) rmdir "$fixture_dir/dri" ;;
    amd) gpu_lines='00:01.0 VGA compatible controller: Advanced Micro Devices, Inc. [AMD/ATI] Radeon [1002:67df]' ;;
    nvidia) gpu_lines='00:01.0 VGA compatible controller: NVIDIA Corporation GPU [10de:1fb8]' ;;
    arc) gpu_lines='00:01.0 VGA compatible controller: Intel Corporation Arc A380 [8086:56a5]' ;;
    old-intel) gpu_lines='00:02.0 VGA compatible controller: Intel Corporation HD Graphics 4600 [8086:0416]' ;;
    bookworm) fixture_os_codename=bookworm ;;
    ubuntu) fixture_os_id=ubuntu; fixture_os_codename=noble ;;
    arm64) fixture_arch=arm64 ;;
  esac
  setup_dumb_hwaccel || fail "$scenario setup failed"
  assert_no_legacy "$scenario"
done
printf 'PASS: DUMB Intel legacy/current coexistence, failure preservation, selected GPU routing, bounded device probe and install/update parity against unchanged core\n'
