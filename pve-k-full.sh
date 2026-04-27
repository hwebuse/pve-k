#!/bin/bash
# =============================================================================
# PVE-K 全能优化脚本 v2.0
# 融合: xiangfeidexiaohuo/pve-diy (详细硬件信息)
#       Mapleawaa/PVE-Tools-9 (彩色UI/温度阈值/安全机制)
# 功能: 换源/去弹窗/直通/CPU电源/温度监控/ceph/内核管理
# =============================================================================

VERSION="2.0.0"

# ============ 颜色与 UI 系统 ============
setup_colors() {
    if [[ -t 1 && -z "${NO_COLOR}" ]]; then
        RED=$(printf '\033[0;31m')
        GREEN=$(printf '\033[0;32m')
        YELLOW=$(printf '\033[1;33m')
        BLUE=$(printf '\033[0;34m')
        CYAN=$(printf '\033[0;36m')
        MAGENTA=$(printf '\033[0;35m')
        WHITE=$(printf '\033[1;37m')
        ORANGE=$(printf '\033[0;33m')
        NC=$(printf '\033[0m')
        H1=$(printf '\033[1;36m')
    else
        RED='' ; GREEN='' ; YELLOW='' ; BLUE='' ; CYAN=''
        MAGENTA='' ; WHITE='' ; ORANGE='' ; NC='' ; H1=''
    fi
    UI_BORDER="${NC}═════════════════════════════════════════════════${NC}"
}
setup_colors

log_info()  { local ts=$(date +'%H:%M:%S'); echo -e "${GREEN}[$ts]${NC} ${CYAN}INFO${NC}  $1"; }
log_warn()  { local ts=$(date +'%H:%M:%S'); echo -e "${YELLOW}[$ts]${NC} ${ORANGE}WARN${NC}  $1"; }
log_error() { local ts=$(date +'%H:%M:%S'); echo -e "${RED}[$ts]${NC} ${RED}ERROR${NC} $1" >&2; }
log_step()  { local ts=$(date +'%H:%M:%S'); echo -e "${BLUE}[$ts]${NC} ${MAGENTA}STEP${NC}  $1"; }
log_success(){ local ts=$(date +'%H:%M:%S'); echo -e "${GREEN}[$ts]${NC} ${GREEN}OK${NC}   $1"; }

pause() {
    read -n 1 -p " 按任意键继续... " input
    [[ -n ${input} ]] && echo
}

# ============ 通用工具 ============
backup_file() {
    local file="$1"
    local backup_dir="/var/backups/pve-k"
    mkdir -p "$backup_dir"
    [[ -f "$file" ]] && cp "$file" "${backup_dir}/$(basename $file).$(date +%Y%m%d%H%M%S).bak"
}

get_debian_ver() {
    local sver=$(cat /etc/debian_version | awk -F"." '{print $1}')
    case "$sver" in
        13) echo "trixie" ;;
        12) echo "bookworm" ;;
        11) echo "bullseye" ;;
        10) echo "buster" ;;
        *) echo "" ;;
    esac
}

# ============ 1. 一键优化PVE (换源+去弹窗+密钥) ============
pve_optimization() {
    local sver=$(get_debian_ver)
    if [ -z "$sver" ]; then
        log_error "您的Debian版本不支持！"
        return 1
    fi

    log_step "提示：PVE原配置文件将放入 /etc/apt/backup"
    mkdir -p /etc/apt/backup

    # apt国内源
    log_step "更换 apt 国内源..."
    echo " 1. 清华大学镜像站"
    echo " 2. 中科大镜像站"
    read -t 30 -p " 请选择 [默认1]: " aptsource
    aptsource=${aptsource:-1}
    [[ -e /etc/apt/sources.list ]] && cp -rf /etc/apt/sources.list /etc/apt/backup/sources.list.bak
    [[ -e /etc/apt/sources.list.d/debian.sources ]] && mv /etc/apt/sources.list.d/debian.sources /etc/apt/backup/debian.sources.bak
    case "$aptsource" in
        1)
            cat > /etc/apt/sources.list <<-EOF
deb https://mirrors.tuna.tsinghua.edu.cn/debian/ ${sver} main contrib non-free non-free-firmware
deb https://mirrors.tuna.tsinghua.edu.cn/debian/ ${sver}-updates main contrib non-free non-free-firmware
deb https://mirrors.tuna.tsinghua.edu.cn/debian/ ${sver}-backports main contrib non-free non-free-firmware
deb https://mirrors.tuna.tsinghua.edu.cn/debian-security ${sver}-security main contrib non-free non-free-firmware
EOF
            ;;
        2)
            cat > /etc/apt/sources.list <<-EOF
deb https://mirrors.ustc.edu.cn/debian/ ${sver} main contrib non-free non-free-firmware
deb https://mirrors.ustc.edu.cn/debian/ ${sver}-updates main contrib non-free non-free-firmware
deb https://mirrors.ustc.edu.cn/debian/ ${sver}-backports main contrib non-free non-free-firmware
deb https://mirrors.ustc.edu.cn/debian-security/ ${sver}-security main contrib non-free non-free-firmware
EOF
            ;;
        *) log_warn "无效选项，使用默认清华源" ;;
    esac
    log_success "apt源更换完成"

    # CT模板源
    log_step "更换 CT 模板源..."
    [[ -e /usr/share/perl5/PVE/APLInfo.pm ]] && cp -rf /usr/share/perl5/PVE/APLInfo.pm /etc/apt/backup/APLInfo.pm.bak
    case "$aptsource" in
        1) sed -i 's|http://download.proxmox.com|https://mirrors.tuna.tsinghua.edu.cn/proxmox|g' /usr/share/perl5/PVE/APLInfo.pm ;;
        *) sed -i 's|http://download.proxmox.com|http://mirrors.ustc.edu.cn/proxmox|g' /usr/share/perl5/PVE/APLInfo.pm ;;
    esac
    pveam update
    log_success "CT模板源更换完成"

    # PVE帮助源
    log_step "更换 PVE 使用帮助源..."
    [[ ! -d /etc/apt/sources.list.d ]] && mkdir -p /etc/apt/sources.list.d
    [[ -e /etc/apt/sources.list.d/ceph.sources ]] && mv /etc/apt/sources.list.d/ceph.sources /etc/apt/backup/ceph.sources.bak
    [[ -e /etc/apt/sources.list.d/ceph.list ]] && mv /etc/apt/sources.list.d/ceph.list /etc/apt/backup/ceph.list.bak
    [[ -e /etc/apt/sources.list.d/pve-no-subscription.list ]] && cp -rf /etc/apt/sources.list.d/pve-no-subscription.list /etc/apt/backup/pve-no-subscription.list.bak
    cat > /etc/apt/sources.list.d/pve-no-subscription.list <<-EOF
deb https://mirrors.tuna.tsinghua.edu.cn/proxmox/debian ${sver} pve-no-subscription
EOF
    log_success "使用帮助源更换完成"

    # 关闭企业源
    log_step "关闭企业源..."
    if [[ -e /etc/apt/sources.list.d/pve-enterprise.sources ]]; then
        mv /etc/apt/sources.list.d/pve-enterprise.sources /etc/apt/backup/pve-enterprise.sources.bak
        log_success "企业源 pve-enterprise.sources 已移除"
    fi
    if [[ -e /etc/apt/sources.list.d/pve-enterprise.list ]]; then
        mv /etc/apt/sources.list.d/pve-enterprise.list /etc/apt/backup/pve-enterprise.list.bak
        log_success "企业源 pve-enterprise.list 已移除"
    fi

    # 去除订阅弹窗
    log_step "移除 Proxmox VE 无有效订阅提示..."
    local proxmoxlib="/usr/share/javascript/proxmox-widget-toolkit/proxmoxlib.js"
    cp -rf "$proxmoxlib" "${proxmoxlib}.bak"
    sed -Ezi.bak "s/(Ext.Msg.show\(\{\s+title: gettext\('No valid sub)/void\(\{ \/\/\1/g" "$proxmoxlib"
    log_success "已移除订阅提示"

    # 下载GPG密钥
    log_step "下载 Proxmox VE 源密匙..."
    [[ -e /etc/apt/trusted.gpg.d/proxmox-release-${sver}.gpg ]] && mv /etc/apt/trusted.gpg.d/proxmox-release-${sver}.gpg /etc/apt/backup/proxmox-release-${sver}.gpg.bak
    wget -q --timeout=5 --tries=1 http://mirrors.tuna.tsinghua.edu.cn/proxmox/debian/proxmox-release-${sver}.gpg -O /etc/apt/trusted.gpg.d/proxmox-release-${sver}.gpg
    if [[ $? -ne 0 ]]; then
        wget -q --timeout=5 --tries=1 https://raw.githubusercontent.com/xiangfeidexiaohuo/pve-diy/master/gpg/proxmox-release-${sver}.gpg -O /etc/apt/trusted.gpg.d/proxmox-release-${sver}.gpg
    fi
    log_success "密匙下载完成"

    # 重启服务
    log_step "重新加载服务、重启web控制台..."
    systemctl daemon-reload && systemctl restart pveproxy.service
    log_success "服务重启完成"

    log_info "更新源命令: apt-get update -y"
    log_info "更新软件包: apt-get upgrade -y"
    log_info "更新PVE:    apt-get dist-upgrade -y"
    log_success "一键优化完成！"
}

