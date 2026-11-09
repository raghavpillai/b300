#!/usr/bin/env bash
# =============================================================================
#  b300-setup v2: bring-up, tuning, pre-flight + diagnostics for NVIDIA DGX B300
#
#      curl -sL is.gd/b300sh | sudo bash                    # install everything
#      curl -sL is.gd/b300sh | sudo bash -s -- --check      # read-only pre-flight
#
#  After the first run the tool lives at /usr/local/sbin/b300-setup:
#      b300-setup --check     read-only pre-flight / health report (changes nothing)
#      b300-setup --test      health report + functional tests (GPU, NCCL, vLLM)
#      b300-setup -f          re-attach to a running install (survives SSH drops)
#      b300-setup -s          step status       b300-setup --reset   redo all steps
#
#  Built for a factory DGX B300 (DGX OS 7): keeps NVIDIA's driver branch and
#  platform config, follows NVIDIA's documented upgrade order (DOCA before
#  kernel), waits for first-boot RAID, reboots + resumes on its own. Also works
#  on plain Ubuntu 24.04 HGX B300 via NVIDIA's "DGX software on Ubuntu" recipe.
#
#  Knobs (env, persisted to /etc/b300-setup.env). Pass after sudo:
#      curl -sL is.gd/b300sh | sudo INSTALL_SGLANG=0 bash
#    AUTO_REBOOT=1  FULL_UPGRADE=1  INSTALL_DOCA=1  INSTALL_DOCKER=1
#    INSTALL_VLLM=1 INSTALL_SGLANG=1 INSTALL_GDS=0  TUNE_ACS=1
#    CONFIGURE_RAID=0   non-DGX only, DESTRUCTIVE: RAID0 empty NVMe -> /raid
#    DCGM_LEVEL=2       dcgmi diag level in --test (3 = ~35 min stress)
#    NCCL_MIN_BUSBW=600 GB/s floor for 8-GPU all_reduce busbw
#    TEST_MODEL=Qwen/Qwen3-0.6B   SETUP_USER=<you>   HF_TOKEN=
# =============================================================================
set -Eeuo pipefail
export LC_ALL=C.UTF-8

VERSION=2.0
SELF_URL="https://raghavpillai.github.io/b300/install.sh"
SELF=/usr/local/sbin/b300-setup
STATE=/var/lib/b300-setup
LOG=/var/log/b300-setup.log           # raw output of every command
EVENTS=$STATE/events.log              # pretty transcript the follower renders
CUR=$STATE/current                    # "label|start_epoch" of the running task
REPORT=/var/log/b300-setup-report.txt
ENVFILE=/etc/b300-setup.env
UNIT=b300-setup
KNOBS=(AUTO_REBOOT FULL_UPGRADE INSTALL_DOCA INSTALL_DOCKER INSTALL_VLLM
       INSTALL_SGLANG INSTALL_GDS TUNE_ACS CONFIGURE_RAID DCGM_LEVEL
       NCCL_MIN_BUSBW TEST_MODEL SETUP_USER HF_TOKEN)

# ---------------------------------------------------------------- bootstrap --
if [[ "${BASH_SOURCE[0]:-}" != "$SELF" ]]; then
  tmp=$(mktemp)
  if [[ -f "${BASH_SOURCE[0]:-}" ]]; then cp "${BASH_SOURCE[0]}" "$tmp"
  else
    [[ -t 0 ]] || cat >/dev/null   # finish reading the `curl |` pipe so curl exits cleanly
    curl -fsSL "$SELF_URL" -o "$tmp"
  fi
  SUDO=(); [[ $EUID -ne 0 ]] && SUDO=(sudo -E)
  "${SUDO[@]}" install -D -m 0755 "$tmp" "$SELF"; rm -f "$tmp"
  export SETUP_USER="${SETUP_USER:-${SUDO_USER:-$(id -un)}}"
  exec "${SUDO[@]}" bash "$SELF" "$@" </dev/null
fi
[[ $EUID -eq 0 ]] || exec sudo -E bash "$SELF" "$@"
mkdir -p "$STATE"

# -------------------------------------------------------------------- style --
if [[ -z ${NO_COLOR:-} && ( -t 1 || -n ${B300_DETACHED:-} ) ]]; then
  Z=$'\e[0m' BO=$'\e[1m' DI=$'\e[2m' IT=$'\e[3m'
  GR=$'\e[38;5;112m' G2=$'\e[38;5;70m' RD=$'\e[38;5;203m' YE=$'\e[38;5;221m'
  CY=$'\e[38;5;117m' GY=$'\e[38;5;245m' WH=$'\e[38;5;255m'
else Z='' BO='' DI='' IT='' GR='' G2='' RD='' YE='' CY='' GY='' WH=''; fi
SPIN=(⠋ ⠙ ⠹ ⠸ ⠼ ⠴ ⠦ ⠧ ⠇ ⠏)

