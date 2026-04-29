#!/bin/bash

VERSION="3.0.0-codex-core"
MARKER="modbyshowtempfreq"

setup_colors() {
    if [[ -t 1 && -z "${NO_COLOR}" ]]; then
        RED=$(printf '\033[0;31m')
        GREEN=$(printf '\033[0;32m')
        YELLOW=$(printf '\033[1;33m')
        BLUE=$(printf '\033[0;34m')
        CYAN=$(printf '\033[0;36m')
        MAGENTA=$(printf '\033[0;35m')
        NC=$(printf '\033[0m')
    else
        RED='' ; GREEN='' ; YELLOW='' ; BLUE='' ; CYAN='' ; MAGENTA='' ; NC=''
    fi
    UI_BORDER="${CYAN}============================================================${NC}"
}
setup_colors

log_info()    { printf "%b[%s]%b %bINFO%b  %s\n"  "$GREEN" "$(date +'%H:%M:%S')" "$NC" "$CYAN" "$NC" "$1"; }
log_warn()    { printf "%b[%s]%b %bWARN%b  %s\n"  "$YELLOW" "$(date +'%H:%M:%S')" "$NC" "$YELLOW" "$NC" "$1"; }
log_error()   { printf "%b[%s]%b %bERROR%b %s\n" "$RED" "$(date +'%H:%M:%S')" "$NC" "$RED" "$NC" "$1" >&2; }
log_step()    { printf "%b[%s]%b %bSTEP%b  %s\n"  "$BLUE" "$(date +'%H:%M:%S')" "$NC" "$MAGENTA" "$NC" "$1"; }
log_success() { printf "%b[%s]%b %bOK%b    %s\n"  "$GREEN" "$(date +'%H:%M:%S')" "$NC" "$GREEN" "$NC" "$1"; }

pause() {
    read -r -n 1 -p " Press any key to continue... " _
    echo
}

backup_file() {
    local file="$1"
    local backup_dir="/var/backups/pve-k"
    mkdir -p "$backup_dir"
    [[ -f "$file" ]] || return 0
    cp "$file" "${backup_dir}/$(basename "$file").$(date +%Y%m%d%H%M%S).bak"
}

get_debian_ver() {
    local major
    major=$(awk -F. '{print $1}' /etc/debian_version 2>/dev/null)
    case "$major" in
        13|trixie*) echo "trixie" ;;
        12|bookworm*) echo "bookworm" ;;
        11|bullseye*) echo "bullseye" ;;
        10|buster*) echo "buster" ;;
        *) echo "" ;;
    esac
}

backup_pve_ui_files() {
    local pvever
    pvever=$(pveversion | awk -F/ '{print $2}')
    cp /usr/share/perl5/PVE/API2/Nodes.pm "/usr/share/perl5/PVE/API2/Nodes.pm.${pvever}.bak"
    cp /usr/share/pve-manager/js/pvemanagerlib.js "/usr/share/pve-manager/js/pvemanagerlib.js.${pvever}.bak"
    cp /usr/share/javascript/proxmox-widget-toolkit/proxmoxlib.js "/usr/share/javascript/proxmox-widget-toolkit/proxmoxlib.js.${pvever}.bak"
}

remove_subscription_popup() {
    local proxmoxlib="/usr/share/javascript/proxmox-widget-toolkit/proxmoxlib.js"
    [[ -f "$proxmoxlib" ]] || return 0
    if grep -q "$MARKER-popup" "$proxmoxlib"; then
        return 0
    fi
    backup_file "$proxmoxlib"
    cp "$proxmoxlib" "${proxmoxlib}.bak.pre-codex"
    perl -0pi -e "s/if\\s*\\((?:res\\s*===\\s*null\\s*\\|\\|\\s*)?(?:res\\s*===\\s*undefined\\s*\\|\\|\\s*)?(?:!res\\s*\\|\\|\\s*)?res\\.data\\.status\\.toLowerCase\\(\\)\\s*!==\\s*'active'\\)\\s*\\{/if (false) { \\/\\/ ${MARKER}-popup /s" "$proxmoxlib" 2>/dev/null || true
}

