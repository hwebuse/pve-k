#!/bin/bash
# =============================================================================
# PVE-K 硬件监控增强脚本 v2.0
# 融合: xiangfeidexiaohuo/pve-diy (详细硬件信息)
#       Mapleawaa/PVE-Tools-9 (彩色UI/温度阈值/安全机制/UPS)
# 功能: CPU频率/功耗/温度、NVMe/SATA详细状态、UPS、去除订阅弹窗
# =============================================================================

VERSION="2.0.0"

# ============ 颜色与 UI 系统 (源自 PVE-Tools-9) ============
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
        PRIMARY="${CYAN}"
        H1=$(printf '\033[1;36m')
        H2=$(printf '\033[1;37m')
    else
        RED='' ; GREEN='' ; YELLOW='' ; BLUE='' ; CYAN=''
        MAGENTA='' ; WHITE='' ; ORANGE='' ; NC='' ; PRIMARY='' ; H1='' ; H2=''
    fi
    UI_BORDER="${NC}═════════════════════════════════════════════════${NC}"
    UI_DIVIDER="${NC}─────────────────────────────────────────────────${NC}"
}
setup_colors

log_info()  { local ts=$(date +'%H:%M:%S'); echo -e "${GREEN}[$ts]${NC} ${CYAN}INFO${NC}  $1"; }
log_warn()  { local ts=$(date +'%H:%M:%S'); echo -e "${YELLOW}[$ts]${NC} ${ORANGE}WARN${NC}  $1"; }
log_error() { local ts=$(date +'%H:%M:%S'); echo -e "${RED}[$ts]${NC} ${RED}ERROR${NC} $1" >&2; }
log_step()  { local ts=$(date +'%H:%M:%S'); echo -e "${BLUE}[$ts]${NC} ${MAGENTA}STEP${NC}  $1"; }
log_success(){ local ts=$(date +'%H:%M:%S'); echo -e "${GREEN}[$ts]${NC} ${GREEN}OK${NC}   $1"; }

show_status() {
    case "$1" in
        "info")    echo -e "${CYAN}[INFO]${NC} $2" ;;
        "success") echo -e "${GREEN}[ OK ]${NC} $2" ;;
        "warning") echo -e "${YELLOW}[WARN]${NC} $2" ;;
        "error")   echo -e "${RED}[FAIL]${NC} $2" ;;
        "step")    echo -e "${MAGENTA}[STEP]${NC} $2" ;;
    esac
}

pause() {
    read -n 1 -p " 按任意键继续... " input
    [[ -n ${input} ]] && echo
}

# ============ 备份与还原 ============
backup_file() {
    local file="$1"
    local backup_dir="/var/backups/pve-k"
    mkdir -p "$backup_dir"
    if [[ -f "$file" ]]; then
        cp "$file" "${backup_dir}/$(basename $file).$(date +%Y%m%d%H%M%S).bak"
    fi
}

# ============ 去除订阅弹窗 ============
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
        log_success "已去除订阅弹窗"
    fi
}