# ============ 2. 硬件直通 ============
enable_pass() {
    log_step "开启硬件直通..."
    if [ $(dmesg | grep -ce 'DMAR\|IOMMU') = 0 ]; then
        log_error "您的硬件不支持直通！"
        return 1
    fi
    if [ $(grep -c Intel /proc/cpuinfo) = 0 ]; then
        iommu="amd_iommu=on"
    else
        iommu="intel_iommu=on"
    fi
    if [ $(grep -c "$iommu" /etc/default/grub) = 0 ]; then
        sed -i "s|quiet|quiet $iommu|" /etc/default/grub
        update-grub
        if [ $(grep -c "vfio" /etc/modules) = 0 ]; then
            cat <<-EOF >> /etc/modules
vfio
vfio_iommu_type1
vfio_pci
vfio_virqfd
kvmgt
EOF
        fi
        if [ ! -f "/etc/modprobe.d/blacklist.conf" ]; then
            echo "blacklist snd_hda_intel" >> /etc/modprobe.d/blacklist.conf
            echo "blacklist snd_hda_codec_hdmi" >> /etc/modprobe.d/blacklist.conf
            echo "blacklist i915" >> /etc/modprobe.d/blacklist.conf
        fi
        if [ ! -f "/etc/modprobe.d/vfio.conf" ]; then
            echo "options vfio-pci ids=8086:3185" >> /etc/modprobe.d/vfio.conf
        fi
        log_success "开启设置完成，请稍后重启系统。"
    else
        log_warn "您已经配置过硬件直通!"
    fi
}

disable_pass() {
    log_step "关闭硬件直通..."
    if [ $(grep -c Intel /proc/cpuinfo) = 0 ]; then
        iommu="amd_iommu=on"
    else
        iommu="intel_iommu=on"
    fi
    if [ $(grep -c "$iommu" /etc/default/grub) = 0 ]; then
        log_warn "您还没有配置过硬件直通"
    else
        sed -i "s/ $iommu//g" /etc/default/grub
        sed -i '/vfio/d' /etc/modules
        rm -rf /etc/modprobe.d/blacklist.conf /etc/modprobe.d/vfio.conf
        update-grub
        log_success "关闭设置完成，请稍后重启系统。"
    fi
}

hw_passth() {
    while :; do
        clear
        echo -e "${H1}═════════════════════════════════════════════════${NC}"
        echo -e "${H1}         配置硬件直通${NC}"
        echo -e "${UI_BORDER}"
        echo -e "${CYAN}  1. 开启硬件直通${NC}"
        echo -e "${CYAN}  2. 关闭硬件直通${NC}"
        echo -e "${CYAN}  0. 返回主菜单${NC}"
        echo -e "${UI_BORDER}"
        echo -ne " 请选择: [ ]\b\b"
        read -t 60 hwmenuid
        hwmenuid=${hwmenuid:-0}
        case "$hwmenuid" in
            1) enable_pass ; pause ;;
            2) disable_pass ; pause ;;
            0) break ;;
        esac
    done
}

# ============ 3. CPU电源模式 ============
cpupower_menu() {
    governors=$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_available_governors)
    while :; do
        clear
        echo -e "${H1}═════════════════════════════════════════════════${NC}"
        echo -e "${H1}         设置CPU电源模式${NC}"
        echo -e "${UI_BORDER}"
        echo -e "${CYAN}  1. conservative(保守)${NC}"
        echo -e "${CYAN}  2. ondemand(按需)     [默认]${NC}"
        echo -e "${CYAN}  3. powersave(节能)${NC}"
        echo -e "${CYAN}  4. performance(性能)${NC}"
        echo -e "${CYAN}  5. schedutil(负载)${NC}"
        echo -e "${CYAN}  6. 恢复系统默认${NC}"
        echo -e "${CYAN}  0. 返回主菜单${NC}"
        echo -e "${UI_BORDER}"
        echo " 你的CPU支持: ${governors}"
        echo -ne " 请选择: [ ]\b\b"
        read -t 60 cpupowerid
        cpupowerid=${cpupowerid:-2}
        case "$cpupowerid" in
            1) GOVERNOR="conservative" ;;
            2) GOVERNOR="ondemand" ;;
            3) GOVERNOR="powersave" ;;
            4) GOVERNOR="performance" ;;
            5) GOVERNOR="schedutil" ;;
            6) cpupower_del ; pause ; continue ;;
            0) break ;;
            *) log_warn "无效选项"; pause ; continue ;;
        esac
        if [[ -n $(echo "$governors" | grep -o "$GOVERNOR") ]]; then
            log_info "选择CPU模式: $GOVERNOR"
            echo "$GOVERNOR" | tee /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor >/dev/null
            local cmd="sleep 10 && echo '$GOVERNOR' | tee /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor >/dev/null #CPU Power Mode"
            (crontab -l 2>/dev/null | grep -v "CPU Power Mode"; echo "@reboot $cmd") | crontab -
            log_success "已设置并添加开机任务"
        else
            log_warn "您的CPU不支持该模式！"
        fi
        pause
    done
}

cpupower_del() {
    echo "performance" | tee /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor >/dev/null
    crontab -l 2>/dev/null | grep -v "CPU Power Mode" | crontab -
    log_success "已恢复系统默认电源设置"
}