pve_optimization() {
    local sver aptsource mirror host proxmox_mirror
    sver=$(get_debian_ver)
    if [[ -z "$sver" ]]; then
        log_error "Unsupported Debian version"
        return 1
    fi

    mkdir -p /etc/apt/backup
    echo "$UI_BORDER"
    echo "  1. Tsinghua Tuna"
    echo "  2. USTC"
    echo "$UI_BORDER"
    read -r -p " Choose apt mirror [default 1]: " aptsource
    aptsource=${aptsource:-1}

    case "$aptsource" in
        2)
            host="https://mirrors.ustc.edu.cn"
            proxmox_mirror="https://mirrors.ustc.edu.cn/proxmox"
            ;;
        *)
            host="https://mirrors.tuna.tsinghua.edu.cn"
            proxmox_mirror="https://mirrors.tuna.tsinghua.edu.cn/proxmox"
            ;;
    esac

    log_step "Backup apt files"
    [[ -f /etc/apt/sources.list ]] && cp -f /etc/apt/sources.list /etc/apt/backup/sources.list.bak
    [[ -f /etc/apt/sources.list.d/debian.sources ]] && mv /etc/apt/sources.list.d/debian.sources /etc/apt/backup/debian.sources.bak
    [[ -f /etc/apt/sources.list.d/ceph.sources ]] && mv /etc/apt/sources.list.d/ceph.sources /etc/apt/backup/ceph.sources.bak
    [[ -f /etc/apt/sources.list.d/ceph.list ]] && mv /etc/apt/sources.list.d/ceph.list /etc/apt/backup/ceph.list.bak
    [[ -f /etc/apt/sources.list.d/pve-enterprise.sources ]] && mv /etc/apt/sources.list.d/pve-enterprise.sources /etc/apt/backup/pve-enterprise.sources.bak
    [[ -f /etc/apt/sources.list.d/pve-enterprise.list ]] && mv /etc/apt/sources.list.d/pve-enterprise.list /etc/apt/backup/pve-enterprise.list.bak

    log_step "Write Debian sources"
    cat > /etc/apt/sources.list <<EOF
deb ${host}/debian/ ${sver} main contrib non-free non-free-firmware
deb ${host}/debian/ ${sver}-updates main contrib non-free non-free-firmware
deb ${host}/debian/ ${sver}-backports main contrib non-free non-free-firmware
deb ${host}/debian-security ${sver}-security main contrib non-free non-free-firmware
EOF

    mkdir -p /etc/apt/sources.list.d
    cat > /etc/apt/sources.list.d/pve-no-subscription.list <<EOF
deb ${proxmox_mirror}/debian ${sver} pve-no-subscription
EOF
    log_success "Apt sources updated"

    log_step "Switch CT template mirror"
    if [[ -f /usr/share/perl5/PVE/APLInfo.pm ]]; then
        cp -f /usr/share/perl5/PVE/APLInfo.pm /etc/apt/backup/APLInfo.pm.bak
        sed -i 's|http://download.proxmox.com|'"${proxmox_mirror}"'|g' /usr/share/perl5/PVE/APLInfo.pm
        pveam update
        log_success "CT template mirror updated"
    else
        log_warn "APLInfo.pm not found, skipped"
    fi

    log_step "Download Proxmox release key"
    if ! wget -q --timeout=10 --tries=2 "${proxmox_mirror}/debian/proxmox-release-${sver}.gpg" -O "/etc/apt/trusted.gpg.d/proxmox-release-${sver}.gpg"; then
        if ! wget -q --timeout=10 --tries=2 "https://raw.githubusercontent.com/xiangfeidexiaohuo/pve-diy/master/gpg/proxmox-release-${sver}.gpg" -O "/etc/apt/trusted.gpg.d/proxmox-release-${sver}.gpg"; then
            log_warn "Release key download failed"
        fi
    fi

    log_step "Disable subscription popup"
    remove_subscription_popup

    log_step "Restart pveproxy"
    systemctl daemon-reload
    systemctl restart pveproxy.service
    log_success "Optimization finished"
    log_info "Recommended next steps:"
    log_info "  apt-get update -y"
    log_info "  apt-get dist-upgrade -y"
}

