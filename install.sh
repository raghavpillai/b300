#!/usr/bin/env bash
# =============================================================================
#  b300-setup: one-shot bring-up + tuning + validation for NVIDIA DGX/HGX B300
#
#    curl -fsSL https://raghavpillai.github.io/b300 | sudo bash
#
#  Safe to re-run (each step is idempotent and checkpointed). Runs detached as
#  a systemd unit so an SSH drop can't kill it; reboots itself when the driver
#  or kernel changes and resumes automatically. Re-attach with:  b300-setup -f
#
#  Works on stock DGX OS 7 (keeps NVIDIA's preinstalled driver stack) and on
#  plain Ubuntu 24.04 (follows NVIDIA's "DGX software on Ubuntu" recipe).
#
#  Knobs (env vars, persisted to /etc/b300-setup.env on first run):
#    AUTO_REBOOT=1      reboot automatically when required, then resume
#    FULL_UPGRADE=1     apt full-upgrade the OS
#    INSTALL_DOCA=1     DOCA-OFED / ConnectX-8 drivers + nvidia-peermem
#    INSTALL_DOCKER=1   Docker CE + NVIDIA Container Toolkit
#    INSTALL_VLLM=1     vLLM venv at /opt/venvs/vllm
#    INSTALL_SGLANG=1   SGLang venv at /opt/venvs/sglang
#    INSTALL_GDS=0      GPUDirect Storage (nvidia-gds)
#    TUNE_ACS=1         disable PCIe ACS at boot (bare metal only, for GPUDirect)
#    CONFIGURE_RAID=0   DESTRUCTIVE: RAID0 all *empty* NVMe data drives -> /raid
#    TEST_MODEL=Qwen/Qwen3-0.6B   small model used for the smoke test
#    SETUP_USER=<you>   user who owns the venvs / gets docker group
#    HF_TOKEN=          optional, for gated models
# =============================================================================
set -Eeuo pipefail

SELF_URL="https://raghavpillai.github.io/b300/install.sh"
SELF=/usr/local/sbin/b300-setup
STATE=/var/lib/b300-setup
LOG=/var/log/b300-setup.log
REPORT=/var/log/b300-setup-report.txt
ENVFILE=/etc/b300-setup.env
UNIT=b300-setup
KNOBS=(AUTO_REBOOT FULL_UPGRADE INSTALL_DOCA INSTALL_DOCKER INSTALL_VLLM
       INSTALL_SGLANG INSTALL_GDS TUNE_ACS CONFIGURE_RAID TEST_MODEL SETUP_USER
       HF_TOKEN)

# ---------------------------------------------------------------- bootstrap --
# 1) make sure we live at $SELF (works for `curl | bash` and `bash file.sh`)
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
  exec "${SUDO[@]}" bash "$SELF" "$@"
fi
[[ $EUID -eq 0 ]] || exec sudo -E bash "$SELF" "$@"

usage() {
  cat <<EOF
b300-setup [option]
  (none)        run/continue setup detached and follow the log
  -f|--follow   re-attach to the log of a running setup
  -t|--test     re-run only the validation suite (foreground)
  -s|--status   show step status + last report
  --foreground  run setup in this terminal instead of a systemd unit
  --reset       forget completed steps (next run redoes everything)
EOF
}

follow() {
  echo ">>> following $LOG (Ctrl-C detaches; setup keeps running; re-attach: b300-setup -f)"
  touch "$LOG"
  tail -n 40 -F "$LOG" & local tp=$!
  trap 'kill $tp 2>/dev/null; echo; echo ">>> detached. re-attach: b300-setup -f"; exit 0' INT TERM
  sleep 2
  while systemctl is-active -q "$UNIT" || systemctl is-active -q "$UNIT-resume"; do sleep 3; done
  sleep 1; kill $tp 2>/dev/null || true
  [[ -f $REPORT ]] && { echo; cat "$REPORT"; }
}

persist_knobs() {
  # first run writes defaults; explicit env vars on later runs override
  local k; local -A ov=()
  for k in "${KNOBS[@]}"; do [[ -n ${!k+x} ]] && ov[$k]=${!k}; done
  [[ -f $ENVFILE ]] && . "$ENVFILE"
  for k in "${!ov[@]}"; do printf -v "$k" '%s' "${ov[$k]}"; done
  : "${AUTO_REBOOT:=1}" "${FULL_UPGRADE:=1}" "${INSTALL_DOCA:=1}" "${INSTALL_DOCKER:=1}"
  : "${INSTALL_VLLM:=1}" "${INSTALL_SGLANG:=1}" "${INSTALL_GDS:=0}" "${TUNE_ACS:=1}"
  : "${CONFIGURE_RAID:=0}" "${TEST_MODEL:=Qwen/Qwen3-0.6B}" "${HF_TOKEN:=}"
  : "${SETUP_USER:=${SUDO_USER:-root}}"
  umask 077
  for k in "${KNOBS[@]}"; do printf '%s=%q\n' "$k" "${!k}"; done > "$ENVFILE"
  umask 022
}

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
  -f|--follow) follow; exit 0 ;;
  -s|--status) { ls -1 "$STATE" | sed 's/^/done: /'; cat "$REPORT"; } 2>/dev/null || echo "no setup state yet"; exit 0 ;;
  --reset) rm -rf "$STATE"; echo "state cleared"; exit 0 ;;
esac

# 2) detach into a systemd unit unless told otherwise
if [[ -z "${B300_DETACHED:-}" && "${1:-}" != "--foreground" && "${1:-}" != "-t" && "${1:-}" != "--test" ]]; then
  persist_knobs
  if systemctl is-active -q "$UNIT" || systemctl is-active -q "$UNIT-resume"; then
    echo ">>> setup already running"
  else
    systemctl reset-failed "$UNIT" 2>/dev/null || true
    systemd-run --unit="$UNIT" --description="B300 node setup" \
      --setenv=B300_DETACHED=1 -p TimeoutStartSec=0 \
      -p StandardOutput=append:"$LOG" -p StandardError=append:"$LOG" \
      /bin/bash "$SELF" >/dev/null
    echo ">>> started systemd unit '$UNIT'"
  fi
  follow; exit 0