# ============ 4/5. CPU/硬盘温度监控 ============
remove_subscription_popup() {
    local proxmoxlib="/usr/share/javascript/proxmox-widget-toolkit/proxmoxlib.js"
    if [[ -f "$proxmoxlib" ]]; then
        sed -r -i '/\/nodes\/localhost\/subscription/,+30 {
            /^\s+if\s*\(/ {
                :loop
                N
                /\s*\)\s*\{/!b loop
                s/(if\s*\([[:space:]]*res\s*===\s*null\s*(\|\|\s*res\s*===\s*undefined\s*)?(\|\|\s*!res\s*)?(\|\|\s*res\.data\.status\.toLowerCase\(\)\s*!==\s*['\''"]active['\''"]\s*)?[[:space:]]*\)\s*\{)/if(false){/
            }
        }' "$proxmoxlib"
    fi
}

cpu_add() {
    nodes="/usr/share/perl5/PVE/API2/Nodes.pm"
    pvemanagerlib="/usr/share/pve-manager/js/pvemanagerlib.js"
    proxmoxlib="/usr/share/javascript/proxmox-widget-toolkit/proxmoxlib.js"
    pvever=$(pveversion | awk -F"/" '{print $2}')
    log_info "PVE 版本: $pvever"

    if [ $(grep -c 'modbyshowtempfreq' $nodes $pvemanagerlib $proxmoxlib 2>/dev/null) -ge 3 ]; then
        log_warn "已经修改过，请勿重复修改"
        log_warn "如需重新修改，请先执行删除监控"
        pause
        return
    fi

    log_step "更新软件包列表..."
    apt-get update

    log_step "安装所需工具..."
    packages=(lm-sensors nvme-cli sysstat linux-cpupower hdparm smartmontools)
    for package in "${packages[@]}"; do
        if ! dpkg -s "$package" &> /dev/null; then
            log_info "$package 未安装，开始安装"
            apt-get install "${packages[@]}" -y
            modprobe msr
            install=ok
            break
        fi
    done

    [[ -e /usr/sbin/linux-cpupower ]] && chmod +s /usr/sbin/linux-cpupower
    chmod +s /usr/sbin/nvme /usr/sbin/smartctl
    chmod +s /usr/sbin/turbostat 2>/dev/null || log_warn "无法设置 turbostat 权限"
    modprobe msr && echo msr > /etc/modules-load.d/turbostat-msr.conf

    if [ "$install" == "ok" ]; then
        log_success "软件包安装完成，检测硬件信息"
        sensors-detect --auto > /tmp/sensors
        drivers=$(sed -n '/Chip drivers/,/\#----cut here/p' /tmp/sensors | sed '/Chip /d' | sed '/cut/d')
        if [ $(echo $drivers | wc -w) = 0 ]; then
            log_warn "没有找到任何驱动"
            pause
        else
            for i in $drivers; do
                modprobe $i
                if [ $(grep -c $i /etc/modules) = 0 ]; then
                    echo $i >> /etc/modules
                fi
            done
            sensors
            sleep 2
            log_success "驱动信息配置成功"
        fi
        [[ -e /etc/init.d/kmod ]] && /etc/init.d/kmod start
        rm /tmp/sensors
    fi

    log_step "备份源文件"
    backup_file "$nodes"
    backup_file "$pvemanagerlib"
    backup_file "$proxmoxlib"
    rm -f $nodes.*.bak $pvemanagerlib.*.bak $proxmoxlib.*.bak
    cp $nodes $nodes.$pvever.bak
    cp $pvemanagerlib $pvemanagerlib.$pvever.bak
    cp $proxmoxlib $proxmoxlib.$pvever.bak

    # UPS选项
    echo -n "是否启用 UPS 监控？(y/N，默认N): "
    read -n 1 -r
    echo
    local enable_ups=false
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        enable_ups=true
        read -r -p "请输入 NUT UPS 设备名 [默认: ups]: " nut_ups_name
        nut_ups_name=${nut_ups_name:-ups}
        if ! dpkg -s nut-client &> /dev/null; then
            apt-get install nut-client -y
        fi
        log_success "已启用 UPS 监控"
    else
        log_info "已跳过 UPS 监控"
    fi

    # 生成 Nodes.pm 变量
    tmpf=tmpfile.temp
    touch $tmpf
    cat > $tmpf << 'EOF'
#modbyshowtempfreq
        $res->{thermalstate} = `sensors -A`;
        $res->{cpusensors} = `cat /proc/cpuinfo | grep MHz && lscpu | grep MHz`;
        $res->{hdd_temperatures} = `for disk in /dev/sd[a-z]; do smartctl -a \$disk; done | grep -E "Device Model|Capacity|Power_On_Hours|Temperature"`;
        my $powermode = `cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor && turbostat -S -q -s PkgWatt -i 0.1 -n 1 -c package | grep -v PkgWatt`;
        $res->{cpupower} = $powermode;
EOF

    for i in {0..9}; do
        for dev in "/dev/nvme${i}" "/dev/nvme${i}n1"; do
            if [ -b "$dev" ]; then
                log_info "检测到 NVME 磁盘: $dev"
                cat >> $tmpf << EOF
        my \$nvme${i}_temperatures = \`smartctl -a $dev | grep -E "Model Number|(?=Total|Namespace)[^:]+Capacity|Temperature:|Available Spare:|Percentage|Data Unit|Power Cycles|Power On Hours|Unsafe Shutdowns|Integrity Errors"\`;
        my \$nvme${i}_io = \`iostat -d -x -k 1 1 | grep -E "^${dev##*/}"\`;
        \$res->{nvme${i}_status} = \$nvme${i}_temperatures . \$nvme${i}_io;
EOF
                break
            fi
        done
    done

    ln=$(sed -n -e '/PVE::pvecfg::version_text/=' $nodes | head -1)
    ln=$((ln + 1))
    sed -i "${ln}r $tmpf" $nodes
    rm $tmpf

    # 生成 pvemanagerlib.js 渲染器
    tmpf=tmpfile.temp
    touch $tmpf
    cat > $tmpf << 'EOF'
//modbyshowtempfreq
    {
          itemId: 'CPUW', colspan: 2, printBar: false,
          title: gettext('CPU功耗'), textField: 'cpupower',
          renderer:function(value){
              const w0 = value.split('\n')[0].split(' ')[0];
              const w1 = value.split('\n')[1].split(' ')[0];
              return `CPU电源模式: <strong>${w0}</strong> | CPU功耗: <strong>${w1} W</strong>`;
           }
    },
    {
          itemId: 'MHz', colspan: 2, printBar: false,
          title: gettext('CPU频率'), textField: 'cpusensors',
          renderer:function(value){
              const f0 = value.match(/cpu MHz.*?([\d]+)/)[1];
              const f1 = value.match(/CPU min MHz.*?([\d]+)/)[1];
              const f2 = value.match(/CPU max MHz.*?([\d]+)/)[1];
              return `CPU实时: <strong>${f0} MHz</strong> | 最小: ${f1} MHz | 最大: ${f2} MHz`;
           }
    },
    {
          itemId: 'HEXIN', colspan: 2, printBar: false,
          title: gettext('核心频率'), textField: 'cpusensors',
          renderer: function(value) {
              const freqMatches = value.matchAll(/^cpu MHz\s*:\s*([\d\.]+)/gm);
              const frequencies = [];
              for (const match of freqMatches) {
                  frequencies.push(`核心${frequencies.length + 1}: <strong>${parseInt(match[1])} MHz</strong>`);
              }
              if (frequencies.length === 0) return '无法获取CPU频率信息';
              const groupedFreqs = [];
              for (let i = 0; i < frequencies.length; i += 4) {
                  groupedFreqs.push(frequencies.slice(i, i + 4).join(' | '));
              }
              return groupedFreqs.join('<br>');
           }
    },
    {
          itemId: 'thermal', colspan: 2, printBar: false,
          title: gettext('CPU温度'), textField: 'thermalstate',
          renderer: function(value) {
              function colorizeTemp(temp) {
                  let tempNum = Number(temp);
                  if (Number.isNaN(tempNum)) return temp + '°C';
                  if (tempNum < 60) return '<span style="color:#27ae60;font-weight:600;">' + tempNum.toFixed(0) + '°C</span>';
                  if (tempNum < 80) return '<span style="color:#f39c12;font-weight:600;">' + tempNum.toFixed(0) + '°C</span>';
                  return '<span style="color:#e74c3c;font-weight:600;">' + tempNum.toFixed(0) + '°C</span>';
              }
              const coreTemps = [];
              let coreMatch;
              const coreRegex = /(Core\s*\d+|Core\d+|Tdie|Tctl|Physical id\s*\d+).*?\+\s*([\d\.]+)/gi;
              while ((coreMatch = coreRegex.exec(value)) !== null) {
                  let label = coreMatch[1], tempValue = coreMatch[2];
                  if (label.match(/Tdie|Tctl/i)) coreTemps.push(`CPU温度: ${colorizeTemp(tempValue)}`);
                  else {
                      const cn = label.match(/\d+/);
                      coreTemps.push(`核心${cn ? parseInt(cn[0]) + 1 : 1}: ${colorizeTemp(tempValue)}`);
                  }
              }
              let igpuTemp = '';
              const intelIgpuMatch = value.match(/(GFX|Graphics).*?\+\s*([\d\.]+)/i);
              const amdIgpuMatch = value.match(/(junction|edge).*?\+\s*([\d\.]+)/i);
              if (intelIgpuMatch) igpuTemp = `核显: ${colorizeTemp(intelIgpuMatch[2])}`;
              else if (amdIgpuMatch) igpuTemp = `核显: ${colorizeTemp(amdIgpuMatch[2])}`;
              if (coreTemps.length === 0) {
                  const k10tempMatch = value.match(/k10temp-pci-\w+\n[^+]*\+\s*([\d\.]+)/);
                  if (k10tempMatch) coreTemps.push(`CPU温度: ${colorizeTemp(k10tempMatch[1])}`);
              }
              const groupedTemps = [];
              for (let i = 0; i < coreTemps.length; i += 4) {
                  groupedTemps.push(coreTemps.slice(i, i + 4).join(' | '));
              }
              const packageMatch = value.match(/(Package|SoC)\s*(id \d+)?.*?\+\s*([\d\.]+)/i);
              const packageTemp = packageMatch ? `CPU Package: ${colorizeTemp(packageMatch[3])}` : '';
              const boardTempMatch = value.match(/(?:temp1|motherboard|sys).*?\+\s*([\d\.]+)/i);
              const boardTemp = boardTempMatch ? `主板: ${colorizeTemp(boardTempMatch[1])}` : '';
              const combinedTemps = [igpuTemp, packageTemp, boardTemp].filter(Boolean).join(' | ');
              return [groupedTemps.join('<br>'), combinedTemps].filter(Boolean).join('<br>') || '未获取到温度信息';
          }
    },
EOF

    for i in {0..9}; do
        for dev in "/dev/nvme${i}" "/dev/nvme${i}n1"; do
            if [ -b "$dev" ]; then
                cat >> $tmpf << EOF
    {
          itemId: 'nvme${i}-status', colspan: 2, printBar: false,
          title: gettext('NVME盘${i}'), textField: 'nvme${i}_status',
          renderer:function(value){
              function colorizeTemp(temp) {
                  let tempNum = Number(temp);
                  if (Number.isNaN(tempNum)) return temp + '°C';
                  if (tempNum < 50) return '<span style="color:#27ae60;font-weight:600;">' + tempNum + '°C</span>';
                  if (tempNum < 70) return '<span style="color:#f39c12;font-weight:600;">' + tempNum + '°C</span>';
                  return '<span style="color:#e74c3c;font-weight:600;">' + tempNum + '°C</span>';
              }
              function colorizeHealth(percent) {
                  let healthNum = Number(percent);
                  if (Number.isNaN(healthNum)) return percent + '%';
                  if (healthNum >= 80) return '<span style="color:#27ae60;font-weight:600;">' + healthNum + '%</span>';
                  if (healthNum >= 50) return '<span style="color:#f39c12;font-weight:600;">' + healthNum + '%</span>';
                  return '<span style="color:#e74c3c;font-weight:600;">' + healthNum + '%</span>';
              }
              if (value.length > 0) {
                  value = value.replace(/Â/g, '');
                  let data = []; let nvmeNumber = -1;
                  let nvmes = value.matchAll(/(^(?:Model|Total|Temperature:|Available Spare:|Percentage|Data|Power|Unsafe|Integrity Errors|nvme)[\s\S]*)+/gm);
                  for (const nvme of nvmes) {
                      if (/Model Number:/.test(nvme[1])) {
                          nvmeNumber++;
                          data[nvmeNumber] = { Models:[], Integrity_Errors:[], Capacitys:[], Temperatures:[], Available_Spares:[], Useds:[], Reads:[], Writtens:[], Cycles:[], Hours:[], Shutdowns:[], States:[], r_kBs:[], r_awaits:[], w_kBs:[], w_awaits:[], utils:[] };
                      }
                      let Models = nvme[1].matchAll(/^Model Number: *([ \S]*)$/gm);
                      for (const Model of Models) data[nvmeNumber]['Models'].push(Model[1]);
                      let Integrity_Errors = nvme[1].matchAll(/^Media and Data Integrity Errors: *([ \S]*)$/gm);
                      for (const Integrity_Error of Integrity_Errors) data[nvmeNumber]['Integrity_Errors'].push(Integrity_Error[1]);
                      let Capacitys = nvme[1].matchAll(/^(?=Total|Namespace)[^:]+Capacity:[^\[]*\[([ \S]*)\]$/gm);
                      for (const Capacity of Capacitys) data[nvmeNumber]['Capacitys'].push(Capacity[1]);
                      let Temperatures = nvme[1].matchAll(/^Temperature: *([\d]*)[ \S]*$/gm);
                      for (const Temperature of Temperatures) data[nvmeNumber]['Temperatures'].push(Temperature[1]);
                      let Available_Spares = nvme[1].matchAll(/^Available Spare: *([\d]*%)[ \S]*$/gm);
                      for (const Available_Spare of Available_Spares) data[nvmeNumber]['Available_Spares'].push(Available_Spare[1]);
                      let Useds = nvme[1].matchAll(/^Percentage Used: *([ \S]*)%$/gm);
                      for (const Used of Useds) data[nvmeNumber]['Useds'].push(Used[1]);
                      let Reads = nvme[1].matchAll(/^Data Units Read:[^\[]*\[([ \S]*)\]$/gm);
                      for (const Read of Reads) data[nvmeNumber]['Reads'].push(Read[1]);
                      let Writtens = nvme[1].matchAll(/^Data Units Written:[^\[]*\[([ \S]*)\]$/gm);
                      for (const Written of Writtens) data[nvmeNumber]['Writtens'].push(Written[1]);
                      let Cycles = nvme[1].matchAll(/^Power Cycles: *([ \S]*)$/gm);
                      for (const Cycle of Cycles) data[nvmeNumber]['Cycles'].push(Cycle[1]);
                      let Hours = nvme[1].matchAll(/^Power On Hours: *([ \S]*)$/gm);
                      for (const Hour of Hours) data[nvmeNumber]['Hours'].push(Hour[1]);
                      let Shutdowns = nvme[1].matchAll(/^Unsafe Shutdowns: *([ \S]*)$/gm);
                      for (const Shutdown of Shutdowns) data[nvmeNumber]['Shutdowns'].push(Shutdown[1]);
                      let States = nvme[1].matchAll(/^nvme\S+(( *\d+\.\d{2}){22})/gm);
                      for (const State of States) {
                          data[nvmeNumber]['States'].push(State[1]);
                          const IO_array = [...State[1].matchAll(/\d+\.\d{2}/g)];
                          if (IO_array.length > 0) {
                              data[nvmeNumber]['r_kBs'].push(IO_array[1]);
                              data[nvmeNumber]['r_awaits'].push(IO_array[4]);
                              data[nvmeNumber]['w_kBs'].push(IO_array[7]);
                              data[nvmeNumber]['w_awaits'].push(IO_array[10]);
                              data[nvmeNumber]['utils'].push(IO_array[21]);
                          }
                      }
                  }
                  let output = '';
                  for (const [i, nvme] of data.entries()) {
                      if (i > 0) output += '<br><br>';
                      if (nvme.Models.length > 0) {
                          output += \`<strong>\${nvme.Models[0]}</strong>\`;
                          if (nvme.Integrity_Errors.length > 0) {
                              for (const nvmeIntegrity_Error of nvme.Integrity_Errors) {
                                  if (nvmeIntegrity_Error != 0) {
                                      output += \`(<span style='color:#e74c3c'>0E: \${nvmeIntegrity_Error}-故障！</span>\`;
                                      if (nvme.Available_Spares.length > 0) output += ', 备用空间: ' + nvme.Available_Spares[0];
                                      output += \`)\`;
                                  }
                              }
                          }
                          output += '<br>';
                      }
                      if (nvme.Capacitys.length > 0) output += \`容量: \${nvme.Capacitys[0].replace(/ |,/gm, '')}\`;
                      if (nvme.Useds.length > 0) {
                          output += ' | ' + \`寿命: \${colorizeHealth(100-Number(nvme.Useds[0]))}\`;
                          if (nvme.Reads.length > 0) output += \`(已读\${nvme.Reads[0].replace(/ |,/gm, '')})\`;
                          if (nvme.Writtens.length > 0) output += \`(已写\${nvme.Writtens[0].replace(/ |,/gm, '')})\`;
                      }
                      if (nvme.Temperatures.length > 0) output += ' | 温度: ' + colorizeTemp(nvme.Temperatures[0]);
                      if (nvme.States.length > 0) {
                          output += '<br>I/O: ';
                          if (nvme.r_kBs.length > 0 || nvme.r_awaits.length > 0) {
                              output += '读-';
                              if (nvme.r_kBs.length > 0) {
                                  var nvme_r_mB = \`\${nvme.r_kBs[0]}\` / 1024;
                                  output += \`速度\${nvme_r_mB.toFixed(2)}MB/s\`;
                              }
                              if (nvme.r_awaits.length > 0) output += \`, 延迟\${nvme.r_awaits[0]}ms /\`;
                          }
                          if (nvme.w_kBs.length > 0 || nvme.w_awaits.length > 0) {
                              output += '写-';
                              if (nvme.w_kBs.length > 0) {
                                  var nvme_w_mB = \`\${nvme.w_kBs[0]}\` / 1024;
                                  output += \`速度\${nvme_w_mB.toFixed(2)}MB/s\`;
                              }
                              if (nvme.w_awaits.length > 0) output += \`, 延迟\${nvme.w_awaits[0]}ms |\`;
                          }
                          if (nvme.utils.length > 0) output += \`负载\${nvme.utils[0]}%\`;
                      }
                      if (nvme.Cycles.length > 0) {
                          output += '<br>' + \`通电: \${nvme.Cycles[0].replace(/ |,/gm, '')}次\`;
                          if (nvme.Shutdowns.length > 0) output += \`, 不安全断电\${nvme.Shutdowns[0].replace(/ |,/gm, '')}次\`;
                          if (nvme.Hours.length > 0) output += \`, 累计\${nvme.Hours[0].replace(/ |,/gm, '')}小时\`;
                      }
                  }
                  return output.replace(/\n/g, '<br>');
              } else {
                  return '提示: 未安装 NVME 或已直通 NVME 控制器！';
              }
           }
    },
EOF
                break
            fi
        done
    done

    cat >> $tmpf << 'EOF'
    {
          itemId: 'hdd-temperatures', colspan: 2, printBar: false,
          title: gettext('SATA盘'), textField: 'hdd_temperatures',
          renderer: function(value) {
              function colorizeTemp(temp) {
                  let tempNum = Number(temp);
                  if (Number.isNaN(tempNum)) return temp + '°C';
                  if (tempNum < 40) return '<span style="color:#27ae60;font-weight:600;">' + tempNum + '°C</span>';
                  if (tempNum < 50) return '<span style="color:#f39c12;font-weight:600;">' + tempNum + '°C</span>';
                  return '<span style="color:#e74c3c;font-weight:600;">' + tempNum + '°C</span>';
              }
              if (value.length > 0) {
                  try {
                      const jsonData = JSON.parse(value);
                      if (jsonData.standy === true) return '休眠中';
                      if (jsonData.model_name) {
                          let output = `<strong>${jsonData.model_name}</strong><br>`;
                          if (jsonData.temperature?.current !== undefined) output += `温度: ${colorizeTemp(jsonData.temperature.current)}`;
                          if (jsonData.power_on_time?.hours !== undefined) {
                              if (output.length > 0) output += ' | ';
                              output += `通电: ${jsonData.power_on_time.hours}小时`;
                              if (jsonData.power_cycle_count) output += `, 次数: ${jsonData.power_cycle_count}`;
                          }
                          if (jsonData.smart_status?.passed !== undefined) {
                              if (output.length > 0) output += ' | ';
                              output += 'SMART: ' + (jsonData.smart_status.passed ? '<span style="color:#27ae60">正常</span>' : '<span style="color:#e74c3c">警告!</span>');
                          }
                          return output;
                      }
                  } catch (e) {}
                  let outputs = [];
                  let devices = value.matchAll(/(\s*(Model|Device Model|Vendor).*:\s*[\s\S]*?\n){1,2}^User.*\[([\s\S]*?)\]\n^\s*9[\s\S]*?\-\s*([\d]+)[\s\S]*?(\n(^19[0,4][\s\S]*?$){1,2}|\s{0}$)/gm);
                  for (const device of devices) {
                      let devicemodel = '';
                      if (device[1].indexOf("Family") !== -1) devicemodel = device[1].replace(/.*Model Family:\s*([\s\S]*?)\n^Device Model:\s*([\s\S]*?)\n/m, '$1 - $2');
                      else if (device[1].match(/Vendor/)) devicemodel = device[1].replace(/.*Vendor:\s*([\s\S]*?)\n^.*Model:\s*([\s\S]*?)\n/m, '$1 $2');
                      else devicemodel = device[1].replace(/.*(Model|Device Model):\s*([\s\S]*?)\n/m, '$2');
                      let capacity = device[3] ? device[3].replace(/ |,/gm, '') : "未知容量";
                      let powerOnHours = device[4] || "未知";
                      let deviceOutput = '';
                      if (value.indexOf("Min/Max") !== -1) {
                          let devicetemps = device[6]?.matchAll(/19[0,4][\s\S]*?\-\s*(\d+)(\s\(Min\/Max\s(\d+)\/(\d+)\)$|\s{0}$)/gm);
                          for (const devicetemp of devicetemps || []) {
                              deviceOutput = `<strong>${devicemodel}</strong><br>容量: ${capacity} | 已通电: ${powerOnHours}小时 | 温度: ${colorizeTemp(devicetemp[1])}`;
                              outputs.push(deviceOutput);
                          }
                      } else if (value.indexOf("Temperature") !== -1 || value.match(/Airflow_Temperature/)) {
                          let devicetemps = device[6]?.matchAll(/19[0,4][\s\S]*?\-\s*(\d+)/gm);
                          for (const devicetemp of devicetemps || []) {
                              deviceOutput = `<strong>${devicemodel}</strong><br>容量: ${capacity} | 已通电: ${powerOnHours}小时 | 温度: ${colorizeTemp(devicetemp[1])}`;
                              outputs.push(deviceOutput);
                          }
                      } else {
                          if (value.match(/\/dev\/sd[a-z]/)) {
                              deviceOutput = `<strong>${devicemodel}</strong><br>容量: ${capacity} | 已通电: ${powerOnHours}小时 | 提示: 设备存在但未报告温度信息`;
                          } else {
                              deviceOutput = `<strong>${devicemodel}</strong><br>容量: ${capacity} | 已通电: ${powerOnHours}小时 | 提示: 未检测到温度传感器`;
                          }
                          outputs.push(deviceOutput);
                      }
                  }
                  if (!outputs.length && value.length > 0) {
                      let fallbackDevices = value.matchAll(/(\/dev\/sd[a-z]).*?Model:([\s\S]*?)\n/gm);
                      for (const fallbackDevice of fallbackDevices || []) {
                          outputs.push(`${fallbackDevice[2].trim()}<br>提示: 设备存在但无法获取完整信息`);
                      }
                  }
                  return outputs.length ? outputs.join('<br>') : '提示: 检测到硬盘但无法识别详细信息';
              } else {
                  return '提示: 未安装硬盘或已直通硬盘控制器';
              }
          }
    },
EOF

    ln=$(sed -n '/pveversion/,+10{/},/{=;q}}' $pvemanagerlib | head -1)
    sed -i "${ln}r $tmpf" $pvemanagerlib
    rm $tmpf

    log_step "调整页面高度"
    disk_count=$(lsblk -d -o NAME | grep -cE 'sd[a-z]|nvme[0-9]')
    height_increase=$((disk_count * 69))
    node_status_new_height=$((400 + height_increase))
    sed -i -r '/widget\.pveNodeStatus/,+5{/height/{s#[0-9]+#'$node_status_new_height'#}}' $pvemanagerlib
    cpu_status_new_height=$((300 + height_increase))
    sed -i -r '/widget\.pveCpuStatus/,+5{/height/{s#[0-9]+#'$cpu_status_new_height'#}}' $pvemanagerlib
    log_info "左栏高度: ${node_status_new_height}px, CPU面板: ${cpu_status_new_height}px"

    ln=$(sed -n -e '/widget.pveDcGuests/=' $pvemanagerlib | head -1)
    ln=$((ln + 10))
    sed -i "${ln}a\        textAlign: 'right'," $pvemanagerlib
    ln=$(sed -n -e '/widget.pveNodeStatus/=' $pvemanagerlib | head -1)
    ln=$((ln + 10))
    sed -i "${ln}a\        textAlign: 'right'," $pvemanagerlib

    log_step "去除订阅弹窗"
    remove_subscription_popup

    systemctl restart pveproxy
    log_success "修改完成！请刷新浏览器缓存 (Shift+F5)"
}

cpu_del() {
    nodes="/usr/share/perl5/PVE/API2/Nodes.pm"
    pvemanagerlib="/usr/share/pve-manager/js/pvemanagerlib.js"
    proxmoxlib="/usr/share/javascript/proxmox-widget-toolkit/proxmoxlib.js"
    pvever=$(pveversion | awk -F"/" '{print $2}')
    log_info "PVE 版本: $pvever"
    if [ -f "$nodes.$pvever.bak" ]; then
        rm -f $nodes $pvemanagerlib $proxmoxlib
        mv $nodes.$pvever.bak $nodes
        mv $pvemanagerlib.$pvever.bak $pvemanagerlib
        mv $proxmoxlib.$pvever.bak $proxmoxlib
        log_success "已删除监控，请刷新浏览器缓存 (Shift+F5)"
    else
        log_warn "你没有添加过监控，退出脚本。"
    fi
}

# ============ 6/7. Ceph 源 ============
pve9_ceph() {
    local sver=$(get_debian_ver)
    if [[ "$sver" != "trixie" && "$sver" != "bookworm" ]]; then
        log_error "ceph-squid 目前仅支持 PVE 8/9"
        return 1
    fi
    log_step "添加 ceph-squid 源..."
    mkdir -p /etc/apt/backup /etc/apt/sources.list.d
    [[ -e /etc/apt/sources.list.d/ceph.sources ]] && mv /etc/apt/sources.list.d/ceph.sources /etc/apt/backup/ceph.sources.bak
    [[ -e /etc/apt/sources.list.d/ceph.list ]] && mv /etc/apt/sources.list.d/ceph.list /etc/apt/backup/ceph.list.bak
    [[ -e /usr/share/perl5/PVE/CLI/pveceph.pm ]] && cp -rf /usr/share/perl5/PVE/CLI/pveceph.pm /etc/apt/backup/pveceph.pm.bak
    sed -i 's|http://download.proxmox.com|https://mirrors.tuna.tsinghua.edu.cn/proxmox|g' /usr/share/perl5/PVE/CLI/pveceph.pm
    cat > /etc/apt/sources.list.d/ceph.list <<-EOF
deb https://mirrors.tuna.tsinghua.edu.cn/proxmox/debian/ceph-squid ${sver} no-subscription
EOF
    log_success "添加 ceph-squid 源完成"
}

pve8_ceph() {
    local sver=$(get_debian_ver)
    if [[ "$sver" != "bookworm" && "$sver" != "bullseye" ]]; then
        log_error "ceph-quincy 目前仅支持 PVE 7/8"
        return 1
    fi
    log_step "添加 ceph-quincy 源..."
    mkdir -p /etc/apt/backup /etc/apt/sources.list.d
    [[ -e /etc/apt/sources.list.d/ceph.sources ]] && mv /etc/apt/sources.list.d/ceph.sources /etc/apt/backup/ceph.sources.bak
    [[ -e /etc/apt/sources.list.d/ceph.list ]] && mv /etc/apt/sources.list.d/ceph.list /etc/apt/backup/ceph.list.bak
    [[ -e /usr/share/perl5/PVE/CLI/pveceph.pm ]] && cp -rf /usr/share/perl5/PVE/CLI/pveceph.pm /etc/apt/backup/pveceph.pm.bak
    sed -i 's|http://download.proxmox.com|https://mirrors.tuna.tsinghua.edu.cn/proxmox|g' /usr/share/perl5/PVE/CLI/pveceph.pm
    cat > /etc/apt/sources.list.d/ceph.list <<-EOF
deb https://mirrors.tuna.tsinghua.edu.cn/proxmox/debian/ceph-quincy ${sver} main
EOF
    log_success "添加 ceph-quincy 源完成"
}

remove_ceph() {
    log_warn "会卸载 ceph，并删除所有 ceph 相关文件！"
    read -rp "确认继续？(y/n): " confirm
    [[ "$confirm" != "y" ]] && return
    systemctl stop ceph-mon.target ceph-mgr.target ceph-mds.target ceph-osd.target
    rm -rf /etc/systemd/system/ceph*
    killall -9 ceph-mon ceph-mgr ceph-mds ceph-osd 2>/dev/null
    rm -rf /var/lib/ceph/mon/* /var/lib/ceph/mgr/* /var/lib/ceph/mds/* /var/lib/ceph/osd/*
    pveceph purge 2>/dev/null
    apt purge -y ceph-mon ceph-osd ceph-mgr ceph-mds ceph-base ceph-mgr-modules-core
    rm -rf /etc/ceph /etc/pve/ceph.conf /etc/pve/priv/ceph.* /var/log/ceph /etc/pve/ceph /var/lib/ceph
    [[ -e /etc/apt/sources.list.d/ceph.sources ]] && mv /etc/apt/sources.list.d/ceph.sources /etc/apt/backup/ceph.sources.bak
    log_success "已成功卸载 ceph"
}

# ============ 9. 卸载旧内核 ============
remove_kernel() {
    log_warn "此操作非常危险，风险自行承担！"
    current_kernel=$(uname -r)
    available_kernels=$(dpkg --list | grep 'kernel-.*-pve' | awk '{print $2}' | grep -v "$current_kernel" | sort -V)
    if [ -z "$available_kernels" ]; then
        log_success "未检测到旧内核，当前内核: ${current_kernel}"
        return
    fi
    echo "可供移除的内核:"
    echo "$available_kernels" | nl -w 2 -s '. '
    echo -e "\n选择要删除的内核（以逗号分隔，例如 1,2）:"
    read -r selected
    IFS=',' read -r -a selected_indices <<<"$selected"
    kernels_to_remove=()
    for index in "${selected_indices[@]}"; do
        kernel=$(echo "$available_kernels" | sed -n "${index}p")
        [ -n "$kernel" ] && kernels_to_remove+=("$kernel")
    done
    if [ ${#kernels_to_remove[@]} -eq 0 ]; then
        log_error "未做出有效选择"
        return
    fi
    echo "待移除的内核:"
    printf "%s\n" "${kernels_to_remove[@]}"
    read -rp "继续删除吗？(y/n): " confirm
    [[ "$confirm" != "y" ]] && return
    for kernel in "${kernels_to_remove[@]}"; do
        log_step "移除 $kernel..."
        if apt-get purge -y "$kernel" >/dev/null 2>&1; then
            log_success "已成功移除: $kernel"
        else
            log_error "删除失败: $kernel"
        fi
    done
    apt-get autoremove -y >/dev/null 2>&1 && update-grub >/dev/null 2>&1
    log_success "清理和 GRUB 更新完成"
}

# ============ 10. 合并 local 存储 ============
merge_local_storage() {
    log_step "准备合并存储空间，让小硬盘发挥最大价值"
    log_warn "此操作会删除 local-lvm，请确保重要数据已备份！"
    read -p "输入 'yes' 确认继续，其他任意键取消: " -r
    if [[ ! $REPLY == "yes" ]]; then
        log_info "操作已取消"
        return
    fi
    if ! lvdisplay /dev/pve/data &> /dev/null; then
        log_warn "没有找到 local-lvm 分区，可能已经合并过了"
        return
    fi
    log_info "正在删除 local-lvm 分区..."
    lvremove -f /dev/pve/data
    log_info "正在扩容 local 分区..."
    lvextend -l +100%FREE /dev/pve/root
    log_info "正在扩展文件系统..."
    resize2fs /dev/pve/root
    log_success "存储合并完成！"
    log_warn "请在 Web UI 中删除 local-lvm 存储配置，并编辑 local 存储勾选所有内容类型"
}

# ============ 11. 删除 Swap ============
remove_swap() {
    log_step "准备释放 Swap 空间给系统使用"
    log_warn "删除 Swap 后请确保内存充足！"
    read -p "输入 'yes' 确认继续，其他任意键取消: " -r
    if [[ ! $REPLY == "yes" ]]; then
        log_info "操作已取消"
        return
    fi
    if ! lvdisplay /dev/pve/swap &> /dev/null; then
        log_warn "没有找到 swap 分区，可能已经删除过了"
        return
    fi
    log_info "正在关闭 Swap..."
    swapoff /dev/mapper/pve-swap
    log_info "正在修改启动配置..."
    backup_file "/etc/fstab"
    sed -i 's|^/dev/pve/swap|# /dev/pve/swap|g' /etc/fstab
    log_info "正在删除 swap 分区..."
    lvremove -f /dev/pve/swap
    log_info "正在扩展系统分区..."
    lvextend -l +100%FREE /dev/mapper/pve-root
    log_info "正在扩展文件系统..."
    resize2fs /dev/mapper/pve-root
    log_success "Swap 删除完成！系统空间更宽裕了"
}

# ============ 12. 邮件通知配置 ============
pve_mail_setup() {
    log_step "配置 PVE 邮件通知（SMTP）"

    if ! command -v postfix >/dev/null 2>&1; then
        log_warn "未检测到 postfix，正在安装..."
        apt-get install -y postfix mailutils libsasl2-modules
    fi

    local from_addr root_addr
    read -p "请输入发件人邮箱: " from_addr
    [[ -z "$from_addr" ]] && { log_error "发件人邮箱不能为空"; return 1; }
    read -p "请输入 root 通知邮箱（收件人）: " root_addr
    [[ -z "$root_addr" ]] && { log_error "收件人邮箱不能为空"; return 1; }

    echo "请选择 SMTP 预设："
    echo "  1) QQ 邮箱（smtp.qq.com:465 SSL）"
    echo "  2) 163 邮箱（smtp.163.com:465 SSL）"
    echo "  3) Gmail（smtp.gmail.com:587 STARTTLS）"
    echo "  4) 自定义"
    read -p "请选择 [1-4, 默认1]: " preset
    preset=${preset:-1}

    local smtp_host smtp_port tls_mode
    case "$preset" in
        1) smtp_host="smtp.qq.com"; smtp_port="465"; tls_mode="wrapper" ;;
        2) smtp_host="smtp.163.com"; smtp_port="465"; tls_mode="wrapper" ;;
        3) smtp_host="smtp.gmail.com"; smtp_port="587"; tls_mode="starttls" ;;
        4)
            read -p "SMTP 服务器地址: " smtp_host
            read -p "SMTP 端口: " smtp_port
            read -p "TLS 模式（wrapper/starttls）[wrapper]: " tls_mode
            tls_mode=${tls_mode:-wrapper}
            ;;
        *) smtp_host="smtp.qq.com"; smtp_port="465"; tls_mode="wrapper" ;;
    esac

    local smtp_user smtp_pass
    read -p "SMTP 登录账号 [${from_addr}]: " smtp_user
    smtp_user=${smtp_user:-$from_addr}
    echo -n "SMTP 密码/授权码（输入不回显）: "
    read -r -s smtp_pass
    echo
    [[ -z "$smtp_pass" ]] && { log_error "密码不能为空"; return 1; }

    # 安装 SASL 模块
    apt-get install -y libsasl2-modules >/dev/null 2>&1

    # 配置 postfix
    log_step "配置 postfix..."
    backup_file "/etc/postfix/main.cf"

    postconf -e "relayhost = [${smtp_host}]:${smtp_port}"
    postconf -e "smtp_sasl_auth_enable = yes"
    postconf -e "smtp_sasl_password_maps = hash:/etc/postfix/sasl_passwd"
    postconf -e "smtp_sasl_security_options = noanonymous"
    postconf -e "smtp_use_tls = yes"

    if [[ "$tls_mode" == "wrapper" ]]; then
        postconf -e "smtp_tls_wrappermode = yes"
        postconf -e "smtp_tls_security_level = encrypt"
    else
        postconf -e "smtp_tls_wrappermode = no"
        postconf -e "smtp_tls_security_level = may"
    fi

    # 写入 SASL 密码文件
    echo "[${smtp_host}]:${smtp_port} ${smtp_user}:${smtp_pass}" > /etc/postfix/sasl_passwd
    chmod 600 /etc/postfix/sasl_passwd
    postmap /etc/postfix/sasl_passwd

    # 配置发件人/收件人
    postconf -e "sender_canonical_maps = regexp:/etc/postfix/sender_canonical"
    echo "/.*/ ${from_addr}" > /etc/postfix/sender_canonical

    # 设置 PVE 数据中心邮件
    pvesh set /cluster/notifications/targets/default-sendmail --mailto "$root_addr" 2>/dev/null || true

    # 重载 postfix
    systemctl reload postfix
    log_success "postfix 配置完成"

    # 测试发送
    read -p "是否发送测试邮件？(y/N): " test_choice
    if [[ "$test_choice" =~ ^[Yy]$ ]]; then
        echo "PVE-K 邮件测试：如果你收到，说明 SMTP 中继已可用。" | mail -s "PVE-K 邮件测试" "$root_addr"
        log_info "测试邮件已提交发送队列（请检查收件箱与垃圾箱）"
    fi

    log_success "邮件通知配置完成"
}

# ============ 13. 内核管理 ============
kernel_management_menu() {
    while true; do
        clear
        echo -e "${H1}═════════════════════════════════════════════════${NC}"
        echo -e "${H1}         内核管理${NC}"
        echo -e "${UI_BORDER}"
        echo -e "${CYAN}  1. 显示当前内核信息${NC}"
        echo -e "${CYAN}  2. 查看可用内核列表${NC}"
        echo -e "${CYAN}  3. 安装新内核${NC}"
        echo -e "${CYAN}  4. 设置默认启动内核${NC}"
        echo -e "${CYAN}  5. 清理旧内核${NC}"
        echo -e "${CYAN}  6. 重启系统${NC}"
        echo -e "${CYAN}  0. 返回主菜单${NC}"
        echo -e "${UI_BORDER}"
        read -p "请选择 [0-6]: " choice
        case "$choice" in
            1)
                log_info "当前内核: $(uname -r) ($(uname -m))"
                echo "已安装的内核:"
                dpkg -l 2>/dev/null | awk '$2 ~ /^(pve-kernel|proxmox-kernel)-[0-9].*-pve/ && $1 ~ /^(ii|hi)$/ {print "  • " $2}' | sort -V
                ;;
            2)
                log_info "正在获取可用内核列表..."
                apt-get update >/dev/null 2>&1
                local available=$(apt-cache search --names-only '^pve-kernel-.*' 2>/dev/null | awk '{print $1}' | sort -V)
                if [[ -z "$available" ]]; then
                    available=$(apt-cache search --names-only '^proxmox-kernel-.*' 2>/dev/null | awk '{print $1}' | sort -V)
                fi
                if [[ -n "$available" ]]; then
                    echo "$available" | while read -r k; do echo "  • $k"; done
                else
                    log_warn "无法获取可用内核列表，请检查软件源"
                fi
                ;;
            3)
                read -p "请输入要安装的内核版本（如 proxmox-kernel-6.8.12-1-pve）: " kernel_ver
                if [[ -n "$kernel_ver" ]]; then
                    apt-get install -y "$kernel_ver" && log_success "内核安装成功" || log_error "内核安装失败"
                    update-grub
                fi
                ;;
            4)
                read -p "请输入要设为默认的内核版本（如 6.8.12-1-pve）: " kernel_ver
                if [[ -n "$kernel_ver" ]]; then
                    if [[ -f "/boot/vmlinuz-${kernel_ver}" ]]; then
                        grub-set-default "gnulinux-advanced-*/gnulinux-${kernel_ver}-advanced-*" 2>/dev/null && \
                            log_success "默认内核已设置" || log_warn "设置失败，请手动检查"
                        update-grub
                    else
                        log_error "内核文件不存在: /boot/vmlinuz-${kernel_ver}"
                    fi
                fi
                ;;
            5)
                remove_kernel
                ;;
            6)
                read -p "确认重启系统？(y/N): " reboot_confirm
                if [[ "$reboot_confirm" =~ ^[Yy]$ ]]; then
                    log_info "5秒后重启，按 Ctrl+C 取消..."
                    sleep 5 && reboot
                fi
                ;;
            0) break ;;
            *) log_warn "无效选择" ;;
        esac
        pause
    done
}

# ============ 14. 核显虚拟化 ============
igpu_menu() {
    while true; do
        clear
        echo -e "${H1}═════════════════════════════════════════════════${NC}"
        echo -e "${H1}         Intel 核显虚拟化管理${NC}"
        echo -e "${UI_BORDER}"
        echo -e "${CYAN}  1. Intel 11-15代 SR-IOV 配置${NC}"
        echo -e "${CYAN}  2. Intel 6-10代 GVT-g 配置${NC}"
        echo -e "${CYAN}  3. 验证核显虚拟化状态${NC}"
        echo -e "${CYAN}  4. 清理核显虚拟化配置${NC}"
        echo -e "${CYAN}  0. 返回主菜单${NC}"
        echo -e "${UI_BORDER}"
        read -p "请选择 [0-4]: " choice
        case "$choice" in
            1) igpu_sriov_setup ;;
            2) igpu_gvtg_setup ;;
            3) igpu_verify ;;
            4) igpu_restore ;;
            0) break ;;
            *) log_warn "无效选择" ;;
        esac
        pause
    done
}

grub_add_param() {
    local param="$1"
    [[ -z "$param" ]] && return 1
    backup_file "/etc/default/grub"
    local current_line=$(grep '^GRUB_CMDLINE_LINUX_DEFAULT=' /etc/default/grub)
    [[ -z "$current_line" ]] && { log_error "未找到 GRUB_CMDLINE_LINUX_DEFAULT"; return 1; }
    local current_params=$(echo "$current_line" | sed 's/^GRUB_CMDLINE_LINUX_DEFAULT="\(.*\)"$/\1/')
    local param_key=$(echo "$param" | cut -d'=' -f1)
    if echo "$current_params" | grep -qw "$param_key"; then
        current_params=$(echo "$current_params" | sed "s/\b${param_key}[^ ]*\b//g")
    fi
    local new_params=$(echo "$current_params $param" | sed 's/  */ /g' | sed 's/^ //;s/ $//')
    sed -i "s|^GRUB_CMDLINE_LINUX_DEFAULT=.*|GRUB_CMDLINE_LINUX_DEFAULT=\"$new_params\"|" /etc/default/grub
    log_success "GRUB 参数已添加: $param"
}

grub_remove_param() {
    local param="$1"
    [[ -z "$param" ]] && return 1
    backup_file "/etc/default/grub"
    local current_line=$(grep '^GRUB_CMDLINE_LINUX_DEFAULT=' /etc/default/grub)
    [[ -z "$current_line" ]] && { log_error "未找到 GRUB_CMDLINE_LINUX_DEFAULT"; return 1; }
    local current_params=$(echo "$current_line" | sed 's/^GRUB_CMDLINE_LINUX_DEFAULT="\(.*\)"$/\1/')
    local param_key=$(echo "$param" | cut -d'=' -f1)
    local new_params=$(echo "$current_params" | sed "s/\b${param_key}[^ ]*\b//g" | sed 's/  */ /g' | sed 's/^ //;s/ $//')
    sed -i "s|^GRUB_CMDLINE_LINUX_DEFAULT=.*|GRUB_CMDLINE_LINUX_DEFAULT=\"$new_params\"|" /etc/default/grub
    log_success "GRUB 参数已删除: $param"
}

igpu_sriov_setup() {
    log_step "配置 Intel 11-15代 SR-IOV 核显虚拟化"
    log_warn "此操作属于高危操作，配置错误可能导致系统无法启动！"
    read -p "输入 'yes' 确认继续: " -r
    [[ "$REPLY" != "yes" ]] && { log_info "已取消"; return; }

    # 检查内核版本
    local kernel_major=$(uname -r | cut -d'.' -f1)
    local kernel_minor=$(uname -r | cut -d'.' -f2)
    if [ "$kernel_major" -lt 6 ] || ([ "$kernel_major" -eq 6 ] && [ "$kernel_minor" -lt 8 ]); then
        log_error "SR-IOV 需要内核 6.8+，当前: $(uname -r)"
        return 1
    fi
    log_success "内核版本检查通过: $(uname -r)"

    # 安装依赖
    apt-get update
    apt-get install -y "pve-headers-$(uname -r)" build-essential dkms sysfsutils

    # 配置 GRUB
    grub_remove_param "i915.enable_gvt"
    grub_remove_param "pcie_acs_override"
    grub_add_param "intel_iommu=on"
    grub_add_param "iommu=pt"
    grub_add_param "i915.enable_guc=3"
    grub_add_param "i915.max_vfs=7"
    grub_add_param "module_blacklist=xe"
    update-grub

    # 配置内核模块
    for module in vfio vfio_iommu_type1 vfio_pci vfio_virqfd; do
        grep -q "^$module$" /etc/modules || echo "$module" >> /etc/modules
    done
    sed -i '/^kvmgt$/d' /etc/modules
    # 清理 i915 黑名单
    for f in /etc/modprobe.d/blacklist.conf /etc/modprobe.d/pve-blacklist.conf; do
        [[ -f "$f" ]] && sed -i '/blacklist i915/d;/blacklist snd_hda_intel/d;/blacklist snd_hda_codec_hdmi/d' "$f"
    done
    update-initramfs -u -k all

    # 下载 i915-sriov-dkms
    local dkms_ver="2025.11.10"
    read -p "请输入 i915-sriov-dkms 版本 [默认: ${dkms_ver}]: " input_ver
    dkms_ver=${input_ver:-$dkms_ver}
    local deb_url="https://github.com/strongtz/i915-sriov-dkms/releases/download/v${dkms_ver}/i915-sriov-dkms_${dkms_ver}_amd64.deb"
    log_info "下载 i915-sriov-dkms v${dkms_ver}..."
    wget -O /tmp/i915-sriov-dkms.deb "$deb_url" && dpkg -i /tmp/i915-sriov-dkms.deb || log_error "驱动安装失败"
    rm -f /tmp/i915-sriov-dkms.deb

    log_success "SR-IOV 配置完成，请重启系统生效"
    log_warn "物理核显 (00:02.0) 不能直通，否则所有虚拟核显将消失"
}

igpu_gvtg_setup() {
    log_step "配置 Intel 6-10代 GVT-g 核显虚拟化"
    log_warn "此操作会修改 GRUB 和内核模块配置"
    read -p "输入 'yes' 确认继续: " -r
    [[ "$REPLY" != "yes" ]] && { log_info "已取消"; return; }

    grub_remove_param "i915.enable_guc"
    grub_remove_param "i915.max_vfs"
    grub_remove_param "module_blacklist=xe"
    grub_add_param "intel_iommu=on"
    grub_add_param "i915.enable_gvt=1"
    update-grub

    grep -q "^kvmgt$" /etc/modules || echo "kvmgt" >> /etc/modules
    for module in vfio vfio_iommu_type1 vfio_pci vfio_virqfd; do
        grep -q "^$module$" /etc/modules || echo "$module" >> /etc/modules
    done
    update-initramfs -u -k all
    log_success "GVT-g 配置完成，请重启系统生效"
}

igpu_verify() {
    log_info "当前内核: $(uname -r)"
    local grub_params=$(grep '^GRUB_CMDLINE_LINUX_DEFAULT=' /etc/default/grub | sed 's/^GRUB_CMDLINE_LINUX_DEFAULT="//;s/"$//')
    echo "GRUB 参数:"
    echo "$grub_params" | tr ' ' '\n' | while read -r p; do [[ -n "$p" ]] && echo "  • $p"; done
    echo
    if echo "$grub_params" | grep -q "i915.enable_guc=3"; then
        log_success "SR-IOV: 已配置"
    elif echo "$grub_params" | grep -q "i915.enable_gvt=1"; then
        log_success "GVT-g: 已配置"
    else
        log_info "核显虚拟化: 未配置"
    fi
    # 检查 VFs
    local vfs=$(ls /sys/bus/pci/devices/0000:00:02.0/virtfn* 2>/dev/null | wc -l)
    [[ $vfs -gt 0 ]] && log_success "检测到 ${vfs} 个虚拟核显(VFs)" || log_info "未检测到虚拟核显"
}

igpu_restore() {
    log_step "清理核显虚拟化配置"
    read -p "输入 'yes' 确认: " -r
    [[ "$REPLY" != "yes" ]] && return
    grub_remove_param "i915.enable_guc"
    grub_remove_param "i915.max_vfs"
    grub_remove_param "i915.enable_gvt"
    grub_remove_param "module_blacklist=xe"
    grub_remove_param "iommu=pt"
    sed -i '/^kvmgt$/d' /etc/modules
    update-grub
    update-initramfs -u -k all
    log_success "核显虚拟化配置已清理，请重启系统"
}

# ============ 15. RDM 磁盘直通 ============
rdm_menu() {
    while true; do
        clear
        echo -e "${H1}═════════════════════════════════════════════════${NC}"
        echo -e "${H1}         RDM 磁盘直通${NC}"
        echo -e "${UI_BORDER}"
        echo -e "${CYAN}  1. 查看可直通磁盘${NC}"
        echo -e "${CYAN}  2. 添加单盘直通${NC}"
        echo -e "${CYAN}  3. 取消单盘直通${NC}"
        echo -e "${CYAN}  0. 返回主菜单${NC}"
        echo -e "${UI_BORDER}"
        read -p "请选择 [0-3]: " choice
        case "$choice" in
            1) rdm_list_disks ;;
            2) rdm_attach ;;
            3) rdm_detach ;;
            0) break ;;
            *) log_warn "无效选择" ;;
        esac
        pause
    done
}

rdm_list_disks() {
    log_info "可直通磁盘列表："
    local byid_dir="/dev/disk/by-id"
    if [[ ! -d "$byid_dir" ]]; then
        log_error "未找到 $byid_dir"
        return 1
    fi
    local idx=0
    for link in $(find "$byid_dir" -maxdepth 1 -type l 2>/dev/null | sort); do
        local base=$(basename "$link")
        [[ "$base" =~ -part[0-9]+$ ]] && continue
        local real_dev=$(readlink -f "$link" 2>/dev/null)
        [[ -z "$real_dev" || ! -b "$real_dev" ]] && continue
        local dev_type=$(lsblk -dn -o TYPE "$real_dev" 2>/dev/null | head -1)
        [[ "$dev_type" != "disk" ]] && continue
        # 跳过 DM/LVM
        [[ "$real_dev" == /dev/mapper/* || "$(basename "$real_dev")" == dm-* ]] && continue
        local size=$(lsblk -dn -o SIZE "$real_dev" 2>/dev/null | head -1)
        local model=$(lsblk -dn -o MODEL "$real_dev" 2>/dev/null | head -1)
        echo "  [$idx] $base -> $real_dev  ${size:-?}  ${model:-?}"
        idx=$((idx + 1))
    done
    [[ $idx -eq 0 ]] && log_warn "未发现可直通磁盘"
}

rdm_attach() {
    rdm_list_disks
    read -p "请输入磁盘 by-id 路径（如 /dev/disk/by-id/ata-XXX）: " id_path
    [[ -z "$id_path" || ! -e "$id_path" ]] && { log_error "无效路径"; return 1; }
    read -p "请输入目标 VMID: " vmid
    [[ -z "$vmid" || ! "$vmid" =~ ^[0-9]+$ ]] && { log_error "无效 VMID"; return 1; }
    read -p "总线类型 (scsi/sata/ide) [scsi]: " bus
    bus=${bus:-scsi}
    # 查找可用插槽
    local slot=""
    local max_idx=30
    [[ "$bus" == "sata" ]] && max_idx=5
    [[ "$bus" == "ide" ]] && max_idx=3
    local cfg=$(qm config "$vmid" 2>/dev/null)
    [[ -z "$cfg" ]] && { log_error "无法读取 VM $vmid 配置"; return 1; }
    for ((i=0; i<=max_idx; i++)); do
        if ! echo "$cfg" | grep -qE "^${bus}${i}:"; then
            slot="${bus}${i}"
            break
        fi
    done
    [[ -z "$slot" ]] && { log_error "无可用 $bus 插槽"; return 1; }
    log_info "将直通: $id_path -> VM $vmid ($slot)"
    backup_file "$(qm config "$vmid" 2>/dev/null | head -1 || echo /etc/pve/qemu-server/${vmid}.conf)"
    if qm set "$vmid" "-$slot" "$id_path" 2>/dev/null; then
        log_success "直通配置已写入 VM $vmid ($slot)"
    else
        log_error "qm set 执行失败，请检查磁盘是否被占用"
    fi
}

rdm_detach() {
    read -p "请输入目标 VMID: " vmid
    [[ -z "$vmid" || ! "$vmid" =~ ^[0-9]+$ ]] && { log_error "无效 VMID"; return 1; }
    echo "当前 VM $vmid 磁盘配置:"
    qm config "$vmid" 2>/dev/null | grep -E '^(scsi|sata|ide|virtio)' | nl -w 2 -s '. '
    read -p "请输入要移除的插槽（如 scsi1）: " slot
    [[ -z "$slot" ]] && { log_error "未输入插槽"; return 1; }
    if qm set "$vmid" -delete "$slot" 2>/dev/null; then
        log_success "已移除 VM $vmid 的 $slot"
    else
        log_error "移除失败，请检查插槽名是否正确"
    fi
}

# ============ 16. GRUB 参数管理 ============
grub_menu() {
    while true; do
        clear
        echo -e "${H1}═════════════════════════════════════════════════${NC}"
        echo -e "${H1}         GRUB 参数管理${NC}"
        echo -e "${UI_BORDER}"
        echo -e "${CYAN}  1. 查看当前 GRUB 配置${NC}"
        echo -e "${CYAN}  2. 添加 GRUB 参数${NC}"
        echo -e "${CYAN}  3. 删除 GRUB 参数${NC}"
        echo -e "${CYAN}  4. 更新 GRUB${NC}"
        echo -e "${CYAN}  0. 返回主菜单${NC}"
        echo -e "${UI_BORDER}"
        read -p "请选择 [0-4]: " choice
        case "$choice" in
            1)
                log_info "当前 GRUB 参数:"
                local params=$(grep '^GRUB_CMDLINE_LINUX_DEFAULT=' /etc/default/grub | sed 's/^GRUB_CMDLINE_LINUX_DEFAULT="//;s/"$//')
                if [[ -n "$params" ]]; then
                    echo "$params" | tr ' ' '\n' | while read -r p; do
                        [[ -n "$p" ]] && echo "  • $p"
                    done
                else
                    log_warn "未找到 GRUB_CMDLINE_LINUX_DEFAULT"
                fi
                echo
                # 关键参数检测
                echo "关键参数检测:"
                echo "$params" | grep -q "intel_iommu=on\|amd_iommu=on" && echo "  [OK] IOMMU: 已启用" || echo "  [INFO] IOMMU: 未启用"
                echo "$params" | grep -q "iommu=pt" && echo "  [OK] 直通优化: 已启用" || echo "  [INFO] 直通优化: 未启用"
                echo "$params" | grep -q "i915.enable_guc=3" && echo "  [OK] SR-IOV: 已配置" || echo "  [INFO] SR-IOV: 未配置"
                echo "$params" | grep -q "i915.enable_gvt=1" && echo "  [OK] GVT-g: 已配置" || echo "  [INFO] GVT-g: 未配置"
                ;;
            2)
                read -p "请输入要添加的参数（如 intel_iommu=on）: " param
                if [[ -n "$param" ]]; then
                    grub_add_param "$param"
                    read -p "是否立即更新 GRUB？(Y/n): " upd
                    [[ "$upd" != "n" ]] && update-grub && log_success "GRUB 已更新"
                fi
                ;;
            3)
                read -p "请输入要删除的参数键名（如 intel_iommu）: " param
                if [[ -n "$param" ]]; then
                    grub_remove_param "$param"
                    read -p "是否立即更新 GRUB？(Y/n): " upd
                    [[ "$upd" != "n" ]] && update-grub && log_success "GRUB 已更新"
                fi
                ;;
            4)
                update-grub && log_success "GRUB 更新完成" || log_error "GRUB 更新失败"
                ;;
            0) break ;;
            *) log_warn "无效选择" ;;
        esac
        pause
    done
}

# ============ 主菜单 ============
menu() {
    while :; do
        clear
        echo -e "${H1}═════════════════════════════════════════════════${NC}"
        echo -e "${H1}         PVE-K 全能优化脚本 v${VERSION}${NC}"
        echo -e "${H1}═════════════════════════════════════════════════${NC}"
        echo -e "${CYAN}  1. 一键优化PVE (换源/去弹窗/密钥)${NC}"
        echo -e "${CYAN}  2. 配置PCI硬件直通${NC}"
        echo -e "${CYAN}  3. 设置CPU电源模式${NC}"
        echo -e "${CYAN}  4. 添加 CPU/硬盘/温度详细监控${NC}"
        echo -e "${CYAN}  5. 删除监控（恢复官方文件）${NC}"
        echo -e "${CYAN}  6. PVE8/9 添加 ceph-squid 源${NC}"
        echo -e "${CYAN}  7. PVE7/8 添加 ceph-quincy 源${NC}"
        echo -e "${CYAN}  8. 一键卸载 ceph${NC}"
        echo -e "${CYAN}  9. 一键卸载旧内核 (危险!)${NC}"
        echo -e "${CYAN}  10. 合并 local 存储${NC}"
        echo -e "${CYAN}  11. 删除 Swap 扩容系统分区${NC}"
        echo -e "${CYAN}  12. 邮件通知配置 (SMTP)${NC}"
        echo -e "${CYAN}  13. 内核管理${NC}"
        echo -e "${CYAN}  14. 核显虚拟化 (SR-IOV/GVT-g)${NC}"
        echo -e "${CYAN}  15. RDM 磁盘直通${NC}"
        echo -e "${CYAN}  16. GRUB 参数管理${NC}"
        echo -e "${CYAN}  0. 退出${NC}"
        echo -e "${UI_BORDER}"
        echo -ne " 请选择: [ ]\b\b"
        read -t 60 menuid
        menuid=${menuid:-0}
        case ${menuid} in
            1) pve_optimization ; pause ;;
            2) hw_passth ;;
            3) cpupower_menu ;;
            4) cpu_add ; pause ;;
            5) cpu_del ; pause ;;
            6) pve9_ceph ; pause ;;
            7) pve8_ceph ; pause ;;
            8) remove_ceph ; pause ;;
            9) remove_kernel ; pause ;;
            10) merge_local_storage ; pause ;;
            11) remove_swap ; pause ;;
            12) pve_mail_setup ; pause ;;
            13) kernel_management_menu ;;
            14) igpu_menu ;;
            15) rdm_menu ;;
            16) grub_menu ;;
            0) clear; exit 0 ;;
            *) log_warn "无效选项"; pause ;;
        esac
    done
}

if [[ $EUID -ne 0 ]]; then
    log_error "请使用 root 权限运行此脚本"
    exit 1
fi

menu