ensure_monitor_packages() {
    local packages=(
        lm-sensors
        nvme-cli
        sysstat
        linux-cpupower
        hdparm
        smartmontools
    )
    local missing=()
    local pkg
    for pkg in "${packages[@]}"; do
        dpkg -s "$pkg" >/dev/null 2>&1 || missing+=("$pkg")
    done
    if [[ ${#missing[@]} -gt 0 ]]; then
        log_step "Install monitor packages"
        apt-get update
        apt-get install -y "${missing[@]}"
    fi

    [[ -x /usr/sbin/nvme ]] && chmod +s /usr/sbin/nvme
    [[ -x /usr/sbin/smartctl ]] && chmod +s /usr/sbin/smartctl
    [[ -x /usr/sbin/linux-cpupower ]] && chmod +s /usr/sbin/linux-cpupower
    [[ -x /usr/sbin/turbostat ]] && chmod +s /usr/sbin/turbostat || true
    modprobe msr 2>/dev/null || true
    echo msr > /etc/modules-load.d/turbostat-msr.conf
}

cpu_add() {
    local nodes="/usr/share/perl5/PVE/API2/Nodes.pm"
    local pvemanager="/usr/share/pve-manager/js/pvemanagerlib.js"
    local proxmoxlib="/usr/share/javascript/proxmox-widget-toolkit/proxmoxlib.js"
    local pvever tmpf ln

    [[ -f "$nodes" && -f "$pvemanager" && -f "$proxmoxlib" ]] || {
        log_error "Required PVE files not found"
        return 1
    }

    if grep -q "$MARKER" "$nodes" "$pvemanager" "$proxmoxlib" 2>/dev/null; then
        log_warn "Monitoring patch already exists"
        return 0
    fi

    ensure_monitor_packages
    backup_file "$nodes"
    backup_file "$pvemanager"
    backup_file "$proxmoxlib"
    backup_pve_ui_files

    log_step "Patch Nodes.pm"
    tmpf=$(mktemp /tmp/pve-k-nodes.XXXXXX)
    cat > "$tmpf" <<'EOF'
#modbyshowtempfreq
        $res->{codex_cpu_block} = `bash -lc '
gov=$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null || echo unknown)
avg=$(awk -F": " "/cpu MHz/ {sum+=\\$2; n++} END {if (n) printf \"%.0f\", sum/n; else print \"n/a\"}" /proc/cpuinfo 2>/dev/null)
min=$(lscpu 2>/dev/null | awk -F: "/CPU min MHz/ {gsub(/ /, \"\", \\$2); if (\\$2 != \"\") printf \"%.0f\", \\$2}")
max=$(lscpu 2>/dev/null | awk -F: "/CPU max MHz/ {gsub(/ /, \"\", \\$2); if (\\$2 != \"\") printf \"%.0f\", \\$2}")
power=$(turbostat -S -q -s PkgWatt -i 0.1 -n 1 -c package 2>/dev/null | awk "NF && \\$1 !~ /PkgWatt/ {print \\$1; exit}")
echo "Governor: ${gov}"
echo "Average MHz: ${avg:-n/a}  Min: ${min:-n/a}  Max: ${max:-n/a}"
if [[ -n "$power" ]]; then echo "Package Power: ${power} W"; fi
sensors -A 2>/dev/null | awk "/Package id|Physical id|Tdie|Tctl|Core [0-9]+|Composite|junction|edge/ {print}" | head -n 12
' 2>/dev/null`;
        $res->{codex_disk_block} = `bash -lc '
for dev in /dev/sd? /dev/nvme?n1 /dev/nvme?; do
    [[ -b "$dev" ]] || continue
    model=$(smartctl -i "$dev" 2>/dev/null | awk -F": +" "/Device Model|Model Number|Product/ {print \\$2; exit}")
    size=$(lsblk -dn -o SIZE "$dev" 2>/dev/null | head -1)
    temp=$(smartctl -A "$dev" 2>/dev/null | awk "
        /Temperature_Celsius|Current Drive Temperature|Composite Temperature|Temperature:/ {
            for (i = NF; i >= 1; i--) if (\\$i ~ /^[0-9]+$/) { print \\$i \" C\"; exit }
        }")
    hours=$(smartctl -A "$dev" 2>/dev/null | awk "
        /Power_On_Hours/ {print \\$(NF-1); exit}
        /Power on Hours/ {print \\$NF; exit}")
    printf "%s | %s | %s | temp:%s | hours:%s\n" "$dev" "${model:-unknown}" "${size:-?}" "${temp:-n/a}" "${hours:-n/a}"
done
' 2>/dev/null`;
EOF
    ln=$(sed -n -e '/PVE::pvecfg::version_text/=' "$nodes" | head -1)
    if [[ -z "$ln" ]]; then
        rm -f "$tmpf"
        log_error "Failed to find version_text hook in Nodes.pm"
        return 1
    fi
    ln=$((ln + 1))
    sed -i "${ln}r $tmpf" "$nodes"
    rm -f "$tmpf"

    log_step "Patch pvemanagerlib.js"
    tmpf=$(mktemp /tmp/pve-k-js.XXXXXX)
    cat > "$tmpf" <<'EOF'
//modbyshowtempfreq
    {
        itemId: 'codexCpuInfo',
        colspan: 2,
        printBar: false,
        title: gettext('CPU Details'),
        textField: 'codex_cpu_block',
        renderer: function(value) {
            if (!value || value.trim() === '') {
                return 'No CPU data';
            }
            return Ext.String.htmlEncode(value).replace(/\n/g, '<br>');
        },
    },
    {
        itemId: 'codexDiskInfo',
        colspan: 2,
        printBar: false,
        title: gettext('Disk Details'),
        textField: 'codex_disk_block',
        renderer: function(value) {
            if (!value || value.trim() === '') {
                return 'No disk data';
            }
            return Ext.String.htmlEncode(value).replace(/\n/g, '<br>');
        },
    },
EOF
    ln=$(sed -n '/pveversion/,+10{/},/{=;q}}' "$pvemanager" | head -1)
    if [[ -z "$ln" ]]; then
        rm -f "$tmpf"
        log_error "Failed to find pveversion block in pvemanagerlib.js"
        return 1
    fi
    sed -i "${ln}r $tmpf" "$pvemanager"
    rm -f "$tmpf"

    log_step "Increase node status panel height"
    sed -i -r '/widget\.pveNodeStatus/,+8{/height/{s#[0-9]+#760#}}' "$pvemanager"
    sed -i -r '/widget\.pveCpuStatus/,+8{/height/{s#[0-9]+#520#}}' "$pvemanager"

    log_step "Refresh subscription popup patch"
    remove_subscription_popup

    systemctl restart pveproxy.service
    log_success "CPU and disk details patch applied"
    log_info "Refresh the browser with Ctrl+F5 or Shift+F5"
}

cpu_del() {
    local nodes="/usr/share/perl5/PVE/API2/Nodes.pm"
    local pvemanager="/usr/share/pve-manager/js/pvemanagerlib.js"
    local proxmoxlib="/usr/share/javascript/proxmox-widget-toolkit/proxmoxlib.js"
    local pvever

    pvever=$(pveversion | awk -F/ '{print $2}')
    if [[ -f "${nodes}.${pvever}.bak" && -f "${pvemanager}.${pvever}.bak" && -f "${proxmoxlib}.${pvever}.bak" ]]; then
        cp -f "${nodes}.${pvever}.bak" "$nodes"
        cp -f "${pvemanager}.${pvever}.bak" "$pvemanager"
        cp -f "${proxmoxlib}.${pvever}.bak" "$proxmoxlib"
        systemctl restart pveproxy.service
        log_success "Monitoring patch removed"
        log_info "Refresh the browser with Ctrl+F5 or Shift+F5"
    else
        log_warn "Backup files not found for current PVE version"
    fi
}

menu() {
    while true; do
        clear
        echo "$UI_BORDER"
        echo " PVE-K Codex Core v${VERSION}"
        echo " Focused for source switch, popup removal, CPU/disk details"
        echo "$UI_BORDER"
        echo "  1. Switch mirror + remove popup"
        echo "  2. Add CPU/disk detail patch"
        echo "  3. Remove CPU/disk detail patch"
        echo "  0. Exit"
        echo "$UI_BORDER"
        read -r -p " Choose [0-3]: " choice
        case "$choice" in
            1) pve_optimization ; pause ;;
            2) cpu_add ; pause ;;
            3) cpu_del ; pause ;;
            0) exit 0 ;;
            *) log_warn "Invalid choice" ; pause ;;
        esac
    done
}

if [[ $EUID -ne 0 ]]; then
    log_error "Please run this script as root"
    exit 1
fi

menu