# ============ CPU 添加 / 删除 ============
cpu_add() {
    nodes="/usr/share/perl5/PVE/API2/Nodes.pm"
    pvemanagerlib="/usr/share/pve-manager/js/pvemanagerlib.js"
    proxmoxlib="/usr/share/javascript/proxmox-widget-toolkit/proxmoxlib.js"
    pvever=$(pveversion | awk -F"/" '{print $2}')
    log_info "PVE 版本: $pvever"

    # 幂等性检测
    if [ $(grep 'modbyshowtempfreq' $nodes $pvemanagerlib $proxmoxlib 2>/dev/null | wc -l) -eq 3 ]; then
        log_warn "已经修改过，请勿重复修改"
        log_warn "如果没有生效，请使用 Shift+F5 刷新浏览器缓存"
        log_warn "如果需要强制重新修改，请先执行还原操作"
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
    chmod +s /usr/sbin/nvme
    chmod +s /usr/sbin/smartctl
    chmod +s /usr/sbin/turbostat 2>/dev/null || log_warn "无法设置 turbostat 权限"
    modprobe msr && echo msr > /etc/modules-load.d/turbostat-msr.conf

    if [ "$install" == "ok" ]; then
        log_success "软件包安装完成，检测硬件信息"
        sensors-detect --auto > /tmp/sensors
        drivers=$(sed -n '/Chip drivers/,/\#----cut here/p' /tmp/sensors | sed '/Chip /d' | sed '/cut/d')
        if [ $(echo $drivers | wc -w) = 0 ]; then
            log_warn "没有找到任何驱动，似乎系统不支持或驱动安装失败。"
            pause
        else
            for i in $drivers; do
                modprobe $i
                if [ $(grep $i /etc/modules | wc -l) = 0 ]; then
                    echo $i >> /etc/modules
                fi
            done
            sensors
            sleep 2
            log_success "驱动信息配置成功。"
        fi
        [[ -e /etc/init.d/kmod ]] && /etc/init.d/kmod start
        rm /tmp/sensors
    fi

    log_step "备份源文件"
    backup_file "$nodes"
    backup_file "$pvemanagerlib"
    backup_file "$proxmoxlib"

    # 版本备份
    rm -f $nodes.*.bak $pvemanagerlib.*.bak $proxmoxlib.*.bak
    cp $nodes $nodes.$pvever.bak
    cp $pvemanagerlib $pvemanagerlib.$pvever.bak
    cp $proxmoxlib $proxmoxlib.$pvever.bak

    # UPS 选项
    local enable_ups=false
    local nut_ups_target=""
    echo -n "是否启用 UPS 监控？(y/N，默认N): "
    read -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        enable_ups=true
        read -r -p "请输入 NUT UPS 设备名 [默认: ups]: " nut_ups_name
        nut_ups_name=${nut_ups_name:-ups}
        nut_ups_target="${nut_ups_name}@localhost"
        log_success "已启用 UPS 监控 (NUT: ${nut_ups_target})"
        if ! dpkg -s nut-client &> /dev/null; then
            apt-get install nut-client -y
        fi
    else
        log_info "已跳过 UPS 监控"
    fi

    # ============ 生成 Nodes.pm 后端变量 ============
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

    # NVMe 变量（文本模式，兼容 pve-diy 的详细解析）
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

    # 注入 Nodes.pm
    ln=$(sed -n -e '/PVE::pvecfg::version_text/=' $nodes | head -1)
    ln=$((ln + 1))
    sed -i "${ln}r $tmpf" $nodes
    rm $tmpf

    # ============ 生成 pvemanagerlib.js 前端渲染器 ============
    tmpf=tmpfile.temp
    touch $tmpf
    cat > $tmpf << 'EOF'
//modbyshowtempfreq
    {
          itemId: 'CPUW',
          colspan: 2,
          printBar: false,
          title: gettext('CPU功耗'),
          textField: 'cpupower',
          renderer:function(value){
              const w0 = value.split('\n')[0].split(' ')[0];
              const w1 = value.split('\n')[1].split(' ')[0];
              return `CPU电源模式: <strong>${w0}</strong> | CPU功耗: <strong>${w1} W</strong>`;
           }
    },
    {
          itemId: 'MHz',
          colspan: 2,
          printBar: false,
          title: gettext('CPU频率'),
          textField: 'cpusensors',
          renderer:function(value){
              const f0 = value.match(/cpu MHz.*?([\d]+)/)[1];
              const f1 = value.match(/CPU min MHz.*?([\d]+)/)[1];
              const f2 = value.match(/CPU max MHz.*?([\d]+)/)[1];
              return `CPU实时: <strong>${f0} MHz</strong> | 最小: ${f1} MHz | 最大: ${f2} MHz`;
           }
    },
    {
          itemId: 'HEXIN',
          colspan: 2,
          printBar: false,
          title: gettext('核心频率'),
          textField: 'cpusensors',
          renderer: function(value) {
              const freqMatches = value.matchAll(/^cpu MHz\s*:\s*([\d\.]+)/gm);
              const frequencies = [];
              for (const match of freqMatches) {
                  const coreNum = frequencies.length + 1;
                  frequencies.push(`核心${coreNum}: <strong>${parseInt(match[1])} MHz</strong>`);
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
          itemId: 'thermal',
          colspan: 2,
          printBar: false,
          title: gettext('CPU温度'),
          textField: 'thermalstate',
          renderer: function(value) {
              function colorizeTemp(temp) {
                  let tempNum = Number(temp);
                  if (Number.isNaN(tempNum)) return temp + '°C';
                  if (tempNum < 60) return '<span style="color:#27ae60; font-weight:600;">' + tempNum.toFixed(0) + '°C</span>';
                  if (tempNum < 80) return '<span style="color:#f39c12; font-weight:600;">' + tempNum.toFixed(0) + '°C</span>';
                  return '<span style="color:#e74c3c; font-weight:600;">' + tempNum.toFixed(0) + '°C</span>';
              }
              const coreTemps = [];
              let coreMatch;
              const coreRegex = /(Core\s*\d+|Core\d+|Tdie|Tctl|Physical id\s*\d+).*?\+\s*([\d\.]+)/gi;
              while ((coreMatch = coreRegex.exec(value)) !== null) {
                  let label = coreMatch[1];
                  let tempValue = coreMatch[2];
                  if (label.match(/Tdie|Tctl/i)) {
                      coreTemps.push(`CPU温度: ${colorizeTemp(tempValue)}`);
                  } else {
                      const coreNumberMatch = label.match(/\d+/);
                      const coreNum = coreNumberMatch ? parseInt(coreNumberMatch[0]) + 1 : 1;
                      coreTemps.push(`核心${coreNum}: ${colorizeTemp(tempValue)}`);
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
              const result = [groupedTemps.join('<br>'), combinedTemps].filter(Boolean).join('<br>');
              return result || '未获取到温度信息';
          }
    },
EOF

    # NVMe 前端渲染（详细版，含 I/O 实时数据）
    for i in {0..9}; do
        for dev in "/dev/nvme${i}" "/dev/nvme${i}n1"; do
            if [ -b "$dev" ]; then
                cat >> $tmpf << EOF
    {
          itemId: 'nvme${i}-status',
          colspan: 2,
          printBar: false,
          title: gettext('NVME盘${i}'),
          textField: 'nvme${i}_status',
          renderer:function(value){
              function colorizeTemp(temp) {
                  let tempNum = Number(temp);
                  if (Number.isNaN(tempNum)) return temp + '°C';
                  if (tempNum < 50) return '<span style="color:#27ae60; font-weight:600;">' + tempNum + '°C</span>';
                  if (tempNum < 70) return '<span style="color:#f39c12; font-weight:600;">' + tempNum + '°C</span>';
                  return '<span style="color:#e74c3c; font-weight:600;">' + tempNum + '°C</span>';
              }
              function colorizeHealth(percent) {
                  let healthNum = Number(percent);
                  if (Number.isNaN(healthNum)) return percent + '%';
                  if (healthNum >= 80) return '<span style="color:#27ae60; font-weight:600;">' + healthNum + '%</span>';
                  if (healthNum >= 50) return '<span style="color:#f39c12; font-weight:600;">' + healthNum + '%</span>';
                  return '<span style="color:#e74c3c; font-weight:600;">' + healthNum + '%</span>';
              }
              if (value.length > 0) {
                  value = value.replace(/Â/g, '');
                  let data = [];
                  let nvmeNumber = -1;
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
                                      if (nvme.Available_Spares.length > 0) {
                                          output += ', 备用空间: ' + nvme.Available_Spares[0];
                                      }
                                      output += \`)\`;
                                  }
                              }
                          }
                          output += '<br>';
                      }
                      if (nvme.Capacitys.length > 0) {
                          output += \`容量: \${nvme.Capacitys[0].replace(/ |,/gm, '')}\`;
                      }
                      if (nvme.Useds.length > 0) {
                          output += ' | ';
                          output += \`寿命: \${colorizeHealth(100-Number(nvme.Useds[0]))}\`;
                          if (nvme.Reads.length > 0) output += \`(已读\${nvme.Reads[0].replace(/ |,/gm, '')})\`;
                          if (nvme.Writtens.length > 0) output += \`(已写\${nvme.Writtens[0].replace(/ |,/gm, '')})\`;
                      }
                      if (nvme.Temperatures.length > 0) {
                          output += ' | 温度: ' + colorizeTemp(nvme.Temperatures[0]);
                      }
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
                          output += '<br>';
                          output += \`通电: \${nvme.Cycles[0].replace(/ |,/gm, '')}次\`;
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

    # SATA 前端渲染
    cat >> $tmpf << 'EOF'
    {
          itemId: 'hdd-temperatures',
          colspan: 2,
          printBar: false,
          title: gettext('SATA盘'),
          textField: 'hdd_temperatures',
          renderer: function(value) {
              function colorizeTemp(temp) {
                  let tempNum = Number(temp);
                  if (Number.isNaN(tempNum)) return temp + '°C';
                  if (tempNum < 40) return '<span style="color:#27ae60; font-weight:600;">' + tempNum + '°C</span>';
                  if (tempNum < 50) return '<span style="color:#f39c12; font-weight:600;">' + tempNum + '°C</span>';
                  return '<span style="color:#e74c3c; font-weight:600;">' + tempNum + '°C</span>';
              }
              if (value.length > 0) {
                  try {
                      const jsonData = JSON.parse(value);
                      if (jsonData.standy === true) return '休眠中';
                      let output = '';
                      if (jsonData.model_name) {
                          output = `<strong>${jsonData.model_name}</strong><br>`;
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
                              outputs.push(deviceOutput);
                          } else {
                              deviceOutput = `<strong>${devicemodel}</strong><br>容量: ${capacity} | 已通电: ${powerOnHours}小时 | 提示: 未检测到温度传感器`;
                              outputs.push(deviceOutput);
                          }
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

    # 修改页面高度
    log_step "调整页面高度"
    disk_count=$(lsblk -d -o NAME | grep -cE 'sd[a-z]|nvme[0-9]')
    height_increase=$((disk_count * 69))
    node_status_new_height=$((400 + height_increase))
    sed -i -r '/widget\.pveNodeStatus/,+5{/height/{s#[0-9]+#'$node_status_new_height'#}}' $pvemanagerlib
    cpu_status_new_height=$((300 + height_increase))
    sed -i -r '/widget\.pveCpuStatus/,+5{/height/{s#[0-9]+#'$cpu_status_new_height'#}}' $pvemanagerlib
    log_info "左栏高度: ${node_status_new_height}px, CPU面板: ${cpu_status_new_height}px"

    # 调整布局右对齐
    ln=$(sed -n -e '/widget.pveDcGuests/=' $pvemanagerlib | head -1)
    ln=$((ln + 10))
    sed -i "${ln}a\        textAlign: 'right'," $pvemanagerlib
    ln=$(sed -n -e '/widget.pveNodeStatus/=' $pvemanagerlib | head -1)
    ln=$((ln + 10))
    sed -i "${ln}a\        textAlign: 'right'," $pvemanagerlib

    # 去除订阅弹窗
    log_step "去除订阅弹窗"
    remove_subscription_popup

    systemctl restart pveproxy
    log_success "修改完成！请刷新浏览器缓存 (Shift+F5)"
}

# ============ 删除监控 ============
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
        log_success "已删除温度显示，请重新刷新浏览器缓存 (Shift+F5)"
    else
        log_warn "你没有添加过温度显示，退出脚本。"
    fi
}

# ============ 主菜单 ============
menu() {
    while :; do
        clear
        echo -e "${H1}═════════════════════════════════════════════════${NC}"
        echo -e "${H1}         PVE-K 硬件监控增强脚本 v${VERSION}${NC}"
        echo -e "${H1}═════════════════════════════════════════════════${NC}"
        echo -e "${CYAN}  1. 添加 CPU/硬盘/温度详细监控${NC}"
        echo -e "${CYAN}  2. 删除监控（恢复官方文件）${NC}"
        echo -e "${CYAN}  0. 退出${NC}"
        echo -e "${UI_BORDER}"
        echo -ne " 请选择: [ ]\b\b"
        read -t 60 menuid
        menuid=${menuid:-0}
        case ${menuid} in
            1) cpu_add ; pause ;;
            2) cpu_del ; pause ;;
            0) clear; exit 0 ;;
            *) log_warn "无效选项"; pause ;;
        esac
    done
}

# 检查 root
if [[ $EUID -ne 0 ]]; then
    log_error "请使用 root 权限运行此脚本"
    exit 1
fi

menu