fi

persist_knobs
mkdir -p "$STATE"
if [[ -z "${B300_DETACHED:-}" ]]; then exec > >(tee -a "$LOG") 2>&1; fi

# ------------------------------------------------------------------ helpers --
export DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a NEEDRESTART_SUSPEND=1
C_B=$'\e[1m'; C_G=$'\e[32m'; C_Y=$'\e[33m'; C_R=$'\e[31m'; C_0=$'\e[0m'
ts()   { date '+%H:%M:%S'; }
log()  { echo "${C_B}[$(ts)]${C_0} $*"; }
ok()   { echo "${C_G}[$(ts)] OK${C_0}  $*"; }
warn() { echo "${C_Y}[$(ts)] WARN${C_0} $*"; }
err()  { echo "${C_R}[$(ts)] ERR${C_0}  $*"; }
die()  { err "$*"; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }
# grep -q exits early -> SIGPIPE upstream -> false failure under pipefail
q() { grep "$@" >/dev/null; }
flag() { [[ "${!1:-0}" == 1 ]]; }
mark_reboot() { touch "$STATE/.reboot-needed"; }

APT=(apt-get -y -q -o DPkg::Lock::Timeout=1800
     -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold)
apt_update()  { "${APT[@]}" update; }
apt_install() { "${APT[@]}" install "$@"; }
has_candidate() { apt-cache policy "$1" 2>/dev/null | q 'Candidate: [0-9]'; }
installed()     { dpkg-query -W -f='${Status}' "$1" 2>/dev/null | q 'ok installed'; }
# install whatever subset of the list actually exists in the configured repos
apt_install_avail() {
  local p want=()
  for p in "$@"; do has_candidate "$p" && want+=("$p") || warn "package not available: $p"; done
  ((${#want[@]})) && apt_install "${want[@]}"
}
as_user() { sudo -u "$SETUP_USER" -H env "PATH=/usr/local/bin:/usr/local/cuda/bin:$PATH" "$@"; }
# first version of $1 available in apt that starts with driver version $2
pkg_ver() { apt-cache madison "$1" 2>/dev/null | awk -F'|' -v v="$2" '{gsub(/ /,"",$2)} index($2, v) == 1 {print $2; exit}'; }
drv_ver() { nvidia-smi --query-gpu=driver_version --format=csv,noheader 2>/dev/null | head -1; }
gpu_ok()  { have nvidia-smi && nvidia-smi -L >/dev/null 2>&1; }
cuda_src_present() {
  grep -rqs 'developer.download.nvidia.com/compute/cuda/repos/ubuntu2404/x86_64' \
    /etc/apt/sources.list /etc/apt/sources.list.d/
}

FAILED=()
run_step() {   # run_step <name> <critical:0|1> <function>
  local name=$1 crit=$2 fn=$3 rc
  if [[ -f "$STATE/$name" ]]; then log "skip $name (done)"; return 0; fi
  echo; log "${C_B}==== $name ====${C_0}"
  set +e
  ( set -Eeuo pipefail
    trap 'err "step $name failed at line $LINENO: $BASH_COMMAND"' ERR
    "$fn" )
  rc=$?
  set -e
  if ((rc == 0)); then touch "$STATE/$name"; ok "$name"
  elif ((crit)); then die "critical step '$name' failed (rc=$rc). Fix and re-run: sudo b300-setup"
  else warn "step '$name' failed (rc=$rc), continuing"; FAILED+=("$name"); fi
}

# ------------------------------------------------------------------- steps ---
preflight() {
  . /etc/os-release
  [[ $(uname -m) == x86_64 ]] || die "B300 nodes are x86_64; got $(uname -m)"
  [[ ${VERSION_ID:-} == 24.04 ]] || die "expected Ubuntu 24.04 / DGX OS 7, got ${PRETTY_NAME:-unknown}"
  local product gpus nics virt free
  product=$(cat /sys/class/dmi/id/product_name 2>/dev/null || echo unknown)
  gpus=$(lspci -d 10de: 2>/dev/null | grep -ciE '3d controller|vga' || true)
  nics=$(lspci -d 15b3: 2>/dev/null | grep -ci 'ethernet\|infiniband' || true)
  virt=$(systemd-detect-virt 2>/dev/null || true)
  free=$(df -BG --output=avail / | tail -1 | tr -dc 0-9)
  log "host:     $(hostname)  product='$product'  virt=${virt:-none}"
  log "os:       ${PRETTY_NAME}  kernel $(uname -r)  DGX OS: $([[ -f /etc/dgx-release ]] && grep -h DGX_OTA_VERSION /etc/dgx-release | tail -1 || echo no)"
  log "gpus:     $gpus NVIDIA GPU(s) on PCIe; mellanox ports: $nics"
  log "cpu:      $(lscpu | awk -F: '/Model name/{gsub(/^ +/,"",$2);print $2; exit}') x$(nproc)  mem $(free -g | awk '/Mem/{print $2}')G"
  log "root fs:  ${free}G free; /raid: $(mountpoint -q /raid && df -h --output=size /raid | tail -1 || echo 'not mounted')"
  log "user:     $SETUP_USER"
  ((gpus > 0)) || warn "no NVIDIA GPUs visible on PCIe"
  ((free >= 60)) || warn "less than 60G free on / - venvs + CUDA need ~40G"
  id "$SETUP_USER" >/dev/null 2>&1 || die "SETUP_USER '$SETUP_USER' does not exist"
}

base_packages() {
  # NVIDIA recommends removing unattended-upgrades on DGX: it silently bumps
  # driver userspace and breaks the driver <-> fabric-manager version lock.
  "${APT[@]}" purge unattended-upgrades || true
  apt_update
  apt_install_avail \
    build-essential cmake ninja-build pkg-config ccache gdb git git-lfs \
    curl wget ca-certificates gnupg jq yq software-properties-common \
    htop btop nvtop tmux screen vim neovim ncdu tree unzip zip zstd pigz pv aria2 rsync \
    numactl hwloc libnuma-dev pciutils lshw dmidecode ipmitool lm-sensors \
    iperf3 ethtool net-tools dnsutils iproute2 lsof strace sysstat iotop fio \
    nvme-cli mdadm xfsprogs smartmontools rasdaemon chrony nfs-common \
    python3-dev python3-venv python3-pip pipx \
    linux-tools-common linux-tools-generic "linux-tools-$(uname -r)" "linux-headers-$(uname -r)" \
    libelf-dev libssl-dev dkms
  git lfs install --system >/dev/null 2>&1 || true
  systemctl enable --now chrony rasdaemon sysstat 2>/dev/null || true
}

repos() {
  # NVIDIA's DGX repo bundle = DGX BaseOS + CUDA + DOCA repos + apt pins.
  # Use it on DGX OS (already present) or on a box with no NVIDIA driver yet.
  # If a non-DGX driver is already installed (e.g. cloud image), don't swap
  # repos under it - just make sure the CUDA repo exists.
  if [[ -f /etc/apt/sources.list.d/dgx.sources ]] || grep -rqs repo.download.nvidia.com/baseos /etc/apt/sources.list.d/; then
    log "DGX repo already configured"
  elif ! gpu_ok; then
    log "adding NVIDIA DGX repo bundle"
    local ex=(--exclude='./etc/apt/sources.list.d/ai-workbench-desktop.sources')
    cuda_src_present && ex+=(--exclude='./etc/apt/sources.list.d/cuda-compute-repo.sources')
    curl -fsSL https://repo.download.nvidia.com/baseos/ubuntu/noble/x86_64/dgx-repo-files.tgz \
      | tar xzf - -C / "${ex[@]}"
  else
    log "driver $(drv_ver) already installed from a non-DGX source; keeping its repos"
  fi
  if ! cuda_src_present; then
    log "adding CUDA repo"
    local d; d=$(mktemp -d)
    curl -fsSL -o "$d/k.deb" https://developer.download.nvidia.com/compute/cuda/repos/ubuntu2404/x86_64/cuda-keyring_1.1-1_all.deb
    dpkg -i "$d/k.deb"; rm -rf "$d"
  fi
  apt_update
}

driver() {
  local v major
  if gpu_ok && v=$(drv_ver) && major=${v%%.*} && ((major >= 580)); then
    log "keeping working driver $v (B300 needs >= R580 open modules)"
    # branch pin: without it apt resolves fabricmanager/nscq/nvsdm to the newest branch
    has_candidate "nvidia-driver-pinning-$major" && apt_install "nvidia-driver-pinning-$major"
    # Fabric Manager + NVLSM are mandatory on B300 (NVSwitch / NVLink5). They
    # must match the driver version exactly.
    if ! installed nvidia-fabricmanager && ! installed "nvidia-fabricmanager-$major"; then
      local sfx fv nv done=0
      for sfx in "" "-$major"; do
        fv=$(pkg_ver "nvidia-fabricmanager$sfx" "$v"); [[ -n $fv ]] || continue
        nv=$(pkg_ver "libnvidia-nscq$sfx" "$v")
        apt_install "nvidia-fabricmanager$sfx=$fv" ${nv:+"libnvidia-nscq$sfx=$nv"}
        done=1; break
      done
      ((done)) || die "no nvidia-fabricmanager package matching driver $v in any repo"
    fi
    apt_install_avail nvlsm
    if ! installed libnvsdm; then
      local sv; sv=$(pkg_ver libnvsdm "$v"); [[ -n $sv ]] && apt_install "libnvsdm=$sv"
    fi
  else
    [[ -n ${v:-} ]] && warn "driver ${v} is too old for B300; installing R580"
    log "installing R580 open driver + NVLink5 stack"
    has_candidate nvidia-driver-pinning-580 && apt_install nvidia-driver-pinning-580
    if has_candidate nvidia-driver-580-open; then
      apt_install nvidia-driver-580-open libnvidia-nscq nvidia-modprobe nvidia-fabricmanager
    else   # CUDA-repo naming
      apt_install nvidia-open nvidia-fabricmanager libnvidia-nscq
    fi
    apt_install_avail nv-persistence-mode nvlsm libnvsdm
    mark_reboot
  fi
  apt_install_avail datacenter-gpu-manager-4-cuda13 nvidia-mig-manager
  # Prevent drift between driver userspace, kmod and fabric manager.
  if ! dpkg -l 'nvidia-driver-pinning-*' 2>/dev/null | q '^ii'; then
    v=${v:-$(dpkg-query -W -f='${Version}' nvidia-fabricmanager 2>/dev/null | cut -d- -f1)}
    [[ -n $v ]] && dpkg-query -W -f='${Package} ${Version}\n' \
      | awk -v v="$v" 'index($2, v) == 1 {print $1}' | xargs -r apt-mark hold
  fi
  for s in nvidia-persistenced nvidia-fabricmanager nvidia-dcgm; do
    systemctl list-unit-files "$s.service" >/dev/null 2>&1 && systemctl enable "$s" 2>/dev/null || true
  done
  # Plain Ubuntu: pull in the same system config packages DGX OS ships with.
  if [[ ! -f /etc/dgx-release ]] && has_candidate nvidia-system-core; then
    apt_install_avail nvidia-system-core nvidia-system-utils nvidia-peermem-loader nvidia-grub-params nvdebug
  fi
}

upgrade() {
  flag FULL_UPGRADE || { log "FULL_UPGRADE=0, skipping"; return 0; }
  "${APT[@]}" full-upgrade
  "${APT[@]}" autoremove --purge
  [[ -f /var/run/reboot-required ]] && mark_reboot || true
}

doca() {
  flag INSTALL_DOCA || { log "INSTALL_DOCA=0, skipping"; return 0; }
  if ! lspci -d 15b3: | q -i 'ethernet\|infiniband'; then log "no ConnectX NICs, skipping"; return 0; fi
  if have ofed_info && ofed_info -s >/dev/null 2>&1; then
    log "DOCA/OFED present: $(ofed_info -s)"
  elif has_candidate nvidia-system-mlnx-drivers; then
    apt_install nvidia-system-mlnx-drivers
    mark_reboot
  else
    if ! has_candidate doca-ofed; then
      curl -fsSL https://linux.mellanox.com/public/repo/doca/GPG-KEY-Mellanox.pub \
        | gpg --dearmor --yes -o /usr/share/keyrings/GPG-KEY-Mellanox.gpg
      echo "deb [signed-by=/usr/share/keyrings/GPG-KEY-Mellanox.gpg] https://linux.mellanox.com/public/repo/doca/latest/ubuntu24.04/x86_64/ ./" \
        > /etc/apt/sources.list.d/doca.list
      apt_update
    fi
    apt_install doca-ofed
    mark_reboot
  fi
  apt_install_avail infiniband-diags rdma-core ibverbs-utils perftest mstflint
  # nvidia-peermem = GPUDirect RDMA; ib_umad is used by NVLSM on B300.
  printf '%s\n' nvidia-peermem ib_umad > /etc/modules-load.d/b300-rdma.conf
  modprobe ib_umad 2>/dev/null || true
  modprobe nvidia-peermem 2>/dev/null || true
}

docker_stack() {
  flag INSTALL_DOCKER || { log "INSTALL_DOCKER=0, skipping"; return 0; }
  if have snap && snap list docker >/dev/null 2>&1; then snap remove --purge docker; fi
  if ! installed docker-ce; then
    "${APT[@]}" remove docker.io docker-doc docker-compose podman-docker containerd runc 2>/dev/null || true
    if ! has_candidate docker-ce; then
      install -m 0755 -d /etc/apt/keyrings
      curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
      echo "deb [arch=amd64 signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu noble stable" \
        > /etc/apt/sources.list.d/docker.list
      apt_update
    fi
    apt_install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
  fi
  if ! has_candidate nvidia-container-toolkit; then
    curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey \
      | gpg --dearmor --yes -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg
    curl -fsSL https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list \
      | sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' \
      > /etc/apt/sources.list.d/nvidia-container-toolkit.list
    apt_update
  fi
  apt_install nvidia-container-toolkit
  apt_install_avail nv-docker-options
  nvidia-ctk runtime configure --runtime=docker --set-as-default
  # big ulimits for NCCL/pinned memory inside containers; data on /raid if present
  local f=/etc/docker/daemon.json patch
  [[ -s $f ]] || echo '{}' > $f
  patch='.["default-ulimits"] = {"memlock":{"Name":"memlock","Hard":-1,"Soft":-1},"nofile":{"Name":"nofile","Hard":1048576,"Soft":1048576},"stack":{"Name":"stack","Hard":67108864,"Soft":67108864}}
         | .["log-driver"] = "json-file" | .["log-opts"] = {"max-size":"100m","max-file":"3"}'
  if mountpoint -q /raid && [[ -z $(ls -A /var/lib/docker/containers 2>/dev/null) ]]; then
    mkdir -p /raid/docker; patch+=' | .["data-root"] = "/raid/docker"'
  fi
  jq "$patch" $f > $f.tmp && mv $f.tmp $f
  systemctl enable docker >/dev/null 2>&1
  systemctl restart docker
  usermod -aG docker "$SETUP_USER" || true
}

cuda() {
  local v major tk=cuda-toolkit-13
  v=$(drv_ver || true); major=${v%%.*}
  [[ ${major:-580} == 580 ]] && tk=cuda-toolkit-13-0   # match R580 exactly
  apt_install "$tk"     # includes nvcc, cuBLAS, nsight-systems/compute
  apt_install_avail cudnn9-cuda-13
  local nv=""          # NCCL built for the same CUDA minor as the toolkit
  [[ $tk == cuda-toolkit-13-0 ]] && nv=$(apt-cache madison libnccl2 | awk -F'|' '$2 ~ /cuda13\.0/ {gsub(/ /,"",$2); print $2; exit}')
  if [[ -n $nv ]]; then apt_install "libnccl2=$nv" "libnccl-dev=$nv"; apt-mark hold libnccl2 libnccl-dev
  else apt_install_avail libnccl2 libnccl-dev; fi
  flag INSTALL_GDS && apt_install_avail nvidia-gds
  cat > /etc/profile.d/cuda.sh <<'EOF'
export CUDA_HOME=/usr/local/cuda
case ":$PATH:" in *":/usr/local/cuda/bin:"*) ;; *) export PATH="/usr/local/cuda/bin:$PATH" ;; esac
EOF
  /usr/local/cuda/bin/nvcc --version | tail -2
}

raid() {
  mountpoint -q /raid && { log "/raid already mounted"; return 0; }
  flag CONFIGURE_RAID || { log "CONFIGURE_RAID=0, /raid not mounted - leaving disks alone"; return 0; }
  if [[ -x /usr/bin/configure_raid_array.py ]]; then
    /usr/bin/configure_raid_array.py -c -f; return 0
  fi
  local root_disk disks=() d
  root_disk=$(lsblk -no PKNAME "$(findmnt -no SOURCE /)" 2>/dev/null | tail -1)
  for d in $(lsblk -dnpo NAME,TYPE | awk '$2=="disk" && $1 ~ /nvme/ {print $1}'); do
    [[ $(basename "$d") == "$root_disk" ]] && continue
    [[ $(lsblk -no NAME "$d" | wc -l) -gt 1 ]] && continue           # has partitions
    [[ -n $(blkid -p "$d" 2>/dev/null) ]] && continue                 # has a signature
    disks+=("$d")
  done
  ((${#disks[@]})) || { warn "no empty NVMe drives found"; return 0; }
  log "creating RAID0 on: ${disks[*]}"
  mdadm --create /dev/md/raid --run --level=0 --raid-devices=${#disks[@]} "${disks[@]}"
  mkfs.xfs -f /dev/md/raid
  mdadm --detail --scan > /etc/mdadm/mdadm.conf
  update-initramfs -u
  mkdir -p /raid
  echo "UUID=$(blkid -s UUID -o value /dev/md/raid) /raid xfs defaults,nofail,noatime 0 0" >> /etc/fstab
  mount /raid; chmod 1777 /raid
}

tuning() {
  # --- sysctl
  cat > /etc/sysctl.d/90-b300.conf <<'EOF'
# GPU hosts: NUMA auto-balancing migrates pinned pages and hurts GPU/RDMA perf
kernel.numa_balancing = 0
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
  sysctl --system >/dev/null || warn "some sysctls were rejected"

  # --- limits (pinned memory for NCCL / RDMA / CUDA host alloc)
  cat > /etc/security/limits.d/90-b300.conf <<'EOF'
*    soft memlock unlimited
*    hard memlock unlimited
*    soft nofile  1048576
*    hard nofile  1048576
*    soft stack   unlimited
root soft memlock unlimited
root hard memlock unlimited
root soft nofile  1048576
root hard nofile  1048576
EOF
  mkdir -p /etc/systemd/system.conf.d /etc/systemd/user.conf.d
  printf '[Manager]\nDefaultLimitMEMLOCK=infinity\nDefaultLimitNOFILE=1048576\n' \
    | tee /etc/systemd/system.conf.d/90-b300.conf > /etc/systemd/user.conf.d/90-b300.conf

  # --- boot-time tuning service
  cat > /usr/local/sbin/b300-tune <<EOF
#!/bin/bash
# applied at every boot by b300-tune.service
for g in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do echo performance > "\$g" 2>/dev/null; done
for e in /sys/devices/system/cpu/cpu*/cpufreq/energy_performance_preference; do echo performance > "\$e" 2>/dev/null; done
echo madvise > /sys/kernel/mm/transparent_hugepage/enabled 2>/dev/null
echo defer+madvise > /sys/kernel/mm/transparent_hugepage/defrag 2>/dev/null
command -v nvidia-smi >/dev/null && nvidia-smi -pm 1 >/dev/null 2>&1
# PCIe ACS forces P2P/GPUDirect traffic through the root complex; NCCL docs
# recommend disabling it on bare metal. Never in VMs.
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
  systemctl enable --now b300-tune.service

  # --- kernel cmdline: IOMMU passthrough (bare metal) keeps DMA fast for GPUDirect
  if [[ $(systemd-detect-virt || true) == none ]] && ! grep -qw 'iommu=pt' /proc/cmdline \
     && ! grep -rqs 'iommu=pt' /etc/default/grub /etc/default/grub.d/; then
    echo 'GRUB_CMDLINE_LINUX_DEFAULT="$GRUB_CMDLINE_LINUX_DEFAULT iommu=pt"' > /etc/default/grub.d/99-b300.cfg
    update-grub && mark_reboot
  fi

  # --- env for all users
  local hf=""
  mountpoint -q /raid && { mkdir -p /raid/hf /raid/uv-cache; chmod 1777 /raid/hf /raid/uv-cache; hf=1; }
  cat > /etc/profile.d/b300-env.sh <<EOF
# written by b300-setup
${hf:+export HF_HOME=/raid/hf}
${hf:+export UV_CACHE_DIR=/raid/uv-cache}
export UV_LINK_MODE=copy
alias ml='source /opt/venvs/ml/bin/activate'
alias vl='source /opt/venvs/vllm/bin/activate'
alias sgl='source /opt/venvs/sglang/bin/activate'
alias gpus='nvidia-smi --query-gpu=index,name,temperature.gpu,power.draw,utilization.gpu,memory.used,memory.total --format=csv'
EOF
}

reboot_checkpoint() {
  if [[ ! -f $STATE/.reboot-needed ]] && gpu_ok; then return 0; fi
  local n; n=$(cat "$STATE/.reboots" 2>/dev/null || echo 0)
  if ((n >= 2)); then warn "already rebooted $n times and GPUs still not healthy; continuing anyway"; rm -f "$STATE/.reboot-needed"; return 0; fi
  cat > /etc/systemd/system/$UNIT-resume.service <<EOF
[Unit]
Description=Resume B300 node setup after reboot
Wants=network-online.target
After=network-online.target nvidia-fabricmanager.service

[Service]
Type=exec
Environment=B300_DETACHED=1
ExecStart=/bin/bash $SELF
StandardOutput=append:$LOG
StandardError=append:$LOG
TimeoutStartSec=0

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload; systemctl enable $UNIT-resume.service
  echo $((n + 1)) > "$STATE/.reboots"; rm -f "$STATE/.reboot-needed"
  if flag AUTO_REBOOT; then
    log "${C_Y}REBOOTING in 15s to load new driver/kernel. Setup resumes automatically.${C_0}"
    log "${C_Y}After you reconnect:  b300-setup -f${C_0}"
    sleep 15; systemctl reboot; sleep 600; exit 0
  else
    log "${C_Y}Reboot required (AUTO_REBOOT=0). Run: sudo reboot   - setup resumes on boot.${C_0}"
    exit 0
  fi
}

gpu_health() {
  # wait for fabric manager to finish training NVLink after boot
  local i fm n
  for i in $(seq 1 60); do gpu_ok && break; sleep 5; done
  gpu_ok || { journalctl -u nvidia-fabricmanager -n 40 --no-pager || true; err "nvidia-smi not working"; return 1; }
  n=$(nvidia-smi -L | wc -l)
  for i in $(seq 1 60); do
    fm=$(nvidia-smi -q | grep -A2 -E '^\s+Fabric$' | grep -cE 'State\s+: Completed' || true)
    ((fm >= n)) && break; sleep 5
  done
  nvidia-smi
  if ((fm < n)); then
    warn "NVLink fabric not ready ($fm/$n GPUs Completed). Fabric manager log:"
    journalctl -u nvidia-fabricmanager -n 60 --no-pager || true
    systemctl status nvlsm --no-pager 2>/dev/null || true
    return 1
  fi
  ok "$n GPUs, NVLink fabric Completed on all"
}

nccl_tests() {
  [[ -x /opt/nccl-tests/build/all_reduce_perf ]] && { log "nccl-tests already built"; return 0; }
  rm -rf /opt/nccl-tests
  git clone --depth 1 https://github.com/NVIDIA/nccl-tests.git /opt/nccl-tests
  make -C /opt/nccl-tests -j"$(nproc)" CUDA_HOME=/usr/local/cuda NCCL_HOME=/usr \
    NVCC_GENCODE="-gencode=arch=compute_100,code=sm_100 -gencode=arch=compute_103,code=sm_103 -gencode=arch=compute_103,code=compute_103" >/dev/null
  ln -sf /opt/nccl-tests/build/all_reduce_perf /usr/local/bin/all_reduce_perf
}

python_envs() {
  if ! have uv; then
    curl -LsSf https://astral.sh/uv/install.sh | env UV_INSTALL_DIR=/usr/local/bin UV_NO_MODIFY_PATH=1 sh
  fi
  uv --version
  install -d -o "$SETUP_USER" -g "$(id -gn "$SETUP_USER")" /opt/venvs /opt/venvs/.python
  # python lives under /opt so every user (and root) can run the venvs
  local UVENV=(UV_LINK_MODE=copy UV_PYTHON_PREFERENCE=managed UV_PYTHON_INSTALL_DIR=/opt/venvs/.python)
  mountpoint -q /raid && UVENV+=(UV_CACHE_DIR=/raid/uv-cache)
  mk() { [[ -x /opt/venvs/$1/bin/python ]] || as_user env "${UVENV[@]}" uv venv -q --python 3.12 "/opt/venvs/$1"; }
  pipi() { local v=$1; shift; as_user env "${UVENV[@]}" uv pip install -q --python "/opt/venvs/$v/bin/python" "$@"; }

  # ---- ml: torch (PyPI default wheels are CUDA 13) + training/research stack
  log "ml venv: torch + core libs"
  mk ml
  pipi ml torch torchvision torchaudio \
    transformers accelerate datasets tokenizers safetensors sentencepiece tiktoken \
    "huggingface_hub[hf_xet]" peft trl einops numpy scipy pandas pyarrow polars \
    scikit-learn matplotlib seaborn jupyterlab ipython ipywidgets tqdm rich \
    tensorboard wandb mlflow nvitop gpustat nvidia-ml-py py-spy ninja packaging
  local tv; tv=$(/opt/venvs/ml/bin/python -c 'import torch;print(torch.__version__)')
  echo "torch==$tv" > /tmp/b300-torch-pin.txt; chmod 644 /tmp/b300-torch-pin.txt
  local extra
  for extra in bitsandbytes liger-kernel deepspeed lm-eval torchao "flash-attn-4>=4.0.0b0"; do
    pipi ml -c /tmp/b300-torch-pin.txt "$extra" || warn "ml: optional package '$extra' failed to install"
  done
  for b in nvitop gpustat hf jupyter py-spy; do
    [[ -x /opt/venvs/ml/bin/$b ]] && ln -sf "/opt/venvs/ml/bin/$b" "/usr/local/bin/$b"
  done

  # ---- vllm: own venv so its pinned torch never fights the ml stack
  if flag INSTALL_VLLM; then
    log "vllm venv"
    mk vllm
    pipi vllm vllm "huggingface_hub[hf_xet]" || { warn "vllm install failed"; touch "$STATE/.vllm-failed"; }
  fi
  # ---- sglang
  if flag INSTALL_SGLANG; then
    log "sglang venv"
    mk sglang
    # sglang needs a pre-release flash-attn-4; naming it explicitly lets uv pick it
    pipi sglang sglang "flash-attn-4>=4.0.0b0" "huggingface_hub[hf_xet]" || warn "sglang install failed"
  fi
}

# ------------------------------------------------------------- validation ----
validate() {
  local R=() n busbw tmp
  pass() { R+=("PASS  $*"); ok "$*"; }
  fail() { R+=("FAIL  $*"); err "$*"; }
  skip() { R+=("SKIP  $*"); warn "$*"; }
  tmp=$(mktemp -d); chmod 755 "$tmp"
  [[ -n ${HF_TOKEN:-} ]] && export HF_TOKEN
  mountpoint -q /raid && export HF_HOME=/raid/hf

  # 1. driver / fabric
  if gpu_ok; then
    n=$(nvidia-smi -L | wc -l)
    pass "driver $(drv_ver), $n x $(nvidia-smi --query-gpu=name --format=csv,noheader | head -1), $(nvidia-smi --query-gpu=memory.total --format=csv,noheader | head -1) each"
  else fail "nvidia-smi"; n=0; fi
  local fm; fm=$(nvidia-smi -q 2>/dev/null | grep -A2 -E '^\s+Fabric$' | grep -cE 'State\s+: Completed' || true)
  ((fm >= n && n > 0)) && pass "NVLink fabric Completed on $fm/$n GPUs" || fail "NVLink fabric Completed on $fm/$n GPUs (check: journalctl -u nvidia-fabricmanager)"
  for s in nvidia-fabricmanager nvidia-persistenced nvidia-dcgm b300-tune docker; do
    systemctl list-unit-files "$s.service" >/dev/null 2>&1 || continue
    systemctl is-active -q "$s" && pass "service $s active" || fail "service $s not active"
  done
  local pm; pm=$(nvidia-smi --query-gpu=persistence_mode --format=csv,noheader 2>/dev/null | grep -c Enabled || true)
  ((pm == n)) && pass "persistence mode on all GPUs" || fail "persistence mode $pm/$n"
  echo; nvidia-smi topo -m 2>/dev/null | head -20 || true
  have ofed_info && pass "DOCA/OFED $(ofed_info -s 2>/dev/null)" || skip "DOCA/OFED not installed"
  lsmod | q nvidia_peermem && pass "nvidia_peermem loaded (GPUDirect RDMA)" || skip "nvidia_peermem not loaded"
  [[ $(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null) == performance ]] \
    && pass "CPU governor performance" || skip "CPU governor not settable (BIOS-controlled?)"

  # 2. DCGM quick diag
  if have dcgmi; then
    if timeout 900 dcgmi diag -r 1 > "$tmp/dcgm.txt" 2>&1; then pass "dcgmi diag -r 1"
    else fail "dcgmi diag -r 1 (see below)"; tail -30 "$tmp/dcgm.txt"; fi
  else skip "dcgmi not installed"; fi

  # 3. containers
  if have docker; then
    if timeout 600 docker run --rm --gpus all ubuntu:24.04 nvidia-smi -L > "$tmp/d.txt" 2>&1; then
      pass "docker --gpus all sees $(grep -c '^GPU' "$tmp/d.txt") GPUs"
    else fail "docker GPU container"; tail -5 "$tmp/d.txt"; fi
  fi

  # 4. nccl-tests across all GPUs (NVLink5 + NVSwitch)
  if [[ -x /opt/nccl-tests/build/all_reduce_perf ]] && ((n > 1)); then
    if timeout 900 /opt/nccl-tests/build/all_reduce_perf -b 256M -e 8G -f 2 -g "$n" -c 1 -w 5 -n 20 > "$tmp/nccl.txt" 2>&1; then
      busbw=$(awk '/Avg bus bandwidth/{print $NF}' "$tmp/nccl.txt")
      grep -E '^\s+[0-9]+' "$tmp/nccl.txt" | tail -6
      if grep -q 'Out of bounds values : 0 OK' "$tmp/nccl.txt" || ! grep -q 'Out of bounds' "$tmp/nccl.txt"; then
        pass "nccl all_reduce x$n: avg busbw ${busbw} GB/s, peak $(awk '/^ +[0-9]+/{if($12>m)m=$12}END{print m}' "$tmp/nccl.txt") GB/s"
      else fail "nccl all_reduce data corruption"; fi
    else fail "nccl all_reduce"; tail -20 "$tmp/nccl.txt"; fi
  fi

  # 5. PyTorch: every GPU computes; bf16 matmul throughput; P2P
  if [[ -x /opt/venvs/ml/bin/python ]]; then
    cat > "$tmp/torch_test.py" <<'EOF'
import time, torch
n = torch.cuda.device_count()
print(f"torch {torch.__version__} cuda {torch.version.cuda} archs {torch.cuda.get_arch_list()}")
print(f"capability {torch.cuda.get_device_capability(0)}  devices {n}")
res = []
for d in range(n):
    torch.cuda.set_device(d)
    a = torch.randn(16384, 16384, device=d, dtype=torch.bfloat16); b = torch.randn_like(a)
    for _ in range(3): a @ b
    torch.cuda.synchronize(); t = time.perf_counter(); it = 20
    for _ in range(it): a @ b
    torch.cuda.synchronize(); dt = time.perf_counter() - t
    res.append(2 * 16384**3 * it / dt / 1e12)
print("bf16 matmul TFLOPS per GPU:", " ".join(f"{x:.0f}" for x in res))
p2p = all(torch.cuda.can_device_access_peer(i, j) for i in range(n) for j in range(n) if i != j)
print("P2P all pairs:", p2p)
x = torch.ones(1 << 28, device=0); y = x.to(n - 1); torch.cuda.synchronize()
t = time.perf_counter()
for _ in range(10): y.copy_(x)
torch.cuda.synchronize(); print(f"GPU0->GPU{n-1} copy: {10 * x.numel() * 4 / (time.perf_counter() - t) / 1e9:.0f} GB/s")
assert min(res) > 0.5 * max(res), "one GPU is much slower than the others"
assert p2p
print("TORCH_OK", f"{min(res):.0f}")
EOF
    if as_user /opt/venvs/ml/bin/python "$tmp/torch_test.py" 2>&1 | tee "$tmp/torch.txt" | q TORCH_OK; then
      pass "pytorch $(awk '/^torch /{print $2}' "$tmp/torch.txt") on all GPUs, P2P ok, min bf16 $(awk '/TORCH_OK/{print $2}' "$tmp/torch.txt") TFLOPS"
    else fail "pytorch GPU test"; fi

    # torch.distributed NCCL across all GPUs
    cat > "$tmp/dist_test.py" <<'EOF'
import os, time, torch, torch.distributed as dist
dist.init_process_group("nccl"); r = dist.get_rank(); w = dist.get_world_size()
torch.cuda.set_device(int(os.environ["LOCAL_RANK"]))
x = torch.ones(1 << 28, device="cuda", dtype=torch.bfloat16)
for _ in range(5): dist.all_reduce(x)
torch.cuda.synchronize(); t = time.perf_counter()
for _ in range(20): dist.all_reduce(x)
torch.cuda.synchronize(); dt = (time.perf_counter() - t) / 20
if r == 0: print(f"DIST_OK busbw {x.numel()*2*2*(w-1)/w/dt/1e9:.0f}")
dist.destroy_process_group()
EOF
    if ((n > 1)) && as_user timeout 600 /opt/venvs/ml/bin/torchrun --standalone --nproc_per_node="$n" "$tmp/dist_test.py" 2>&1 | tee "$tmp/dist.txt" | q DIST_OK; then
      pass "torch.distributed all_reduce x$n: $(awk '/DIST_OK/{print $3}' "$tmp/dist.txt") GB/s busbw"
    elif ((n > 1)); then fail "torch.distributed NCCL"; tail -15 "$tmp/dist.txt"; fi

    # transformers generate with the small model
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
print("HF_OUT:", tok.decode(out[0][enc["input_ids"].shape[-1]:], skip_special_tokens=True).strip().replace("\n", " ")[:300])
EOF
    if as_user env ${HF_HOME:+HF_HOME=$HF_HOME} ${HF_TOKEN:+HF_TOKEN=$HF_TOKEN} timeout 900 \
        /opt/venvs/ml/bin/python "$tmp/hf_test.py" > "$tmp/hf.txt" 2>&1 && grep -q HF_OUT "$tmp/hf.txt"; then
      grep HF_OUT "$tmp/hf.txt"; pass "transformers generate ($TEST_MODEL)"
    else fail "transformers generate ($TEST_MODEL)"; tail -15 "$tmp/hf.txt"; fi
  else skip "ml venv missing"; fi

  # 6. vLLM inference + throughput with the small model
  if [[ -x /opt/venvs/vllm/bin/python ]] && /opt/venvs/vllm/bin/python -c 'import vllm' 2>/dev/null; then
    cat > "$tmp/vllm_test.py" <<EOF
import time
from vllm import LLM, SamplingParams
llm = LLM(model="${TEST_MODEL}", gpu_memory_utilization=0.30, max_model_len=4096)
sp = SamplingParams(temperature=0.0, max_tokens=64)
o = llm.chat([{"role": "user", "content": "Say hello from a B300 in five words."}], sp)
print("VLLM_OUT:", o[0].outputs[0].text.strip().replace("\n", " ")[:300])
prompts = [f"Write a short story about GPU number {i}." for i in range(512)]
sp = SamplingParams(temperature=0.8, max_tokens=256, ignore_eos=True)
t = time.perf_counter(); outs = llm.generate(prompts, sp); dt = time.perf_counter() - t
toks = sum(len(x.outputs[0].token_ids) for x in outs)
print(f"VLLM_TPUT {toks/dt:.0f}")
EOF
    if as_user env ${HF_HOME:+HF_HOME=$HF_HOME} ${HF_TOKEN:+HF_TOKEN=$HF_TOKEN} CUDA_VISIBLE_DEVICES=0 timeout 1200 \
        /opt/venvs/vllm/bin/python "$tmp/vllm_test.py" > "$tmp/vllm.txt" 2>&1 && grep -q VLLM_TPUT "$tmp/vllm.txt"; then
      grep VLLM_OUT "$tmp/vllm.txt"
      pass "vLLM $(/opt/venvs/vllm/bin/python -c 'import vllm;print(vllm.__version__)' 2>/dev/null) $TEST_MODEL on 1 GPU: $(awk '/VLLM_TPUT/{print $2}' "$tmp/vllm.txt") output tok/s (512 reqs)"
    else fail "vLLM smoke test"; tail -25 "$tmp/vllm.txt"; fi
  elif flag INSTALL_VLLM; then fail "vllm venv not importable"; fi

  if [[ -x /opt/venvs/sglang/bin/python ]]; then
    /opt/venvs/sglang/bin/python -c 'import sglang;print(sglang.__version__)' > "$tmp/sgl.txt" 2>&1 \
      && pass "sglang $(cat "$tmp/sgl.txt") importable" || fail "sglang import"
  fi

  # ---- report
  {
    echo "================ B300 setup report  $(date -Is)  $(hostname) ================"
    printf '%s\n' "${R[@]}"
    ((${#FAILED[@]})) && echo "steps that failed during install: ${FAILED[*]}"
    echo
    echo "venvs:   source /opt/venvs/ml/bin/activate   (aliases: ml, vl, sgl - new shell)"
    echo "         /opt/venvs/vllm   /opt/venvs/sglang"
    echo "tools:   nvitop  gpus  all_reduce_perf  dcgmi  nvidia-smi topo -m"
    echo "serve:   /opt/venvs/vllm/bin/vllm serve <model> --tensor-parallel-size 8"
    echo "rerun:   sudo b300-setup --test        log: $LOG"
    echo "NOTE: log out/in once so docker group + ulimits apply to your shell."
  } | tee "$REPORT"
  rm -rf "$tmp"
  ! printf '%s\n' "${R[@]}" | q '^FAIL'
}

# --------------------------------------------------------------------- main --
if [[ "${1:-}" == "-t" || "${1:-}" == "--test" ]]; then set +e; validate; exit $?; fi

log "${C_B}B300 node setup starting${C_0}  (log: $LOG)"
run_step preflight     1 preflight
run_step base_packages 1 base_packages
run_step repos         1 repos
run_step driver        1 driver
run_step upgrade       0 upgrade
run_step doca          0 doca
run_step docker        0 docker_stack
run_step cuda          0 cuda
run_step raid          0 raid
run_step tuning        0 tuning
reboot_checkpoint
gpu_health || warn "GPU health check reported problems - continuing so the report shows details"
run_step nccl_tests    0 nccl_tests
run_step python_envs   0 python_envs

systemctl disable $UNIT-resume.service 2>/dev/null || true
rm -f /etc/systemd/system/$UNIT-resume.service; systemctl daemon-reload

echo; log "${C_B}==== validation ====${C_0}"
if validate; then ok "${C_G}${C_B}B300 node is ready.${C_0}"; else warn "setup finished with failures - see $REPORT"; fi