# emit: user-facing line. Detached runs write only the transcript (the
# follower renders it); interactive runs print and keep a copy in the log.
emit() {
  if [[ -n ${B300_DETACHED:-} ]]; then printf '%s\n' "$*" >> "$EVENTS"
  else printf '%s\n' "$*"; printf '%s\n' "$*" | strip >> "$LOG"; fi
  return 0
}
strip() { sed -E 's/\x1b\[[0-9;]*[a-zA-Z]//g'; }
dur() { local s=$1; ((s >= 60)) && printf '%dm%02ds' $((s / 60)) $((s % 60)) || printf '%ds' "$s"; }
pad() { local s=$1 n=$2; printf '%s%*s' "$s" $(( n > ${#s} ? n - ${#s} : 0 )) ''; }   # char-aware %-Ns
cols() { local c=${B300_COLS:-}; [[ -n $c ]] || c=$(tput cols 2>/dev/null || echo 110); ((c > 140)) && c=140; echo "$c"; }
rule() { local t=$1 w; w=$(( $(cols) - ${#t} - 6 )); ((w < 4)) && w=4
  emit ""; emit "${GR}━━${Z} ${BO}${WH}${t}${Z} ${GR}$(printf '━%.0s' $(seq 1 "$w"))${Z}"; }

banner() {
  local sub=$1
  emit ""
  emit "${GR}${BO}   ██████╗ ██████╗  ██████╗  ██████╗ ${Z}"
  emit "${GR}${BO}   ██╔══██╗╚════██╗██╔═████╗██╔═████╗${Z}   ${WH}${BO}NVIDIA DGX B300${Z}"
  emit "${GR}${BO}   ██████╔╝ █████╔╝██║██╔██║██║██╔██║${Z}   ${GY}${sub}${Z}"
  emit "${G2}${BO}   ██╔══██╗ ╚═══██╗████╔╝██║████╔╝██║${Z}   ${GY}b300-setup v${VERSION}${Z}"
  emit "${G2}${BO}   ██████╔╝██████╔╝╚██████╔╝╚██████╔╝${Z}   ${DI}$(hostname) · $(date '+%F %H:%M')${Z}"
  emit "${G2}   ╚═════╝ ╚═════╝  ╚═════╝  ╚═════╝ ${Z}"
}

# box color "title" lines...   (rounded box, ANSI-aware width)
box() {
  local color=$1 title=$2; shift 2
  local l w=0 vis
  for l in "$title" "$@"; do vis=$(printf '%s' "$l" | strip); ((${#vis} > w)) && w=${#vis}; done
  w=$((w + 2))
  emit "${color}╭─${Z} ${BO}${title}${Z} ${color}$(printf '─%.0s' $(seq 1 $((w - ${#title} - 2))))╮${Z}"
  for l in "$@"; do
    vis=$(printf '%s' "$l" | strip)
    emit "${color}│${Z} ${l}$(printf '%*s' $((w - ${#vis})) '')${color}│${Z}"
  done
  emit "${color}╰$(printf '─%.0s' $(seq 1 $((w + 1))))╯${Z}"
}

# check results (used by --check / --test / install validation)
N_PASS=0 N_WARN=0 N_FAIL=0; FAILS=() WARNS=() RES=()
_res() { # icon color label detail
  local d=${4:-}; local maxd=$(( $(cols) - 52 )); ((maxd < 30)) && maxd=30
  ((${#d} > maxd)) && d="${d:0:maxd-1}…"
  emit "  ${2}${1}${Z} $(pad "$3" 44) ${DI}${d}${Z}"
  RES+=("$1 $(pad "$3" 44) ${4:-}")
}
ok()   { N_PASS=$((N_PASS + 1)); _res "✓" "$GR" "$@"; }
meh()  { N_WARN=$((N_WARN + 1)); WARNS+=("$1${2:+: $2}"); _res "!" "$YE" "$@"; }
bad()  { N_FAIL=$((N_FAIL + 1)); FAILS+=("$1${2:+: $2}"); _res "✗" "$RD" "$@"; }
note() { _res "•" "$CY" "$@"; }
log()  { emit "    ${DI}${*}${Z}"; }

# task "label" cmd...  -> runs cmd with output to $LOG, spinner on a tty
task() {
  local label=$1; shift; local t0=$SECONDS rc=0 pid i=0 last w off
  off=$(stat -c %s "$LOG" 2>/dev/null || echo 0)
  printf '%s|%s\n' "$label" "$(date +%s)" > "$CUR"
  printf '\n──── [%s] %s\n' "$(date '+%F %T')" "$label" >> "$LOG"
  if [[ -t 1 && -z ${B300_DETACHED:-} ]]; then
    "$@" >> "$LOG" 2>&1 & pid=$!
    w=$(cols)
    while kill -0 "$pid" 2>/dev/null; do
      last=$(tail -c 1500 "$LOG" 2>/dev/null | tr '\r' '\n' | strip | grep -av '^\s*$\|^──── ' | tail -1 | tr -d '\t')
      last=${last:0:$((w - ${#label} - 20))}
      printf '\r\e[2K  %s%s%s %s %s%s%s %s%s%s' "$GR" "${SPIN[i++ % 10]}" "$Z" "$label" \
        "$GY" "$(dur $((SECONDS - t0)))" "$Z" "$DI" "${last:+│ $last}" "$Z"
      sleep 0.1
    done
    printf '\r\e[2K'
    wait "$pid" || rc=$?
  else
    "$@" >> "$LOG" 2>&1 || rc=$?
  fi
  rm -f "$CUR"
  if ((rc == 0)); then emit "  ${GR}✓${Z} ${label} ${DI}$(dur $((SECONDS - t0)))${Z}"
  else
    emit "  ${RD}✗ ${label}${Z} ${DI}(exit ${rc} after $(dur $((SECONDS - t0))))${Z}"
    tail -c +$((off + 1)) "$LOG" | strip | grep -av '^──── \|^\s*$' | tail -n 10 | sed 's/^/      │ /' \
      | while IFS= read -r l; do emit "${DI}${l:0:$(( $(cols) - 2 ))}${Z}"; done
    touch "$STATE/.task-failed"
  fi
  return "$rc"
}

# ------------------------------------------------------------------ helpers --
export DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=l NEEDRESTART_SUSPEND=1
have() { command -v "$1" >/dev/null 2>&1; }
# grep -q exits early -> SIGPIPE upstream -> false failure under pipefail
q() { grep "$@" >/dev/null; }
flag() { [[ "${!1:-0}" == 1 ]]; }
is_dgx() { [[ -f /etc/dgx-release ]]; }
mark_reboot() { touch "$STATE/.reboot-needed"; }
APT=(apt-get -y -q -o DPkg::Lock::Timeout=1800
     -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold)
apt_install() { "${APT[@]}" install "$@"; }
has_candidate() { apt-cache policy "$1" 2>/dev/null | q 'Candidate: [0-9]'; }
installed()     { dpkg-query -W -f='${Status}' "$1" 2>/dev/null | q 'ok installed'; }
# install whichever of the given packages exist in the configured repos (one apt-cache call)
apt_install_avail() {
  local want=()
  mapfile -t want < <(apt-cache policy "$@" 2>/dev/null \
    | awk '/^[^ ].*:$/ {p = substr($1, 1, length($1) - 1)} /Candidate: [0-9]/ {print p}')
  ((${#want[@]} < $#)) && echo "not available, skipped: $(printf '%s\n' "$@" | grep -vxF -f <(printf '%s\n' "${want[@]}" "") | tr '\n' ' ')"
  ((${#want[@]})) && apt_install "${want[@]}"
}
# first version of $1 available in apt that starts with driver version $2
pkg_ver() { apt-cache madison "$1" 2>/dev/null | awk -F'|' -v v="$2" '{gsub(/ /,"",$2)} index($2, v) == 1 {print $2; exit}'; }
doca_repo_pkg() { installed doca-bos8-latest-repo && echo doca-bos8-latest-repo || echo doca-repo; }
apt_update() {
  "${APT[@]}" update && return 0
  # DGX OS known issue: DOCA repo signing key rotated (NO_PUBKEY DC726C5E41B9CC50)
  echo "apt update failed - applying NVIDIA's documented repo-key refresh"
  "${APT[@]}" install nvidia-repo-keys "$(doca_repo_pkg)" || true
  "${APT[@]}" update
}
as_user() { sudo -u "$SETUP_USER" -H env "PATH=/usr/local/bin:/usr/local/cuda/bin:$PATH" "$@"; }
drv_ver() { nvidia-smi --query-gpu=driver_version --format=csv,noheader 2>/dev/null | head -1; }
gpu_ok()  { have nvidia-smi && nvidia-smi -L >/dev/null 2>&1; }
pci_gpus() { lspci -d 10de: 2>/dev/null | grep -ciE '3d controller|vga' || true; }
smi() { nvidia-smi --query-gpu="$1" --format=csv,noheader,nounits 2>/dev/null; }
cuda_src_present() {
  grep -rqs 'developer.download.nvidia.com/compute/cuda/repos/ubuntu2404/x86_64' \
    /etc/apt/sources.list /etc/apt/sources.list.d/
}
newest_kernel() { ls /boot/vmlinuz-* 2>/dev/null | sed 's#.*/vmlinuz-##' | sort -V | tail -1; }
# every DKMS module must be built for the kernel we're about to boot
dkms_ok() {
  have dkms || return 0
  local kv bad; kv=$(newest_kernel); [[ -n $kv ]] || return 0
  bad=$(dkms status -k "$kv" 2>/dev/null | grep -v ': installed' | grep -v '^\s*$' || true)
  [[ -z $bad ]] && return 0
  echo "DKMS not installed for $kv:"; echo "$bad"
  dkms autoinstall -k "$kv" || true
  bad=$(dkms status -k "$kv" 2>/dev/null | grep -v ': installed' | grep -v '^\s*$' || true)
  [[ -z $bad ]]
}
fabric_states() { nvidia-smi -q 2>/dev/null | awk '/^ +Fabric$/{f=1;next} f&&/State/{s=$NF} f&&/Status/{print s, $NF; f=0}'; }

persist_knobs() {
  local k; local -A ov=()
  for k in "${KNOBS[@]}"; do [[ -n ${!k+x} ]] && ov[$k]=${!k}; done
  [[ -f $ENVFILE ]] && . "$ENVFILE"
  for k in "${!ov[@]}"; do printf -v "$k" '%s' "${ov[$k]}"; done
  : "${AUTO_REBOOT:=1}" "${FULL_UPGRADE:=1}" "${INSTALL_DOCA:=1}" "${INSTALL_DOCKER:=1}"
  : "${INSTALL_VLLM:=1}" "${INSTALL_SGLANG:=1}" "${INSTALL_GDS:=0}" "${TUNE_ACS:=1}"
  : "${CONFIGURE_RAID:=0}" "${DCGM_LEVEL:=2}" "${NCCL_MIN_BUSBW:=600}"
  : "${TEST_MODEL:=Qwen/Qwen3-0.6B}" "${HF_TOKEN:=}" "${SETUP_USER:=${SUDO_USER:-root}}"
  (umask 077; for k in "${KNOBS[@]}"; do printf '%s=%q\n' "$k" "${!k}"; done > "$ENVFILE")
}

# ------------------------------------------------------------ live follower --
follow() {
  local off=0 size i=0 label t0 last w n=0
  touch "$EVENTS" "$LOG"
  w=$(cols)
  trap 'printf "\r\e[2K\e[?25h\n  %sdetached - setup keeps running. re-attach:%s %sb300-setup -f%s\n" "$GY" "$Z" "$BO" "$Z"; exit 0' INT TERM
  printf '\e[?25l'
  while :; do
    size=$(stat -c %s "$EVENTS" 2>/dev/null || echo 0)
    if ((size > off)); then
      printf '\r\e[2K'; tail -c +$((off + 1)) "$EVENTS" | head -c $((size - off)); off=$size
    fi
    if [[ -f $CUR ]] && IFS='|' read -r label t0 < "$CUR" 2>/dev/null; then
      last=$(tail -c 1500 "$LOG" 2>/dev/null | tr '\r' '\n' | strip | grep -av '^\s*$\|^──── ' | tail -1 | tr -d '\t')
      last=${last:0:$((w - ${#label} - 20))}
      printf '\r\e[2K  %s%s%s %s %s%s%s %s%s%s' "$GR" "${SPIN[i % 10]}" "$Z" "$label" \
        "$GY" "$(dur $(( $(date +%s) - t0 )))" "$Z" "$DI" "${last:+│ $last}" "$Z"
    else printf '\r\e[2K'; fi
    i=$((i + 1))
    if ((i % 8 == 0)); then
      if systemctl is-active -q "$UNIT" || systemctl is-active -q "$UNIT-resume"; then n=0
      else n=$((n + 1)); ((n >= 2)) && break; fi
    fi
    sleep 0.12
  done
  size=$(stat -c %s "$EVENTS" 2>/dev/null || echo 0)
  ((size > off)) && tail -c +$((off + 1)) "$EVENTS"
  printf '\r\e[2K\e[?25h'
}

# =============================================================================
#  PRE-FLIGHT / DIAGNOSTIC CHECKS (read-only)
# =============================================================================
chk_system() {
  rule "System"
  . /etc/os-release
  local product; product=$(cat /sys/class/dmi/id/product_name 2>/dev/null || echo unknown)
  [[ $product == *B300* ]] && ok "Platform" "$product" || meh "Platform" "'$product' (expected DGX B300)"
  [[ $(uname -m) == x86_64 ]] && ok "Architecture" "x86_64" || bad "Architecture" "$(uname -m)"
  [[ ${VERSION_ID:-} == 24.04 ]] && ok "OS" "$PRETTY_NAME" || bad "OS" "${PRETTY_NAME:-?} (need Ubuntu 24.04 / DGX OS 7)"
  if is_dgx; then
    local sw ota cur
    sw=$(. /etc/dgx-release; echo "${DGX_SWBUILD_VERSION:-?}")
    ota=$(grep -h '^DGX_OTA_VERSION' /etc/dgx-release | tail -1 | cut -d= -f2 | tr -d '"' || true)
    ok "DGX OS" "factory ${sw}${ota:+, updated to $ota}"
    cur=${ota:-$sw}
    [[ $(printf '%s\n7.5.0\n' "$cur" | sort -V | head -1) == 7.5.0 ]] \
      || note "DGX OS < 7.5.0" "install upgrades it; B300 firmware 26.07.1 needs ≥ 7.5"
  else note "DGX OS" "not DGX OS - will use NVIDIA's DGX-on-Ubuntu packages"; fi
  note "Kernel" "$(uname -r)"
  note "CPU" "$(lscpu | awk -F: '/Model name/{gsub(/^ +/,"",$2);print $2; exit}') · $(nproc) threads · $(lscpu | awk -F: '/NUMA node\(s\)/{gsub(/ /,"",$2);print $2}') NUMA"
  note "Memory" "$(free -g | awk '/Mem/{print $2}') GiB"
  local st; st=$(systemctl is-system-running 2>/dev/null || true); st=${st:-unknown}
  case $st in
    running) ok "systemd state" "running" ;;
    degraded) meh "systemd state" "degraded: $(systemctl --failed --no-legend --plain 2>/dev/null | awk '{print $1}' | head -4 | tr '\n' ' ')" ;;
    *) meh "systemd state" "$st (boot still settling?)" ;;
  esac
  [[ $(timedatectl show -p NTPSynchronized --value 2>/dev/null) == yes ]] && ok "Clock synced (NTP)" \
    || meh "Clock not NTP-synced" "TLS/apt can fail with a skewed clock"
}

chk_packages() {
  rule "Packages"
  local a; a=$(dpkg --audit 2>/dev/null || true)
  [[ -z $a ]] && ok "dpkg state clean" || bad "dpkg has half-configured packages" "install runs: dpkg --configure -a"
  if dpkg -l 'nvidia-driver-pinning*' 2>/dev/null | q '^ii'; then
    ok "Driver branch pin" "$(dpkg -l 'nvidia-driver-pinning*' | awk '/^ii/{print $2}' | head -1)"
  else note "Driver branch pin" "none installed"; fi
  local h; h=$(apt-mark showhold 2>/dev/null | tr '\n' ' ')
  [[ -z $h ]] && ok "No held packages" || note "Held packages" "$h"
  local sim up kern
  sim=$(apt-get -s -o Debug::NoLocking=1 full-upgrade 2>/dev/null || true)
  up=$(grep -c '^Inst' <<<"$sim" || true)
  kern=$(grep -oE '^Inst (linux-image-[^ ]+|nvidia-dkms[^ ]*|doca-ofed|mlnx-ofed-kernel[^ ]*)' <<<"$sim" | awk '{print $2}' | tr '\n' ' ' || true)
  ((up == 0)) && ok "Up to date" "(per cached apt lists)" || note "Pending upgrades" "$up packages${kern:+ · incl. $kern}"
  [[ -f /var/run/reboot-required ]] && meh "Reboot required" "$(tr '\n' ' ' < /var/run/reboot-required.pkgs 2>/dev/null | cut -c1-60)"
  if have dkms; then
    local d; d=$(dkms status 2>/dev/null | grep -F "$(uname -r)" | grep -v ': installed' || true)
    [[ -z $d ]] && ok "DKMS modules built" "$(dkms status 2>/dev/null | grep -F "$(uname -r)" | cut -d, -f1 | sort -u | tr '\n' ' ')" \
      || bad "DKMS modules not built for $(uname -r)" "$d"
  fi
  systemctl is-enabled -q unattended-upgrades 2>/dev/null && note "unattended-upgrades on" "install disables it (DOCA DKMS vs kernel race)"
  return 0
}

chk_gpus() {
  rule "GPUs"
  local pci n; pci=$(pci_gpus)
  if ! gpu_ok; then
    ((pci > 0)) && bad "nvidia-smi" "not working ($pci GPUs on PCIe) - driver missing or not loaded" \
                || bad "No NVIDIA GPUs visible"
    return 0
  fi
  n=$(nvidia-smi -L | wc -l)
  local name mem; name=$(smi name | head -1); mem=$(smi memory.total | head -1)
  if ((n == pci && n == 8)); then ok "GPUs" "8 × $name · $((mem / 1024)) GiB each"
  elif ((n == pci)); then meh "GPUs" "$n × $name (a DGX B300 has 8)"
  else bad "GPUs" "nvidia-smi sees $n, PCIe has $pci"; fi
  local v; v=$(drv_ver)
  ((${v%%.*} >= 580)) && ok "Driver" "$v (R580+ open, required for B300)" || bad "Driver" "$v - B300 needs R580+"
  local vb; vb=$(smi vbios_version | sort -u)
  [[ $(wc -l <<<"$vb") == 1 ]] && ok "VBIOS uniform" "$vb" || meh "VBIOS differs across GPUs" "$(tr '\n' ' ' <<<"$vb")"
  local pm; pm=$(smi persistence_mode | grep -c Enabled || true)
  ((pm == n)) && ok "Persistence mode" "on ($pm/$n)" || meh "Persistence mode" "$pm/$n on"
  local mig; mig=$(smi mig.mode.current | grep -vc -E 'Disabled|N/A' || true)
  ((mig == 0)) && ok "MIG off" || meh "MIG enabled on $mig GPU(s)" "nvidia-smi -mig 0"
  local ecc; ecc=$(smi ecc.mode.current | grep -c Enabled || true)
  ((ecc == n)) && ok "ECC enabled" "$ecc/$n" || meh "ECC" "enabled on $ecc/$n"
  local ue; ue=$(smi ecc.errors.uncorrected.volatile.total | awk '$1 ~ /^[0-9]+$/ {s+=$1} END {print s+0}')
  ((ue == 0)) && ok "Uncorrectable ECC (this boot)" "0" || bad "Uncorrectable ECC errors" "$ue since boot"
  local rr; rr=$(smi remapped_rows.pending,remapped_rows.failure | grep -ci yes || true)
  ((rr == 0)) && ok "HBM row remapping" "none pending / failed" || bad "HBM row remap pending/failed" "$rr GPU(s) - reset or RMA"
  local pl; pl=$(smi power.limit,power.default_limit | awk -F', ' '$1+0 < $2-1 {c++} END {print c+0}')
  ((pl == 0)) && ok "Power limits at default" "$(smi power.limit | head -1 | cut -d. -f1) W" || meh "Power limit lowered" "$pl GPU(s) below default"
  local thr; thr=$(smi clocks_event_reasons.hw_slowdown,clocks_event_reasons.hw_thermal_slowdown,clocks_event_reasons.hw_power_brake_slowdown | grep -c Active || true)
  ((thr == 0)) && ok "No HW slowdown / power brake" || bad "HW slowdown active" "$thr GPU(s) - check cooling/PSU"
  local t tm; t=$(smi temperature.gpu | sort -n | tail -1); tm=$(smi temperature.memory | grep -E '^[0-9]+$' | sort -n | tail -1 || true)
  if ((t < 85)); then ok "Temperatures" "GPU max ${t}°C${tm:+ · HBM max ${tm}°C}"; else meh "GPU hot" "max ${t}°C${tm:+ · HBM ${tm}°C}"; fi
  local pw; pw=$(smi index,pcie.link.width.current,pcie.link.width.max | awk -F', ' '$2 != $3 {printf "GPU%s x%s/x%s ", $1, $2, $3}')
  [[ -z $pw ]] && ok "PCIe link width" "x$(smi pcie.link.width.current | head -1) on all" || meh "PCIe link downtrained" "$pw"
  local xid; xid=$(journalctl -k -b --no-pager 2>/dev/null | grep -oE 'NVRM: Xid \(PCI:[^)]+\): [0-9]+' | awk '{print $NF}' | sort | uniq -c | awk '{printf "Xid%s×%s ", $2, $1}')
  [[ -z $xid ]] && ok "No Xid errors this boot" || bad "Xid errors" "$xid (79/48/94/95/119/120 → support case)"
}

chk_fabric() {
  rule "NVLink fabric"
  gpu_ok || { note "skipped" "no working driver"; return 0; }
  local n states good; n=$(nvidia-smi -L | wc -l); states=$(fabric_states)
  good=$(grep -c '^Completed Success' <<<"$states" || true)
  if [[ -z $states ]]; then bad "Fabric state" "no Fabric section - fabric manager not running?"
  elif ((good == n)); then ok "Fabric state" "Completed / Success on $good/$n GPUs"
  else bad "Fabric state" "$good/$n healthy: $(sort <<<"$states" | uniq -c | tr -s ' ' | tr '\n' ';')"; fi
  systemctl is-active -q nvidia-fabricmanager && ok "nvidia-fabricmanager" "active · $(dpkg-query -W -f='${Version}' nvidia-fabricmanager 2>/dev/null)" \
    || bad "nvidia-fabricmanager" "not active - journalctl -u nvidia-fabricmanager"
  pgrep -x nvlsm >/dev/null && ok "NVLSM (NVLink subnet manager)" "running" || meh "NVLSM process" "not running (started by fabricmanager on B300)"
  local fme; fme=$(journalctl -u nvidia-fabricmanager -b --no-pager 2>/dev/null | grep -ciE 'error|fail' || true)
  ((fme == 0)) || meh "Fabric manager log" "$fme error lines this boot"
  local links u
  links=$(nvidia-smi nvlink -s 2>/dev/null | awk '/^GPU/{g++} /Link [0-9]+:/{t[g]++; if ($0 ~ /inactive/) i[g]++} END {for (k=1;k<=g;k++) printf "%d/%d ", t[k]-i[k], t[k]}')
  u=$(tr ' ' '\n' <<<"$links" | grep -v '^$' | sort -u)
  if [[ -z $links ]]; then meh "NVLink links" "nvidia-smi nvlink -s gave no output"
  elif [[ $(wc -l <<<"$u") == 1 && ${u%/*} == "${u#*/}" ]]; then ok "NVLink links" "${u%/*} active per GPU, all GPUs"
  else meh "NVLink links" "active/total per GPU: $links"; fi
  local le; le=$(nvidia-smi nvlink -e 2>/dev/null | grep -iE 'replay|recovery|crc|error' | grep -oE '[0-9]+$' | awk '$1>0{c++} END{print c+0}')
  ((le == 0)) && ok "NVLink error counters" "all zero" || meh "NVLink error counters" "$le non-zero counters (watch if rising)"
  local p; p=$(stat -c %a /var/run/nvidia-fabricmanager 2>/dev/null || true)
  if [[ -n $p && ! ${p: -1} =~ [157] ]]; then
    meh "FM socket dir not world-accessible" "($p) non-root NCCL may fail - NVIDIA known issue"
  fi
  return 0
}

chk_network() {
  rule "Network"
  local mlx; mlx=$(lspci -d 15b3: 2>/dev/null | grep -ciE 'ethernet|infiniband' || true)
  note "ConnectX / BlueField functions" "$mlx"
  if compgen -G '/sys/class/infiniband/*/ports/*/state' >/dev/null; then
    local up=0 down=0 desc="" p st rate ll fw
    for p in /sys/class/infiniband/*/ports/*; do
      st=$(cut -d: -f2 < "$p/state" | tr -d ' ')
      ll=$(cat "$p/link_layer" 2>/dev/null); rate=$(awk '{print $1$2}' "$p/rate" 2>/dev/null)
      if [[ $st == ACTIVE ]]; then up=$((up + 1)); desc+="$ll:$rate "; else down=$((down + 1)); fi
    done
    desc=$(tr ' ' '\n' <<<"$desc" | grep -v '^$' | sort | uniq -c | awk '{printf "%s×%s ", $1, $2}')
    ((down == 0)) && ok "RDMA ports" "$up active · $desc" || meh "RDMA ports" "$up active ${desc:+($desc)}, $down down/uncabled"
    fw=$(cat /sys/class/infiniband/*/fw_ver 2>/dev/null | sort | uniq -c | awk '{printf "%s (×%s) ", $2, $1}')
    note "ConnectX firmware" "$fw"
  else
    note "RDMA ports" "no RDMA devices (DOCA-OFED not installed yet?)"
  fi
  if have ofed_info; then ok "DOCA-OFED" "$(ofed_info -s 2>/dev/null | tr -d ':')"; else note "DOCA-OFED" "not installed"; fi
  if q '^nvidia_peermem ' /proc/modules; then ok "nvidia_peermem (GPUDirect RDMA)" "loaded"
  elif is_dgx && gpu_ok; then bad "nvidia_peermem not loaded" "GPUDirect RDMA off (known OTA issue: modprobe nvidia-peermem)"
  else note "nvidia_peermem" "not loaded"; fi
  systemctl is-active -q rshim 2>/dev/null && note "BlueField-3 rshim" "active · reset BF3 BMC default password if not done"
  local clash; clash=$(ip -4 route 2>/dev/null | grep -v docker0 | grep -E '(^| )172\.17\.' || true)
  [[ -z $clash ]] && ok "No Docker subnet clash" "172.17.0.0/16 free" || meh "Docker subnet clash" "$clash"
  local h fails=""
  for h in repo.download.nvidia.com developer.download.nvidia.com pypi.org huggingface.co github.com; do
    curl -sI --max-time 6 "https://$h" >/dev/null 2>&1 || fails+="$h "
  done
  [[ -z $fails ]] && ok "Internet" "NVIDIA repos, PyPI, HF, GitHub reachable" || bad "Unreachable" "$fails"
}

chk_platform() {
  rule "Platform tuning"
  [[ $(cat /proc/cmdline) == *iommu=pt* ]] && ok "IOMMU passthrough" "iommu=pt" || meh "IOMMU passthrough" "iommu=pt not on cmdline"
  if systemctl is-enabled -q nvidia-acs-disable 2>/dev/null; then ok "PCIe ACS" "disabled by nvidia-acs-disable"
  elif systemctl is-enabled -q b300-tune 2>/dev/null; then ok "PCIe ACS" "disabled by b300-tune"
  else
    local acs; acs=$(lspci -vvv 2>/dev/null | grep -c 'ACSCtl:.*SrcValid+' || true)
    ((acs == 0)) && ok "PCIe ACS" "off" || meh "PCIe ACS enabled" "on $acs bridges - hurts GPUDirect P2P"
  fi
  local gov; gov=$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null || echo n/a)
  [[ $gov == performance ]] && ok "CPU governor" "performance" || meh "CPU governor" "$gov"
  note "Transparent hugepages" "$(grep -o '\[[a-z]*\]' /sys/kernel/mm/transparent_hugepage/enabled | tr -d '[]')"
  local ml; ml=$(systemctl show -p DefaultLimitMEMLOCK --value 2>/dev/null)
  [[ $ml == infinity ]] && ok "memlock limit" "unlimited" || note "memlock limit" "${ml:-?} (install raises to unlimited)"
}

chk_storage() {
  rule "Storage"
  if mountpoint -q /raid; then
    ok "/raid" "$(df -h --output=size,avail,fstype /raid | tail -1 | awk '{print $1" total, "$2" free, "$3}')"
  elif is_dgx; then
    if [[ -e /var/tmp/first-boot-check-raid ]] || systemctl is-active -q nvidia-raid-config 2>/dev/null; then
      meh "/raid" "first-boot RAID build still running (~10 min after first boot)"
    else bad "/raid not mounted" "systemctl status raid.mount nvidia-raid-config"; fi
  else note "/raid" "not present (CONFIGURE_RAID=1 to build from empty NVMe)"; fi
  local free; free=$(df -BG --output=avail / | tail -1 | tr -dc 0-9)
  ((free >= 80)) && ok "Root filesystem" "${free}G free" || meh "Root filesystem" "only ${free}G free (venvs + CUDA ≈ 60G)"
  if [[ -r /proc/mdstat ]]; then
    q -E '\[[U_]*_[U_]*\]' /proc/mdstat && bad "md RAID degraded" "$(grep -B1 -E '\[[U_]*_' /proc/mdstat | head -1)"
    q -E 'resync|recovery' /proc/mdstat && note "md RAID rebuilding" "$(grep -oE '(resync|recovery) *= *[0-9.]+%' /proc/mdstat | head -1) - normal ~1h after first boot"
  fi
  local nv; nv=$(journalctl -k -b --no-pager 2>/dev/null | grep -c 'opcode 0x2 QID' || true)
  ((nv == 0)) || meh "NVMe I/O errors" "$nv 'opcode 0x2' msgs - known Micron E1.S fw issue"
  return 0
}

chk_software() {
  rule "Software stack"
  if have docker; then
    local rt; rt=$(docker info --format '{{json .Runtimes}}' 2>/dev/null || true)
    [[ $rt == *nvidia* ]] && ok "Docker + NVIDIA runtime" "$(docker version --format '{{.Server.Version}}' 2>/dev/null)" \
      || meh "Docker" "installed, nvidia runtime not registered"
  else note "Docker" "not installed"; fi
  systemctl is-active -q nvidia-dcgm 2>/dev/null && ok "DCGM host engine" "$(dcgmi -v 2>/dev/null | awk -F: '/Version/{gsub(/ /,"",$2);print $2; exit}')" \
    || note "DCGM" "not running"
  have nvsm && ok "NVSM" "installed" || note "NVSM" "not installed"
  [[ -x /usr/local/cuda/bin/nvcc ]] && ok "CUDA toolkit" "$(/usr/local/cuda/bin/nvcc --version | grep -oE 'release [0-9.]+' | cut -d' ' -f2)" \
    || note "CUDA toolkit" "not installed (DGX OS ships without it)"
  have uv && ok "uv" "$(uv --version | cut -d' ' -f2)" || note "uv" "not installed"
  local v; for v in ml vllm sglang; do
    [[ -x /opt/venvs/$v/bin/python ]] && ok "venv /opt/venvs/$v" "python $(/opt/venvs/$v/bin/python -V 2>&1 | cut -d' ' -f2)"
  done
  [[ -x /opt/nccl-tests/build/all_reduce_perf ]] && ok "nccl-tests" "/opt/nccl-tests"
  return 0
}

chk_firmware() {
  rule "Firmware (info)"
  note "System BIOS" "$(cat /sys/class/dmi/id/bios_version 2>/dev/null || echo ?)"
  have ipmitool && note "BMC" "$(timeout 10 ipmitool mc info 2>/dev/null | awk -F: '/Firmware Revision/{gsub(/ /,"",$2);print $2}' || echo ?)"
  gpu_ok && note "GPU VBIOS / InfoROM" "$(smi vbios_version | head -1) / $(smi inforom.img | head -1)"
  note "Reference (FW 26.07.1)" "SBIOS 01.00.08 · BMC 01.01.44 · VBIOS 97.10.73.00.09 · CX8 40.48.1126"
  log "full inventory: nvfwupd -t ip=<bmc> user=<u> password=<p> show_version"
}

chk_nvsm() {
  have nvsm || return 0
  rule "NVSM health"
  local out=$STATE/nvsm-health.txt
  task "nvsm show health" sh -c "timeout 300 nvsm show health > $out 2>&1" || true
  if q -iE 'unhealthy|critical|failed' "$out"; then
    meh "NVSM health" "issues: $(grep -iE 'unhealthy|critical|failed' "$out" | head -2 | tr -s ' ' | tr '\n' ';')"
  elif q -i 'healthy' "$out"; then ok "NVSM health" "Healthy"
  else note "NVSM health" "no verdict - see $out"; fi
}

run_checks() {
  set +e
  chk_system; chk_packages; chk_gpus; chk_fabric; chk_network; chk_platform; chk_storage; chk_software; chk_firmware
  return 0
}

summary() {
  local title=$1 color=$GR verdict="all good" f
  ((N_WARN)) && { color=$YE; verdict="ok with warnings"; }
  ((N_FAIL)) && { color=$RD; verdict="needs attention"; }
  local lines=("${GR}✓ ${N_PASS} passed${Z}   ${YE}! ${N_WARN} warnings${Z}   ${RD}✗ ${N_FAIL} failed${Z}   ${BO}→ ${verdict}${Z}")
  ((${#FAILS[@]} + ${#WARNS[@]})) && lines+=("")
  for f in "${FAILS[@]}"; do lines+=("${RD}✗${Z} ${f:0:96}"); done
  for f in "${WARNS[@]}"; do lines+=("${YE}!${Z} ${f:0:96}"); done
  emit ""; box "$color" "$title" "${lines[@]}"
}

# =============================================================================
#  INSTALL STEPS
# =============================================================================
STEPS=(
  "preflight|Pre-flight checks|1"
  "base|Base packages & tools|1"
  "repos|NVIDIA apt repositories|1"
  "upgrade|OS upgrade (DGX OTA)|1"
  "driver|GPU driver + NVLink stack|1"
  "doca|DOCA-OFED / ConnectX-8|0"
  "docker|Docker + NVIDIA Container Toolkit|0"
  "cuda|CUDA 13 toolkit · cuDNN · NCCL|0"
  "raid|Data RAID (/raid)|0"
  "tuning|System tuning|0"
  "nccltests|nccl-tests|0"
  "python|Python envs (torch · vLLM · SGLang)|0"
)

plan() {
  rule "What the installer will do"
  local s name label
  for s in "${STEPS[@]}"; do
    IFS='|' read -r name label _ <<<"$s"
    if [[ -f $STATE/$name ]]; then emit "  ${GR}✓${Z} ${GY}${label}${Z} ${DI}(done)${Z}"
    else emit "  ${CY}○${Z} $(pad "$label" 38) ${DI}$(plan_detail "$name")${Z}"; fi
  done
  emit "  ${CY}○${Z} $(pad "Validation suite" 38) ${DI}DCGM r${DCGM_LEVEL} · NVSM · NCCL ≥${NCCL_MIN_BUSBW} GB/s · torch · vLLM${Z}"
}
plan_detail() {
  case $1 in
    preflight) is_dgx && echo "wait for first-boot services + /raid, then this report" || echo "this report" ;;
    base) echo "build tools, monitoring (btop/nvtop), disable unattended-upgrades" ;;
    repos) is_dgx && echo "DGX OS repos already present" || echo "NVIDIA DGX + CUDA repos" ;;
    upgrade) flag FULL_UPGRADE && echo "DOCA first → full-upgrade ($(apt-get -s -o Debug::NoLocking=1 full-upgrade 2>/dev/null | grep -c '^Inst' || true) pkgs) → verify DKMS" || echo "skipped (FULL_UPGRADE=0)" ;;
    driver) gpu_ok && echo "keep driver $(drv_ver); ensure FM / NVLSM / DCGM" || echo "R580 open driver + NVLink5 stack" ;;
    doca) have ofed_info && echo "present ($(ofed_info -s 2>/dev/null | tr -d ':'))" || echo "DOCA-OFED + peermem" ;;
    docker) have docker && echo "present; register nvidia runtime, ulimits" || echo "Docker CE + container toolkit" ;;
    cuda) [[ -x /usr/local/cuda/bin/nvcc ]] && echo "present" || echo "cuda-toolkit-13-0, cuDNN 9, NCCL" ;;
    raid) mountpoint -q /raid && echo "/raid mounted - untouched" || echo "report only on DGX" ;;
    tuning) echo "sysctl, limits, boot-time tuning unit, shell env" ;;
    nccltests) echo "build for sm_100 / sm_103" ;;
    python) echo "/opt/venvs/{ml,vllm,sglang} via uv" ;;
  esac
}

STEP_IDX=0
run_step() {   # run_step <name> <function>
  local name=$1 fn=$2 label crit s rc t0=$SECONDS total=$(( ${#STEPS[@]} + 1 ))
  for s in "${STEPS[@]}"; do [[ ${s%%|*} == "$name" ]] && IFS='|' read -r _ label crit <<<"$s"; done
  STEP_IDX=$((STEP_IDX + 1))
  if [[ -f "$STATE/$name" ]]; then emit "  ${GR}✓${Z} ${GY}[${STEP_IDX}/${total}] ${label}${Z} ${DI}· done earlier${Z}"; return 0; fi
  rule "[${STEP_IDX}/${total}] ${label}"
  rm -f "$STATE/.task-failed"
  set +e
  ( set -Eeuo pipefail
    trap 'echo "!! step '"$name"' failed at line $LINENO: $BASH_COMMAND"' ERR
    "$fn" )
  rc=$?
  set -e
  if ((rc != 0)) && [[ ! -f $STATE/.task-failed ]]; then   # surface the failing command
    local why; why=$(grep -a '^!! step' "$LOG" | tail -1 | cut -c1-150)
    [[ -n $why ]] && emit "      ${DI}│ ${why#!! }${Z}"
  fi
  rm -f "$STATE/.task-failed"
  if ((rc == 0)); then touch "$STATE/$name"; emit "  ${GR}${BO}✓ ${label}${Z} ${DI}$(dur $((SECONDS - t0)))${Z}"
  elif ((crit)); then
    emit ""; box "$RD" "Setup stopped" "${RD}✗${Z} critical step '${label}' failed (exit $rc)" \
      "log   ${BO}$LOG${Z}" "fix the cause, then re-run   ${BO}sudo b300-setup${Z}"
    exit 1
  else emit "  ${YE}${BO}! ${label} failed${Z} ${DI}(exit $rc) - continuing; details in $LOG${Z}"; echo "$name" >> "$STATE/.failed"; fi
}

st_preflight() {
  if is_dgx; then
    task "Waiting for boot to settle" sh -c 'timeout 900 systemctl is-system-running --wait >/dev/null 2>&1; exit 0'
    if [[ -e /var/tmp/first-boot-check-raid ]] || systemctl is-active -q nvidia-raid-config 2>/dev/null; then
      task "Waiting for first-boot RAID build (/raid)" sh -c '
        for i in $(seq 1 180); do
          [ ! -e /var/tmp/first-boot-check-raid ] && ! systemctl is-active -q nvidia-raid-config && exit 0
          sleep 10; done; exit 1' || echo "RAID service still busy after 30 min - continuing"
    fi
  fi
  run_checks
  summary "Pre-flight"
  set -e
  # hard blockers only; everything else is fixed by the install or just reported
  [[ $(uname -m) == x86_64 ]] || exit 1
  . /etc/os-release; [[ ${VERSION_ID:-} == 24.04 ]] || exit 1
  (( $(pci_gpus) > 0 )) || { echo "no NVIDIA GPUs on PCIe"; exit 1; }
  id "$SETUP_USER" >/dev/null 2>&1 || { echo "SETUP_USER '$SETUP_USER' does not exist"; exit 1; }
  if [[ -n $(dpkg --audit 2>/dev/null) ]]; then
    task "Repair dpkg state" sh -c 'dpkg --configure -a; apt-get -y -f install'
  fi
}

st_base() {
  # Unattended upgrades can pull a new kernel before DOCA's DKMS modules are
  # rebuilt for it (DGX OS known issue). Upgrades happen deliberately instead.
  echo 'APT::Periodic::Unattended-Upgrade "0";' > /etc/apt/apt.conf.d/99-b300-no-auto-upgrade
  systemctl disable --now unattended-upgrades.service apt-daily-upgrade.timer >/dev/null 2>&1 || true
  task "apt update" apt_update
  task "Install base tools" apt_install_avail \
    build-essential cmake ninja-build pkg-config ccache gdb git git-lfs \
    curl wget ca-certificates gnupg jq software-properties-common \
    htop btop nvtop tmux screen vim ncdu tree unzip zip zstd pigz pv aria2 rsync \
    numactl hwloc libnuma-dev pciutils lshw dmidecode ipmitool lm-sensors \
    iperf3 ethtool net-tools dnsutils iproute2 lsof strace sysstat iotop fio \
    nvme-cli mdadm xfsprogs smartmontools rasdaemon nfs-common \
    python3-dev python3-venv python3-pip pipx \
    linux-tools-common linux-tools-generic "linux-tools-$(uname -r)" "linux-headers-$(uname -r)" \
    libelf-dev libssl-dev dkms
  git lfs install --system >/dev/null 2>&1 || true
  systemctl enable --now rasdaemon sysstat >/dev/null 2>&1 || true
}

st_repos() {
  if [[ -f /etc/apt/sources.list.d/dgx.sources ]] || grep -rqs repo.download.nvidia.com/baseos /etc/apt/sources.list.d/; then
    log "DGX repositories already configured"
  elif ! gpu_ok; then
    local ex="--exclude=./etc/apt/sources.list.d/ai-workbench-desktop.sources"
    cuda_src_present && ex+=" --exclude=./etc/apt/sources.list.d/cuda-compute-repo.sources"
    task "Add NVIDIA DGX repo bundle" sh -c "curl -fsSL https://repo.download.nvidia.com/baseos/ubuntu/noble/x86_64/dgx-repo-files.tgz | tar xzf - -C / $ex"
  else
    log "driver $(drv_ver) installed from a non-DGX source; keeping its repositories"
  fi
  if ! cuda_src_present; then
    local d; d=$(mktemp -d)
    task "Add CUDA repo" sh -c "curl -fsSL -o $d/k.deb https://developer.download.nvidia.com/compute/cuda/repos/ubuntu2404/x86_64/cuda-keyring_1.1-1_all.deb && dpkg -i $d/k.deb"
    rm -rf "$d"
  fi
  task "apt update" apt_update
}

upgrade_all() {
  "${APT[@]}" full-upgrade && return 0
  echo "full-upgrade failed - repairing (apt -f install, dpkg --configure -a) and retrying"
  "${APT[@]}" -f install || true; dpkg --configure -a || true
  "${APT[@]}" full-upgrade
}

st_upgrade() {
  flag FULL_UPGRADE || { log "FULL_UPGRADE=0 - skipped"; return 0; }
  # NVIDIA's DGX OS 7 order: refresh DOCA repo/keys, update DOCA kernel
  # modules *before* the kernel, then full-upgrade, then verify DKMS.
  if is_dgx || has_candidate "$(doca_repo_pkg)"; then
    task "Refresh DOCA repo + NVIDIA keys" apt_install_avail "$(doca_repo_pkg)" nvidia-repo-keys
    task "apt update" apt_update
  fi
  local p mods=()
  for p in doca-ofed mlnx-ofed-kernel-dkms mlnx-nvme-dkms mlnx-nfsrdma-dkms iser-dkms isert-dkms srp-dkms; do
    installed "$p" && mods+=("$p")
  done
  if ((${#mods[@]})); then task "Update DOCA kernel modules first" "${APT[@]}" install --only-upgrade "${mods[@]}"; fi
  task "apt full-upgrade" upgrade_all
  task "Remove unused packages" "${APT[@]}" autoremove --purge
  task "Verify DKMS modules for kernel $(newest_kernel)" dkms_ok
  [[ -f /var/run/reboot-required ]] && mark_reboot || true
}

st_driver() {
  local v major
  if gpu_ok && v=$(drv_ver) && major=${v%%.*} && ((major >= 580)); then
    log "keeping working driver $v (B300 needs R580+ open modules)"
    if ! dpkg -l 'nvidia-driver-pinning*' 2>/dev/null | q '^ii' && has_candidate "nvidia-driver-pinning-$major"; then
      task "Pin driver branch $major" apt_install "nvidia-driver-pinning-$major"
    fi
    if ! installed nvidia-fabricmanager && ! installed "nvidia-fabricmanager-$major"; then
      local sfx fv nv done=0
      for sfx in "" "-$major"; do
        fv=$(pkg_ver "nvidia-fabricmanager$sfx" "$v"); [[ -n $fv ]] || continue
        nv=$(pkg_ver "libnvidia-nscq$sfx" "$v")
        task "Install fabric manager $fv" apt_install "nvidia-fabricmanager$sfx=$fv" ${nv:+"libnvidia-nscq$sfx=$nv"}
        done=1; break
      done
      ((done)) || { echo "no nvidia-fabricmanager matching driver $v"; return 1; }
    fi
    installed nvlsm || task "Install NVLSM" apt_install_avail nvlsm
    if ! installed libnvsdm; then
      local sv; sv=$(pkg_ver libnvsdm "$v")
      if [[ -n $sv ]]; then task "Install libnvsdm" apt_install "libnvsdm=$sv"; fi
    fi
  else
    [[ -n ${v:-} ]] && log "driver ${v} is too old for B300 - installing R580"
    if has_candidate nvidia-driver-pinning-580; then task "Pin driver branch 580" apt_install nvidia-driver-pinning-580; fi
    if has_candidate nvidia-driver-580-open; then
      task "Install R580 open driver + fabric manager" apt_install nvidia-driver-580-open libnvidia-nscq nvidia-modprobe nvidia-fabricmanager
    else
      task "Install R580 open driver + fabric manager" apt_install nvidia-open nvidia-fabricmanager libnvidia-nscq
    fi
    task "Install NVLSM, persistence" apt_install_avail nv-persistence-mode nvlsm libnvsdm
    mark_reboot
  fi
  task "Install DCGM / MIG manager" apt_install_avail datacenter-gpu-manager-4-cuda13 nvidia-mig-manager
  if ! dpkg -l 'nvidia-driver-pinning-*' 2>/dev/null | q '^ii'; then
    v=${v:-$(dpkg-query -W -f='${Version}' nvidia-fabricmanager 2>/dev/null | cut -d- -f1)}
    if [[ -n $v ]]; then
      dpkg-query -W -f='${Package} ${Version}\n' | awk -v v="$v" 'index($2, v) == 1 {print $1}' | xargs -r apt-mark hold
    fi
  fi
  local s; for s in nvidia-persistenced nvidia-fabricmanager nvidia-dcgm; do
    systemctl list-unit-files "$s.service" >/dev/null 2>&1 && systemctl enable "$s" >/dev/null 2>&1 || true
  done
  if ! is_dgx && has_candidate nvidia-system-core; then
    task "Install DGX platform config packages" apt_install_avail nvidia-system-core nvidia-system-utils nvidia-peermem-loader nvidia-grub-params nvdebug
  fi
}

st_doca() {
  flag INSTALL_DOCA || { log "INSTALL_DOCA=0 - skipped"; return 0; }
  lspci -d 15b3: | q -i 'ethernet\|infiniband' || { log "no ConnectX NICs - skipped"; return 0; }
  if have ofed_info && ofed_info -s >/dev/null 2>&1; then
    log "DOCA-OFED present: $(ofed_info -s)"
  elif has_candidate nvidia-system-mlnx-drivers; then
    task "Install DOCA-OFED (nvidia-system-mlnx-drivers)" apt_install nvidia-system-mlnx-drivers; mark_reboot
  else
    if ! has_candidate doca-ofed; then
      curl -fsSL https://linux.mellanox.com/public/repo/doca/GPG-KEY-Mellanox.pub \
        | gpg --dearmor --yes -o /usr/share/keyrings/GPG-KEY-Mellanox.gpg
      echo "deb [signed-by=/usr/share/keyrings/GPG-KEY-Mellanox.gpg] https://linux.mellanox.com/public/repo/doca/latest/ubuntu24.04/x86_64/ ./" \
        > /etc/apt/sources.list.d/doca.list
      task "apt update" apt_update
    fi
    task "Install DOCA-OFED" apt_install doca-ofed; mark_reboot
  fi
  task "Install RDMA tools" apt_install_avail infiniband-diags rdma-core ibverbs-utils perftest mstflint
  installed nvidia-peermem-loader || printf '%s\n' nvidia-peermem ib_umad > /etc/modules-load.d/b300-rdma.conf
  modprobe ib_umad 2>/dev/null || true
  modprobe nvidia-peermem 2>/dev/null || true
}

st_docker() {
  flag INSTALL_DOCKER || { log "INSTALL_DOCKER=0 - skipped"; return 0; }
  if have snap && snap list docker >/dev/null 2>&1; then task "Remove snap docker" snap remove --purge docker; fi
  if ! installed docker-ce; then
    "${APT[@]}" remove docker.io docker-doc docker-compose podman-docker containerd runc >/dev/null 2>&1 || true
    if ! has_candidate docker-ce; then
      install -m 0755 -d /etc/apt/keyrings
      curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
      echo "deb [arch=amd64 signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu noble stable" \
        > /etc/apt/sources.list.d/docker.list
      task "apt update" apt_update
    fi
    task "Install Docker CE" apt_install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
  fi
  if ! has_candidate nvidia-container-toolkit; then
    curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey \
      | gpg --dearmor --yes -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg
    curl -fsSL https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list \
      | sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' \
      > /etc/apt/sources.list.d/nvidia-container-toolkit.list
    task "apt update" apt_update
  fi
  task "Install NVIDIA Container Toolkit" apt_install nvidia-container-toolkit
  apt_install_avail nv-docker-options >/dev/null 2>&1 || true
  # register the runtime but don't make it default: NGC images bake in
  # NVIDIA_VISIBLE_DEVICES=all and would grab every GPU without --gpus
  nvidia-ctk runtime configure --runtime=docker
  local f=/etc/docker/daemon.json patch
  [[ -s $f ]] || echo '{}' > $f
  patch='.["default-ulimits"] = {"memlock":{"Name":"memlock","Hard":-1,"Soft":-1},"nofile":{"Name":"nofile","Hard":1048576,"Soft":1048576},"stack":{"Name":"stack","Hard":67108864,"Soft":67108864}}
         | .["log-driver"] = "json-file" | .["log-opts"] = {"max-size":"100m","max-file":"3"}'
  if mountpoint -q /raid && [[ -z $(ls -A /var/lib/docker/containers 2>/dev/null) ]]; then
    mkdir -p /raid/docker; patch+=' | .["data-root"] = "/raid/docker"'
  fi
  jq "$patch" $f > $f.tmp && mv $f.tmp $f
  systemctl enable docker >/dev/null 2>&1
  task "Restart Docker" systemctl restart docker
  usermod -aG docker "$SETUP_USER" || true
}

st_cuda() {
  local v major tk=cuda-toolkit-13
  v=$(drv_ver || true); major=${v%%.*}
  [[ ${major:-580} == 580 ]] && tk=cuda-toolkit-13-0   # stay on the CUDA matching R580
  task "Install $tk (nvcc, libraries, Nsight)" apt_install "$tk"
  task "Install cuDNN 9 + NCCL" apt_install_avail cudnn9-cuda-13 libnccl2 libnccl-dev
  if flag INSTALL_GDS; then task "Install GPUDirect Storage" apt_install_avail nvidia-gds; fi
  cat > /etc/profile.d/cuda.sh <<'EOF'
export CUDA_HOME=/usr/local/cuda
case ":$PATH:" in *":/usr/local/cuda/bin:"*) ;; *) export PATH="/usr/local/cuda/bin:$PATH" ;; esac
EOF
  log "$(/usr/local/cuda/bin/nvcc --version | tail -1)"
}

st_raid() {
  if mountpoint -q /raid; then log "/raid mounted ($(df -h --output=size /raid | tail -1 | tr -d ' ')) - untouched"; return 0; fi
  if is_dgx; then
    # DGX OS owns /raid (nvidia-raid-config + raid.mount). Never rebuild it here.
    echo "/raid is not mounted on this DGX. Inspect: systemctl status raid.mount nvidia-raid-config; cat /proc/mdstat"
    return 1
  fi
  flag CONFIGURE_RAID || { log "CONFIGURE_RAID=0 - leaving disks alone"; return 0; }
  local root_disk disks=() d
  root_disk=$(lsblk -no PKNAME "$(findmnt -no SOURCE /)" 2>/dev/null | tail -1)
  for d in $(lsblk -dnpo NAME,TYPE | awk '$2=="disk" && $1 ~ /nvme/ {print $1}'); do
    [[ $(basename "$d") == "$root_disk" ]] && continue
    [[ $(lsblk -no NAME "$d" | wc -l) -gt 1 ]] && continue
    [[ -n $(blkid -p "$d" 2>/dev/null) ]] && continue
    disks+=("$d")
  done
  ((${#disks[@]})) || { log "no empty NVMe drives"; return 0; }
  task "Create RAID0 on ${#disks[@]} NVMe drives" sh -c "mdadm --create /dev/md/raid --run --level=0 --raid-devices=${#disks[@]} ${disks[*]} && mkfs.ext4 -F /dev/md/raid"
  mdadm --detail --scan | grep -F /dev/md/raid >> /etc/mdadm/mdadm.conf
  update-initramfs -u >/dev/null
  mkdir -p /raid
  echo "UUID=$(blkid -s UUID -o value /dev/md/raid) /raid ext4 defaults,nofail,noatime 0 2" >> /etc/fstab
  mount /raid; chmod 1777 /raid
}

st_tuning() {
  # Complements DGX OS (which already sets governor, persistence, ACS, iommu=pt)
  cat > /etc/sysctl.d/90-b300.conf <<'EOF'
# written by b300-setup
kernel.perf_event_paranoid = 1
vm.max_map_count = 1048576
vm.swappiness = 1
fs.inotify.max_user_watches = 1048576
fs.inotify.max_user_instances = 8192
# 400/800G networking
net.core.rmem_max = 536870912
net.core.wmem_max = 536870912
net.ipv4.tcp_rmem = 4096 87380 536870912
net.ipv4.tcp_wmem = 4096 65536 536870912
net.core.netdev_max_backlog = 250000
net.core.somaxconn = 65535
net.ipv4.tcp_mtu_probing = 1
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
EOF
  echo tcp_bbr > /etc/modules-load.d/bbr.conf; modprobe tcp_bbr || true
  sysctl --system >/dev/null 2>&1 || log "some sysctls were rejected"
  cat > /etc/security/limits.d/90-b300.conf <<'EOF'
# pinned memory for NCCL / RDMA / CUDA host allocations
*    soft memlock unlimited
*    hard memlock unlimited
*    soft nofile  1048576
*    hard nofile  1048576
*    soft stack   65536
root soft memlock unlimited
root hard memlock unlimited
root soft nofile  1048576
root hard nofile  1048576
EOF
  mkdir -p /etc/systemd/system.conf.d /etc/systemd/user.conf.d
  printf '[Manager]\nDefaultLimitMEMLOCK=infinity\nDefaultLimitNOFILE=1048576\n' \
    | tee /etc/systemd/system.conf.d/90-b300.conf > /etc/systemd/user.conf.d/90-b300.conf

  cat > /usr/local/sbin/b300-tune <<EOF
#!/bin/bash
# applied at every boot by b300-tune.service (no-ops where DGX OS already did it)
for g in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do echo performance > "\$g" 2>/dev/null; done
for e in /sys/devices/system/cpu/cpu*/cpufreq/energy_performance_preference; do echo performance > "\$e" 2>/dev/null; done
echo madvise > /sys/kernel/mm/transparent_hugepage/enabled 2>/dev/null
echo defer+madvise > /sys/kernel/mm/transparent_hugepage/defrag 2>/dev/null
command -v nvidia-smi >/dev/null && nvidia-smi -pm 1 >/dev/null 2>&1
# PCIe ACS routes P2P/GPUDirect through the root complex. Bare metal only.
if [[ "$TUNE_ACS" == 1 ]] && [[ "\$(systemd-detect-virt)" == none ]] && ! systemctl is-enabled -q nvidia-acs-disable 2>/dev/null; then
  for bdf in \$(lspci | awk '{print \$1}'); do
    setpci -v -s "\$bdf" ECAP_ACS+0x6.w >/dev/null 2>&1 || continue
    setpci -s "\$bdf" ECAP_ACS+0x6.w=0000 2>/dev/null
  done
fi
exit 0
EOF
  chmod 755 /usr/local/sbin/b300-tune
  cat > /etc/systemd/system/b300-tune.service <<'EOF'
[Unit]
Description=B300 performance tuning (governor, THP, persistence, ACS)
After=nvidia-persistenced.service
Before=nvidia-fabricmanager.service docker.service

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/b300-tune
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable --now b300-tune.service >/dev/null 2>&1
  if [[ $(systemd-detect-virt || true) == none ]] && ! grep -qw 'iommu=pt' /proc/cmdline \
     && ! grep -rqs 'iommu=pt' /etc/default/grub /etc/default/grub.d/; then
    echo 'GRUB_CMDLINE_LINUX_DEFAULT="$GRUB_CMDLINE_LINUX_DEFAULT iommu=pt"' > /etc/default/grub.d/99-b300.cfg
    task "update-grub (iommu=pt)" update-grub && mark_reboot
  fi
  local hf=""
  if mountpoint -q /raid; then mkdir -p /raid/hf /raid/uv-cache; chmod 1777 /raid/hf /raid/uv-cache; hf=1; fi
  cat > /etc/profile.d/b300-env.sh <<EOF
# written by b300-setup
${hf:+export HF_HOME=/raid/hf}
${hf:+export UV_CACHE_DIR=/raid/uv-cache}
export UV_LINK_MODE=copy
alias ml='source /opt/venvs/ml/bin/activate'
alias vl='source /opt/venvs/vllm/bin/activate'
alias sgl='source /opt/venvs/sglang/bin/activate'
alias gpus='nvidia-smi --query-gpu=index,name,temperature.gpu,temperature.memory,power.draw,utilization.gpu,memory.used,memory.total --format=csv'
EOF
  log "sysctl · limits · b300-tune.service · /etc/profile.d/b300-env.sh"
}

st_nccltests() {
  [[ -x /opt/nccl-tests/build/all_reduce_perf ]] && { log "already built"; return 0; }
  rm -rf /opt/nccl-tests
  task "Clone nccl-tests" git clone --depth 1 https://github.com/NVIDIA/nccl-tests.git /opt/nccl-tests
  task "Build nccl-tests (sm_100 / sm_103)" make -C /opt/nccl-tests -j"$(nproc)" CUDA_HOME=/usr/local/cuda NCCL_HOME=/usr \
    NVCC_GENCODE="-gencode=arch=compute_100,code=sm_100 -gencode=arch=compute_103,code=sm_103 -gencode=arch=compute_103,code=compute_103"
  ln -sf /opt/nccl-tests/build/all_reduce_perf /usr/local/bin/all_reduce_perf
}

st_python() {
  have uv || task "Install uv" sh -c 'curl -LsSf https://astral.sh/uv/install.sh | env UV_INSTALL_DIR=/usr/local/bin UV_NO_MODIFY_PATH=1 sh'
  install -d -o "$SETUP_USER" -g "$(id -gn "$SETUP_USER")" /opt/venvs /opt/venvs/.python
  # python lives under /opt so every user (and root) can run the venvs
  UVENV=(UV_LINK_MODE=copy UV_PYTHON_PREFERENCE=managed UV_PYTHON_INSTALL_DIR=/opt/venvs/.python)
  if mountpoint -q /raid; then UVENV+=(UV_CACHE_DIR=/raid/uv-cache); fi
  mk()   { [[ -x /opt/venvs/$1/bin/python ]] || as_user env "${UVENV[@]}" uv venv -q --python 3.12 "/opt/venvs/$1"; }
  pipi() { local v=$1; shift; as_user env "${UVENV[@]}" uv pip install --python "/opt/venvs/$v/bin/python" "$@"; }

  mk ml
  # torch built for the CUDA minor the driver ships (R580 = CUDA 13.0); PyPI's
  # default wheel tracks the newest CUDA and relies on minor-version compat
  local v; v=$(drv_ver || true)
  if [[ ${v%%.*} == 580 || -z $v ]]; then
    task "ml: torch (cu130 build, matches R580)" pipi ml --index-url https://download.pytorch.org/whl/cu130 torch torchvision torchaudio
  else
    task "ml: torch" pipi ml torch torchvision torchaudio
  fi
  local tv; tv=$(/opt/venvs/ml/bin/python -c 'import torch;print(torch.__version__)')
  echo "torch==${tv%%+*}" > /opt/venvs/.torch-pin.txt   # base version matches the local +cuXXX build
  task "ml: training / research stack" pipi ml -c /opt/venvs/.torch-pin.txt \
    transformers accelerate datasets tokenizers safetensors sentencepiece tiktoken \
    "huggingface_hub[hf_xet]" peft trl einops numpy scipy pandas pyarrow polars \
    scikit-learn matplotlib seaborn jupyterlab ipython ipywidgets tqdm rich \
    tensorboard wandb mlflow nvitop gpustat nvidia-ml-py py-spy ninja packaging
  local extra
  for extra in bitsandbytes liger-kernel lm-eval torchao "flash-attn-4>=4.0.0b0"; do
    task "ml: ${extra%%>*}" pipi ml -c /opt/venvs/.torch-pin.txt "$extra" || true
  done
  # deepspeed imports torch in setup.py
  task "ml: deepspeed" pipi ml -c /opt/venvs/.torch-pin.txt --no-build-isolation-package deepspeed deepspeed || true
  local b; for b in nvitop gpustat hf jupyter py-spy; do
    [[ -x /opt/venvs/ml/bin/$b ]] && ln -sf "/opt/venvs/ml/bin/$b" "/usr/local/bin/$b"
  done
  if flag INSTALL_VLLM; then
    mk vllm; task "vllm venv (own torch)" pipi vllm vllm "huggingface_hub[hf_xet]" || true
  fi
  if flag INSTALL_SGLANG; then
    # sglang needs a pre-release flash-attn-4; naming it explicitly lets uv pick it
    mk sglang; task "sglang venv (own torch)" pipi sglang sglang "flash-attn-4>=4.0.0b0" "huggingface_hub[hf_xet]" || true
  fi
  return 0
}

reboot_checkpoint() {
  if [[ ! -f $STATE/.reboot-needed ]] && gpu_ok; then return 0; fi
  local n; n=$(cat "$STATE/.reboots" 2>/dev/null || echo 0)
  if ((n >= 2)); then emit "  ${YE}!${Z} rebooted $n times and GPUs still unhealthy - continuing so the report shows why"; rm -f "$STATE/.reboot-needed"; return 0; fi
  if ! task "Verify DKMS modules for kernel $(newest_kernel)" dkms_ok; then
    box "$RD" "Not rebooting" "DKMS modules failed to build for $(newest_kernel)." \
      "Rebooting now could leave the GPUs or NICs without drivers." "Check ${BO}dkms status${Z} and $LOG, then re-run ${BO}sudo b300-setup${Z}"
    exit 1
  fi
  cat > /etc/systemd/system/$UNIT-resume.service <<EOF
[Unit]
Description=Resume B300 node setup after reboot
Wants=network-online.target
After=network-online.target nvidia-fabricmanager.service

[Service]
Type=exec
Environment=B300_DETACHED=1
ExecStart=/bin/bash $SELF --run
StandardOutput=append:$LOG
StandardError=append:$LOG
TimeoutStartSec=0

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload; systemctl enable "$UNIT-resume.service" >/dev/null 2>&1
  echo $((n + 1)) > "$STATE/.reboots"; rm -f "$STATE/.reboot-needed"
  if flag AUTO_REBOOT; then
    emit ""; box "$YE" "Rebooting" "New driver / kernel needs a reboot. Setup resumes on its own." \
      "Reconnect in ~5 minutes, then run   ${BO}${WH}b300-setup -f${Z}"
    sleep 12; systemctl reboot; sleep 600; exit 0
  else
    emit ""; box "$YE" "Reboot required" "AUTO_REBOOT=0. Run ${BO}sudo reboot${Z} - setup resumes on boot."
    exit 0
  fi
}

wait_fabric() {
  local i n good
  for i in $(seq 1 60); do gpu_ok && break; sleep 5; done
  gpu_ok || return 1
  n=$(nvidia-smi -L | wc -l)
  for i in $(seq 1 60); do
    good=$(fabric_states | grep -c '^Completed Success' || true)
    ((good >= n)) && return 0; sleep 5
  done
  return 1
}

# =============================================================================
#  FUNCTIONAL TESTS
# =============================================================================
run_functional() {
  set +e
  local n tmp busbw peak; tmp=$(mktemp -d); chmod 755 "$tmp"
  n=$(nvidia-smi -L 2>/dev/null | wc -l)
  mountpoint -q /raid && HF_HOME=/raid/hf
  local UENV="${HF_HOME:+HF_HOME=$HF_HOME} ${HF_TOKEN:+HF_TOKEN=$HF_TOKEN}"
  local RUNU="sudo -u $SETUP_USER -H env $UENV"

  rule "Diagnostics"
  if have dcgmi && systemctl is-active -q nvidia-dcgm; then
    task "DCGM diagnostic level ${DCGM_LEVEL}" sh -c "timeout 3600 dcgmi diag -r ${DCGM_LEVEL} > $tmp/dcgm.txt 2>&1"
    cat "$tmp/dcgm.txt" >> "$LOG"
    if q -E '\b(Fail|FAIL)\b' "$tmp/dcgm.txt"; then
      bad "dcgmi diag -r $DCGM_LEVEL" "$(grep -E '\b(Fail|FAIL)\b' "$tmp/dcgm.txt" | head -2 | tr -s ' |' ' ' | tr '\n' ';')"
    elif q -E 'Pass' "$tmp/dcgm.txt"; then ok "dcgmi diag -r $DCGM_LEVEL" "$(grep -c Pass "$tmp/dcgm.txt") checks passed"
    else bad "dcgmi diag -r $DCGM_LEVEL" "no result - see $LOG"; fi
  else note "DCGM" "not available - skipped"; fi
  chk_nvsm

  rule "Containers"
  if have docker; then
    if task "docker run --gpus all" sh -c "timeout 600 docker run --rm --gpus all ubuntu:24.04 nvidia-smi -L > $tmp/d.txt 2>&1"; then
      ok "Container GPU access" "$(grep -c '^GPU' "$tmp/d.txt") GPUs visible in container"
    else bad "Container GPU access" "docker run --gpus all failed"; cat "$tmp/d.txt" >> "$LOG"; fi
  else note "Docker" "not installed - skipped"; fi

  rule "Collective bandwidth · NVLink5 / NVSwitch"
  if [[ -x /opt/nccl-tests/build/all_reduce_perf ]] && ((n > 1)); then
    if task "nccl-tests all_reduce_perf ×$n (256M → 8G)" sh -c \
        "timeout 900 /opt/nccl-tests/build/all_reduce_perf -b 256M -e 8G -f 2 -g $n -c 1 -w 5 -n 20 > $tmp/nccl.txt 2>&1"; then
      cat "$tmp/nccl.txt" >> "$LOG"
      peak=$(awk '/^ +[0-9]+/{if ($12+0 > m) m = $12+0} END {print int(m)}' "$tmp/nccl.txt")
      busbw=$(awk '/Avg bus bandwidth/{print $NF}' "$tmp/nccl.txt")
      local l; while IFS= read -r l; do log "$l"; done < <(awk '/^ +[0-9]+/{
          bar = ""; for (i = 0; i < int($12 / 25); i++) bar = bar "█"
          printf "%7.0f MB  %6.1f GB/s  %s\n", $1/1048576, $12, bar }' "$tmp/nccl.txt")
      if q 'Out of bounds values : [1-9]' "$tmp/nccl.txt"; then bad "NCCL all_reduce" "data corruption reported"
      elif ((peak >= NCCL_MIN_BUSBW)); then ok "NCCL all_reduce ×$n" "peak ${peak} GB/s busbw (avg ${busbw}) ≥ ${NCCL_MIN_BUSBW}"
      else bad "NCCL all_reduce ×$n" "peak ${peak} GB/s < ${NCCL_MIN_BUSBW} floor - check fabric / NVLink"; fi
    else bad "NCCL all_reduce" "test failed - see $LOG"; cat "$tmp/nccl.txt" >> "$LOG"; fi
  else note "nccl-tests" "not built - skipped"; fi

  rule "PyTorch"
  if [[ -x /opt/venvs/ml/bin/python ]]; then
    cat > "$tmp/torch_test.py" <<'EOF'
import time, torch
n = torch.cuda.device_count()
print(f"TORCH_VER {torch.__version__} cuda {torch.version.cuda} cc {torch.cuda.get_device_capability(0)}")
res = []
for d in range(n):
    torch.cuda.set_device(d)
    a = torch.randn(16384, 16384, device=d, dtype=torch.bfloat16); b = torch.randn_like(a)
    for _ in range(3): a @ b
    torch.cuda.synchronize(); t = time.perf_counter(); it = 20
    for _ in range(it): a @ b
    torch.cuda.synchronize(); res.append(2 * 16384**3 * it / (time.perf_counter() - t) / 1e12)
print("TFLOPS", " ".join(f"{x:.0f}" for x in res))
p2p = all(torch.cuda.can_device_access_peer(i, j) for i in range(n) for j in range(n) if i != j)
x = torch.ones(1 << 28, device=0); y = x.to(n - 1); torch.cuda.synchronize(); t = time.perf_counter()
for _ in range(10): y.copy_(x)
torch.cuda.synchronize(); print(f"COPY {10 * x.numel() * 4 / (time.perf_counter() - t) / 1e9:.0f}")
print(f"TORCH_OK {min(res):.0f} {max(res):.0f} {p2p}")
EOF
    if task "bf16 GEMM on every GPU + P2P copy" sh -c "$RUNU /opt/venvs/ml/bin/python $tmp/torch_test.py > $tmp/torch.txt 2>&1" \
       && q TORCH_OK "$tmp/torch.txt"; then
      local mn mx p2p; read -r _ mn mx p2p < <(grep TORCH_OK "$tmp/torch.txt")
      ok "PyTorch $(awk '/TORCH_VER/{print $2}' "$tmp/torch.txt")" "CUDA $(awk '/TORCH_VER/{print $4}' "$tmp/torch.txt") · all $n GPUs compute"
      ((mn * 2 > mx)) && ok "bf16 GEMM 16k³" "${mn}–${mx} TFLOPS per GPU" || bad "bf16 GEMM imbalance" "${mn}–${mx} TFLOPS - one GPU is slow"
      [[ $p2p == True ]] && ok "GPU peer-to-peer" "all pairs · GPU0→GPU$((n - 1)) $(awk '/COPY/{print $2}' "$tmp/torch.txt") GB/s" \
                         || bad "GPU peer-to-peer" "not all pairs can access each other"
    else bad "PyTorch GPU test" "$(tail -1 "$tmp/torch.txt" | cut -c1-80)"; cat "$tmp/torch.txt" >> "$LOG"; fi

    cat > "$tmp/dist_test.py" <<'EOF'
import os, time, torch, torch.distributed as dist
dist.init_process_group("nccl"); r = dist.get_rank(); w = dist.get_world_size()
torch.cuda.set_device(int(os.environ["LOCAL_RANK"]))
x = torch.ones(1 << 28, device="cuda", dtype=torch.bfloat16)
for _ in range(5): dist.all_reduce(x)
torch.cuda.synchronize(); t = time.perf_counter()
for _ in range(20): dist.all_reduce(x)
torch.cuda.synchronize(); dt = (time.perf_counter() - t) / 20
if r == 0: print(f"DIST_OK {x.numel()*2*2*(w-1)/w/dt/1e9:.0f}")
dist.destroy_process_group()
EOF
    if ((n > 1)); then
      if task "torch.distributed all_reduce (torchrun ×$n as $SETUP_USER)" sh -c \
          "$RUNU timeout 600 /opt/venvs/ml/bin/torchrun --standalone --nproc_per_node=$n $tmp/dist_test.py > $tmp/dist.txt 2>&1" \
         && q DIST_OK "$tmp/dist.txt"; then
        ok "torch.distributed NCCL ×$n" "$(awk '/DIST_OK/{print $2}' "$tmp/dist.txt") GB/s busbw (512 MiB)"
      else bad "torch.distributed NCCL" "failed as $SETUP_USER (FM socket permissions?)"; cat "$tmp/dist.txt" >> "$LOG"; fi
    fi

    cat > "$tmp/hf_test.py" <<EOF
import torch
from transformers import AutoModelForCausalLM, AutoTokenizer
m = "${TEST_MODEL}"
tok = AutoTokenizer.from_pretrained(m)
model = AutoModelForCausalLM.from_pretrained(m, dtype=torch.bfloat16, device_map="cuda:0")
msgs = [{"role": "user", "content": "In one sentence, what is an NVIDIA B300?"}]
enc = tok.apply_chat_template(msgs, add_generation_prompt=True, enable_thinking=False,
                              return_tensors="pt", return_dict=True).to("cuda:0")
out = model.generate(**enc, max_new_tokens=64, do_sample=False)
print("HF_OUT:", tok.decode(out[0][enc["input_ids"].shape[-1]:], skip_special_tokens=True).strip().replace("\n", " ")[:200])
EOF
    if task "transformers generate ($TEST_MODEL)" sh -c "$RUNU timeout 900 /opt/venvs/ml/bin/python $tmp/hf_test.py > $tmp/hf.txt 2>&1" \
       && q HF_OUT "$tmp/hf.txt"; then
      ok "transformers inference" "$TEST_MODEL"
      log "${IT}“$(grep HF_OUT "$tmp/hf.txt" | cut -d' ' -f2- | cut -c1-110)”"
    else bad "transformers inference" "$(tail -1 "$tmp/hf.txt" | cut -c1-80)"; cat "$tmp/hf.txt" >> "$LOG"; fi
  else note "ml venv" "missing - skipped"; fi

  rule "Inference engines"
  if [[ -x /opt/venvs/vllm/bin/python ]] && /opt/venvs/vllm/bin/python -c 'import vllm' 2>/dev/null; then
    cat > "$tmp/vllm_test.py" <<EOF
import time
from vllm import LLM, SamplingParams
llm = LLM(model="${TEST_MODEL}", gpu_memory_utilization=0.30, max_model_len=4096)
o = llm.chat([{"role": "user", "content": "Say hello from a B300 in five words."}], SamplingParams(temperature=0.0, max_tokens=64))
print("VLLM_OUT:", o[0].outputs[0].text.strip().replace("\n", " ")[:200])
prompts = [f"Write a short story about GPU number {i}." for i in range(512)]
t = time.perf_counter(); outs = llm.generate(prompts, SamplingParams(temperature=0.8, max_tokens=256, ignore_eos=True))
print(f"VLLM_TPUT {sum(len(x.outputs[0].token_ids) for x in outs) / (time.perf_counter() - t):.0f}")
EOF
    if task "vLLM inference + 512-request throughput" sh -c \
        "$RUNU CUDA_VISIBLE_DEVICES=0 timeout 1200 /opt/venvs/vllm/bin/python $tmp/vllm_test.py > $tmp/vllm.txt 2>&1" \
       && q VLLM_TPUT "$tmp/vllm.txt"; then
      ok "vLLM $(/opt/venvs/vllm/bin/python -c 'import vllm;print(vllm.__version__)' 2>/dev/null)" "$(awk '/VLLM_TPUT/{print $2}' "$tmp/vllm.txt") output tok/s on 1 GPU ($TEST_MODEL)"
      log "${IT}“$(grep VLLM_OUT "$tmp/vllm.txt" | cut -d' ' -f2- | cut -c1-110)”"
    else bad "vLLM smoke test" "$(grep -iE 'error' "$tmp/vllm.txt" | tail -1 | cut -c1-80)"; cat "$tmp/vllm.txt" >> "$LOG"; fi
  elif flag INSTALL_VLLM; then bad "vLLM" "venv missing or not importable"; fi
  if [[ -x /opt/venvs/sglang/bin/python ]]; then
    local sv
    if sv=$(/opt/venvs/sglang/bin/python -c 'import sglang;print(sglang.__version__)' 2>/dev/null); then ok "SGLang" "$sv importable"
    else bad "SGLang" "import failed"; fi
  fi
  rm -rf "$tmp"
  return 0
}

write_report() {
  {
    echo "B300 setup report · $(hostname) · $(date -Is) · b300-setup v$VERSION"
    echo "passed $N_PASS · warnings $N_WARN · failed $N_FAIL"
    echo; printf '%s\n' "${RES[@]}"
  } > "$REPORT"
}

next_steps() {
  emit ""
  box "$GR" "You're set" \
    "${GR}ml${Z}       source /opt/venvs/ml/bin/activate   ${DI}(alias ml, new shell)${Z}" \
    "${GR}vllm${Z}     /opt/venvs/vllm/bin/vllm serve <model> --tensor-parallel-size 8" \
    "${GR}sglang${Z}   /opt/venvs/sglang/bin/python -m sglang.launch_server --model-path <m> --tp 8" \
    "${GR}watch${Z}    nvitop · gpus · all_reduce_perf -b 1G -e 8G -f 2 -g 8" \
    "${GR}health${Z}   b300-setup --check · sudo b300-setup --test" \
    "${GR}report${Z}   $REPORT" \
    "${DI}log out and back in once so the docker group + limits apply${Z}"
}

# =============================================================================
#  MAIN
# =============================================================================
usage() {
  banner "setup · tuning · diagnostics"
  emit ""
  emit "  ${BO}curl -sL is.gd/b300sh | sudo bash${Z}     install everything"
  emit "  ${BO}b300-setup --check${Z}  ${DI}-c${Z}   read-only pre-flight / health report"
  emit "  ${BO}b300-setup --test${Z}   ${DI}-t${Z}   health report + GPU / NCCL / vLLM tests"
  emit "  ${BO}b300-setup --follow${Z} ${DI}-f${Z}   re-attach to a running install"
  emit "  ${BO}b300-setup --status${Z} ${DI}-s${Z}   step status"
  emit "  ${BO}b300-setup --reset${Z}        forget completed steps"
  emit ""
}

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
  -f|--follow) follow; exit 0 ;;
  -s|--status)
    persist_knobs; banner "status"; plan
    [[ -f $REPORT ]] && emit "" && emit "  ${DI}last report: $REPORT${Z}"
    if systemctl is-active -q "$UNIT" || systemctl is-active -q "$UNIT-resume"; then emit "  ${CY}● install running - b300-setup -f${Z}"; fi
    exit 0 ;;
  --reset) rm -rf "$STATE"; echo "state cleared"; exit 0 ;;
  -c|--check)
    persist_knobs; banner "pre-flight check · read-only"
    run_checks; plan; summary "Pre-flight"; write_report
    ((N_FAIL == 0)); exit $? ;;
  -t|--test)
    persist_knobs; banner "diagnostics + functional tests"
    run_checks; run_functional; summary "Diagnostics"; write_report
    ((N_FAIL == 0)); exit $? ;;
  ""|--run) ;;
  *) usage; exit 2 ;;
esac

# detach into a systemd unit so SSH drops / reboots can't kill the install
if [[ -z "${B300_DETACHED:-}" ]]; then
  persist_knobs
  if systemctl is-active -q "$UNIT" || systemctl is-active -q "$UNIT-resume"; then
    echo "setup already running - attaching"
  else
    systemctl reset-failed "$UNIT" >/dev/null 2>&1 || true
    : > "$EVENTS"
    tput cols > "$STATE/cols" 2>/dev/null || true
    systemd-run --unit="$UNIT" --description="B300 node setup" \
      --setenv=B300_DETACHED=1 -p TimeoutStartSec=0 \
      -p StandardOutput=append:"$LOG" -p StandardError=append:"$LOG" \
      /bin/bash "$SELF" --run >/dev/null
  fi
  follow; exit 0
fi

# ---- detached runner
persist_knobs
B300_COLS=$(cat "$STATE/cols" 2>/dev/null || true)
if [[ -f $STATE/.reboots && ! -f $STATE/.resumed-$(cat "$STATE/.reboots") ]]; then
  touch "$STATE/.resumed-$(cat "$STATE/.reboots")"
  emit ""; box "$CY" "Resumed after reboot" "kernel $(uname -r) · driver $(drv_ver || echo '?')"
else
  banner "setup · tuning · diagnostics"
  emit "  ${DI}user ${SETUP_USER} · log ${LOG} · Ctrl-C detaches, setup keeps running${Z}"
fi
rm -f "$STATE/.failed"

run_step preflight st_preflight
run_step base      st_base
run_step repos     st_repos
run_step upgrade   st_upgrade
run_step driver    st_driver
run_step doca      st_doca
run_step docker    st_docker
run_step cuda      st_cuda
run_step raid      st_raid
run_step tuning    st_tuning
reboot_checkpoint
task "Waiting for NVLink fabric" wait_fabric || emit "  ${YE}!${Z} fabric not ready - the report will show details"
run_step nccltests st_nccltests
run_step python    st_python

systemctl disable "$UNIT-resume.service" >/dev/null 2>&1 || true
rm -f "/etc/systemd/system/$UNIT-resume.service"; systemctl daemon-reload

rule "[$(( ${#STEPS[@]} + 1 ))/$(( ${#STEPS[@]} + 1 ))] Validation"
N_PASS=0 N_WARN=0 N_FAIL=0; FAILS=() WARNS=() RES=()
run_checks; run_functional
if [[ -f $STATE/.failed ]]; then for s in $(cat "$STATE/.failed"); do bad "install step '$s'" "failed - see $LOG"; done; fi
summary "B300 setup complete"; write_report; next_steps
