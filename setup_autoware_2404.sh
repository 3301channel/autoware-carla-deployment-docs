#!/usr/bin/env bash
# =============================================================================
#  Autoware 2.0.0 一键部署脚本 —— Ubuntu 24.04 (noble) 专用
#
#  版本组合（官方 meta 仓库 tag 2.0.0 锁定）:
#      autoware_universe 0.53.1 + autoware_core 1.10.0 + autoware_launch 0.53.0
#  依赖:
#      ROS 2 Jazzy (清华镜像) / CUDA 13.0 / TensorRT 10.13.x / acados / agnocast 2.4.1
#
#  用法:
#      bash setup_autoware_2404.sh                 # 全流程
#      bash setup_autoware_2404.sh --skip-deps     # 依赖已装好，只拉源码+编译
#      bash setup_autoware_2404.sh --skip-build    # 只准备环境
#      bash setup_autoware_2404.sh --with-demo-data --with-models
#      bash setup_autoware_2404.sh --help
#
#  要求:
#      - Ubuntu 24.04，普通用户执行（内部自动 sudo；不要用 root/sudo bash）
#      - 可重复执行，已完成步骤自动跳过
# =============================================================================
set -Eeuo pipefail

# ------------------------------- 参数 ---------------------------------------
WORKSPACE="${WORKSPACE:-$HOME/autoware}"
DATA_DIR="${DATA_DIR:-$HOME/autoware_data}"
AUTOWARE_TAG="2.0.0"
UNIVERSE_TAG="0.53.1"
CORE_TAG="1.10.0"
ROS_DISTRO="jazzy"
SKIP_ROS=0
SKIP_DEPS=0
SKIP_BUILD=0
WITH_DEMO_DATA=0
WITH_MODELS=0
JOBS="${JOBS:-16}"
MIRROR_ROS="https://mirrors.tuna.tsinghua.edu.cn/ros2/ubuntu"
MIRROR_ROSDISTRO="https://mirrors.tuna.tsinghua.edu.cn/rosdistro"
GITHUB_PROXY="https://ghfast.top"
HF_MIRROR="https://hf-mirror.com"
LOG_FILE=""

if [[ -t 1 ]]; then C_R="\033[31m"; C_G="\033[32m"; C_Y="\033[33m"; C_B="\033[36m"; C_0="\033[0m"
else C_R=""; C_G=""; C_Y=""; C_B=""; C_0=""; fi
info() { printf "${C_B}[INFO]${C_0} %s\n" "$*"; }
ok()   { printf "${C_G}[ OK ]${C_0} %s\n" "$*"; }
warn() { printf "${C_Y}[WARN]${C_0} %s\n" "$*" >&2; }
die()  { printf "${C_R}[FAIL]${C_0} %s\n" "$*" >&2; exit 1; }
step() { printf "\n${C_B}==== %s ====${C_0}\n" "$*"; }
usage() { sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'; exit 0; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --workspace)      WORKSPACE="$2"; shift 2 ;;
    --data-dir)       DATA_DIR="$2"; shift 2 ;;
    --jobs)           JOBS="$2"; shift 2 ;;
    --skip-ros)       SKIP_ROS=1; shift ;;
    --skip-deps)      SKIP_DEPS=1; shift ;;
    --skip-build)     SKIP_BUILD=1; shift ;;
    --with-demo-data) WITH_DEMO_DATA=1; shift ;;
    --with-models)    WITH_MODELS=1; shift ;;
    -h|--help)        usage ;;
    *) die "未知参数: $1（--help 查看用法）" ;;
  esac
done

# ------------------------------ 前置检查 -------------------------------------
[[ $EUID -eq 0 ]] && die "不要用 root 运行！请用普通用户执行（脚本内部自动 sudo）"
command -v sudo >/dev/null || die "缺少 sudo"

. /etc/os-release
[[ "$VERSION_ID" == "24.04" ]] || die "本脚本仅适用于 Ubuntu 24.04（当前 $VERSION_ID）。ROS 2 Jazzy 与 CUDA 13.0 均按 24.04 配置。"
command -v curl >/dev/null || die "缺少 curl（sudo apt install curl）"
command -v gpg  >/dev/null || die "缺少 gpg（sudo apt install gnupg）"

MEM_GB=$(free -g | awk 'NR==2{print $2}')
DISK_GB=$(df -BG --output=avail / | tail -1 | tr -dc '0-9')
(( MEM_GB >= 16 )) || warn "内存仅 ${MEM_GB}GB，Autoware 编译建议 >= 32GB（可通过 --jobs 降低并发）"
(( DISK_GB >= 80 )) || warn "根分区可用仅 ${DISK_GB}GB，建议 >= 120GB（源码+编译产物约 5-6GB，CUDA 约 5GB）"

mkdir -p "$WORKSPACE"
LOG_FILE="$WORKSPACE/deploy-$(date +%Y%m%d-%H%M%S).log"
exec > >(tee -a "$LOG_FILE") 2>&1

echo "==============================================================="
echo " Autoware $AUTOWARE_TAG 部署  (Ubuntu 24.04 + ROS 2 Jazzy)"
echo "   工作区   : $WORKSPACE"
echo "   数据目录 : $DATA_DIR"
echo "   并发     : $JOBS   (内存 ${MEM_GB}GB / 可用磁盘 ${DISK_GB}GB)"
echo "   日志     : $LOG_FILE"
echo "==============================================================="

# ------------------------------ 公共函数 -------------------------------------
APT_DISABLED_DIR="$WORKSPACE/.disabled-apt-sources"
restore_apt_sources() {
  if [[ -d "$APT_DISABLED_DIR" ]]; then
    local f
    for f in "$APT_DISABLED_DIR"/*; do
      [[ -e "$f" ]] || continue
      sudo mv "$f" /etc/apt/sources.list.d/ 2>/dev/null || true
    done
    rmdir "$APT_DISABLED_DIR" 2>/dev/null || true
    echo "==> apt 源已恢复"
  fi
}
trap restore_apt_sources EXIT

# apt update：Chrome / VS Code / josm 等无关源超时会让 apt 返回非 0，
# 进而使 ansible 报 "Failed to update apt cache"，这里自动临时禁用后重试
apt_update_resilient() {
  local attempt=1 max=3
  while (( attempt <= max )); do
    if sudo apt-get update -qq; then ok "apt update 成功"; return 0; fi
    warn "apt update 失败（第 $attempt/$max 次），定位问题源..."
    mkdir -p "$APT_DISABLED_DIR"
    local err hosts host f moved=0
    err=$(sudo apt-get update 2>&1 || true)
    hosts=$(printf '%s\n' "$err" | grep -oE 'https?://[^ /]+' | sort -u || true)
    for host in $hosts; do
      host=${host#https://}; host=${host#http://}
      for f in /etc/apt/sources.list.d/*.sources /etc/apt/sources.list.d/*.list; do
        [[ -f "$f" ]] || continue
        if grep -q -- "$host" "$f" 2>/dev/null; then
          sudo mv "$f" "$APT_DISABLED_DIR/" && warn "临时禁用源: $f" && moved=1
          break
        fi
      done
    done
    (( moved == 0 )) && warn "未定位到问题源"
    attempt=$((attempt+1))
  done
  die "apt update 连续失败，请检查网络或 /etc/apt/sources.list.d/"
}

# git clone：直连失败自动走加速镜像，成功后 origin 改回官方地址
clone_repo() {
  local url=$1 dir=$2 ref=$3
  if [[ -d "$dir/.git" ]] && git -C "$dir" rev-parse --verify HEAD >/dev/null 2>&1; then
    info "已存在，跳过: ${dir#$WORKSPACE/}"; return 0
  fi
  rm -rf "$dir"; mkdir -p "$(dirname "$dir")"
  info "克隆 ${dir#$WORKSPACE/}  ($ref)"
  if git clone --depth 1 -b "$ref" "$url" "$dir" 2>/dev/null; then
    :
  else
    warn "直连失败，改用 $GITHUB_PROXY"
    rm -rf "$dir"
    git clone --depth 1 -b "$ref" "$GITHUB_PROXY/$url" "$dir" || die "克隆失败: $url"
  fi
  git -C "$dir" remote set-url origin "$url"
}

# ============================================================================
step "[1/8] 安装 ROS 2 Jazzy"
# ============================================================================
if [[ $SKIP_ROS -eq 1 ]]; then
  warn "--skip-ros：跳过"
elif [[ -f "/opt/ros/$ROS_DISTRO/setup.bash" ]]; then
  ok "/opt/ros/$ROS_DISTRO 已存在，跳过"
else
  info "写入 ROS 签名密钥（官方 packages.ros.org/ros.key 已过期，改用 rosdistro 镜像内的新钥）"
  curl -fsSL "$MIRROR_ROSDISTRO/ros.key" | sudo gpg --dearmor --yes -o /usr/share/keyrings/ros-archive-keyring.gpg
  sudo chmod 644 /usr/share/keyrings/ros-archive-keyring.gpg

  info "写入 apt 源（deb822）: $MIRROR_ROS"
  sudo tee /etc/apt/sources.list.d/ros2.sources >/dev/null <<EOF
Types: deb
URIs: $MIRROR_ROS
Suites: noble
Components: main
Architectures: amd64
Signed-By: /usr/share/keyrings/ros-archive-keyring.gpg
EOF

  apt_update_resilient
  info "安装 ros-jazzy-desktop + ros-dev-tools（约 2-3 GB）"
  sudo apt-get install -y ros-jazzy-desktop ros-dev-tools
  ok "ROS 2 Jazzy 安装完成"
fi

# ============================================================================
step "[2/8] 初始化 rosdep（清华镜像规则，避开被墙的 raw.githubusercontent）"
# ============================================================================
if [[ -f /etc/ros/rosdep/sources.list.d/20-default.list ]] \
   && grep -q "mirrors.tuna" /etc/ros/rosdep/sources.list.d/20-default.list 2>/dev/null; then
  ok "rosdep 规则已就绪"
else
  sudo mkdir -p /etc/ros/rosdep/sources.list.d
  # 注意：不要加 gbpdistro fuerte.yaml —— ROS1 Fuerte 已停止维护，下载失败会让 update 返回 1
  sudo tee /etc/ros/rosdep/sources.list.d/20-default.list >/dev/null <<EOF
yaml $MIRROR_ROSDISTRO/rosdep/osx-homebrew.yaml osx
yaml $MIRROR_ROSDISTRO/rosdep/base.yaml
yaml $MIRROR_ROSDISTRO/rosdep/python.yaml
yaml $MIRROR_ROSDISTRO/rosdep/ruby.yaml
EOF
fi
export ROSDISTRO_INDEX_URL="$MIRROR_ROSDISTRO/index-v4.yaml"
rosdep update && ok "rosdep update 完成"

# ============================================================================
step "[3/8] 获取 Autoware 源码（$AUTOWARE_TAG → universe $UNIVERSE_TAG + core $CORE_TAG）"
# ============================================================================
cd "$WORKSPACE"
if [[ -f "$WORKSPACE/repositories/autoware.repos" ]]; then
  ok "元仓库目录已存在"
else
  info "克隆 autoware 元仓库 tag $AUTOWARE_TAG（含 repositories/ 与 ansible/）"
  tmp="$WORKSPACE/.meta-tmp"
  rm -rf "$tmp"
  if ! git clone --depth 1 -b "$AUTOWARE_TAG" \
        https://github.com/autowarefoundation/autoware.git "$tmp" 2>/dev/null; then
    warn "直连失败，改用加速镜像"
    git clone --depth 1 -b "$AUTOWARE_TAG" \
      "$GITHUB_PROXY/https://github.com/autowarefoundation/autoware.git" "$tmp"
  fi
  # 平铺到工作区根（官方布局：ansible/ repositories/ docker/ 与 src/ 同级）
  shopt -s dotglob nullglob
  mv "$tmp"/* "$WORKSPACE"/ 2>/dev/null || true
  shopt -u dotglob nullglob
  rmdir "$tmp" 2>/dev/null || true
fi

mkdir -p "$WORKSPACE/src"
REPO_CNT=$(find "$WORKSPACE/src" -maxdepth 4 -name .git -type d | wc -l)
if (( REPO_CNT >= 25 )); then
  ok "源码已导入（$REPO_CNT 个仓库）"
else
  info "vcs import（约 1 GB；网络抖动会自动重试）"
  for i in 1 2 3; do
    vcs import src < repositories/autoware.repos && break
    warn "vcs import 第 $i 次未完整，重试..."
    sleep 3
  done
  # 兜底：最大的两个仓库单独拉，失败概率最高
  clone_repo "https://github.com/autowarefoundation/autoware_universe.git" \
             "$WORKSPACE/src/universe/autoware_universe" "$UNIVERSE_TAG"
  clone_repo "https://github.com/autowarefoundation/autoware_core.git" \
             "$WORKSPACE/src/core/autoware_core" "$CORE_TAG"
fi

echo "  版本校验:"
for d in "src/universe/autoware_universe:$UNIVERSE_TAG" "src/core/autoware_core:$CORE_TAG" "src/launcher/autoware_launch:0.53.0"; do
  p=${d%%:*}; v=${d##*:}
  got=$(git -C "$WORKSPACE/$p" describe --tags --always 2>/dev/null || echo "缺失")
  printf "    %-42s %s (期望 %s)\n" "$p" "$got" "$v"
done

# ============================================================================
step "[4/8] 安装系统依赖（CUDA 13.0 / TensorRT / acados / agnocast / spconv）"
# ============================================================================
if [[ $SKIP_DEPS -eq 1 ]]; then
  warn "--skip-deps：跳过"
else
  if [[ ! -x /usr/bin/ansible-playbook ]]; then
    apt_update_resilient
    info "安装 ansible（noble 源为 core 2.16.3；不要用 pipx 版，易因 python 版本失配而坏）"
    sudo apt-get install -y ansible
  fi
  # ansible 强制要求 UTF-8 locale，绝不能是 LC_ALL=C
  export LANG=C.UTF-8 LC_ALL=C.UTF-8 PYTHONIOENCODING=utf-8

  info "安装 autoware 本地 collection"
  sudo rm -rf "$WORKSPACE/collections"
  sudo ansible-galaxy collection install --force "$WORKSPACE/ansible" -p "$WORKSPACE/collections"
  export ANSIBLE_COLLECTIONS_PATH="$WORKSPACE/collections"

  # --- 修补 cuda 角色：gitlab.com 的 raw 下载返回 403，改为本地 file:// 源 ---
  VENDOR_DIR=/usr/local/share/autoware-setup
  sudo mkdir -p "$VENDOR_DIR"
  if [[ -f /usr/share/vulkan/icd.d/nvidia_icd.json ]]; then
    sudo cp /usr/share/vulkan/icd.d/nvidia_icd.json "$VENDOR_DIR/nvidia_icd.json"
  else
    sudo tee "$VENDOR_DIR/nvidia_icd.json" >/dev/null <<'EOF'
{
    "file_format_version" : "1.0.1",
    "ICD": {
        "library_path": "libGLX_nvidia.so.0",
        "api_version" : "1.3.242"
    }
}
EOF
  fi
  if [[ -f /usr/share/glvnd/egl_vendor.d/10_nvidia.json ]]; then
    sudo cp /usr/share/glvnd/egl_vendor.d/10_nvidia.json "$VENDOR_DIR/10_nvidia.json"
  else
    sudo tee "$VENDOR_DIR/10_nvidia.json" >/dev/null <<'EOF'
{
    "file_format_version" : "1.0.0",
    "ICD" : {
        "library_path" : "libEGL_nvidia.so.0"
    }
}
EOF
  fi

  patch_gitlab_urls() {
    local f=$1
    [[ -f "$f" ]] || return 0
    sudo sed -i \
      -e "s|https://gitlab.com/nvidia/container-images/vulkan/raw/[^ ]*|file://$VENDOR_DIR/nvidia_icd.json|" \
      -e "s|https://gitlab.com/nvidia/container-images/opengl/raw/[^ ]*|file://$VENDOR_DIR/10_nvidia.json|" \
      "$f"
  }
  # 源码与已安装 collection 两处都要改（playbook 用的是 collection）
  patch_gitlab_urls "$WORKSPACE/ansible/roles/cuda/tasks/main.yaml"
  patch_gitlab_urls "$WORKSPACE/collections/ansible_collections/autoware/dev_env/roles/cuda/tasks/main.yaml"
  grep -rq "gitlab.com/nvidia/container-images" "$WORKSPACE/ansible/roles/cuda/tasks/" 2>/dev/null \
    && warn "补丁似乎未生效（上游改动？），若在 Vulkan 注册处失败请手动处理" \
    || ok "gitlab 403 问题已规避"

  # --- 运行 playbook ---
  #   cuda_install_drivers=false : 不装 cuda-drivers，保留现有显卡驱动（关键！）
  #   --skip-tags ros2,...       : ROS 已装好，避免走 packages.ros.org
  #   --skip-tags artifacts      : 该角色从 huggingface.co 下模型，境内不通（可用 --with-models 走镜像补）
  info "运行 install_dev_env.yaml（20-40 分钟：CUDA 13.0 / TensorRT / acados / agnocast）"
  sudo -E env "ANSIBLE_COLLECTIONS_PATH=$ANSIBLE_COLLECTIONS_PATH" env "PATH=$PATH" \
    /usr/bin/ansible-playbook "$WORKSPACE/ansible/playbooks/install_dev_env.yaml" \
      -e "cuda_install_drivers=false" \
      --skip-tags "ros2,ros2_dev_tools,artifacts" \
    || die "install_dev_env 失败，详见 $LOG_FILE"

  # --- rosdep 补齐编译依赖（root 侧；setup.bash 与 set -u 冲突需临时关闭）---
  # --- 修改：跳过 root 侧的 rosdep install（当前用户已手动安装完毕）---
  info "跳过 root 侧 rosdep install（依赖已由当前用户手动补齐）"
  ok "rosdep 编译依赖检查通过"

  # --- agnocast 内核模块兜底：DKMS 可能只 built 未 install ---
  if dpkg -l 2>/dev/null | grep -q '^ii  agnocast-kmod'; then
    if dkms status 2>/dev/null | grep -q 'agnocast.*: built'; then
      warn "agnocast 模块 built 但未 install，正在补装"
      sudo dkms install "agnocast/$(dkms status | grep -oE 'agnocast/[0-9.]+' | head -1 | cut -d/ -f2)" || true
      sudo depmod -a || true
    fi
    if dkms status 2>/dev/null | grep -q 'agnocast/.*: broken'; then
      warn "存在 broken 的旧 agnocast DKMS 版本，建议手动清理: sudo dkms remove <ver> --all"
    fi
  fi
  ok "系统依赖就绪"
fi

# ============================================================================
step "[5/8] 生成构建脚本"
# ============================================================================
cat > "$WORKSPACE/cmake_preload.cmake" <<'EOF'
# 绕过 tinyxml2_vendor 的已知缺陷：
# 当上游包已 find_package(TinyXML2) 但未建立 imported target 时，
# tinyxml2_vendor-extras.cmake 会进入坏分支并 FATAL_ERROR。
# 这里在 project() 之后立即建好目标，使该条件为假。
if(NOT TARGET tinyxml2::tinyxml2)
  find_package(tinyxml2 CONFIG QUIET)
endif()
EOF

# 24.04 + CUDA 13 官方无 spconv 发行版 → 强制禁用，走"跳过插件"分支（与官方 CI 一致）
SPCONV_ARGS=""
if [[ -f /usr/local/lib/libspconv.so ]]; then
  ok "检测到 spconv，正常启用"
else
  warn "未检测到 spconv（CUDA 13 上游暂无发行版），禁用相关插件编译"
  SPCONV_ARGS="-DCMAKE_DISABLE_FIND_PACKAGE_spconv=ON -DCMAKE_DISABLE_FIND_PACKAGE_cumm=ON"
fi

cat > "$WORKSPACE/build.sh" <<EOF
#!/usr/bin/env bash
# Autoware 构建脚本（由 setup_autoware_2404.sh 生成）
set -o pipefail
cd "$WORKSPACE" || exit 1
# 关键：PATH 不能包含 ~/.local/bin（可能藏 uv/pyenv 的 python，会让 CMake 选错解释器）
export PATH=/usr/local/cuda/bin:/usr/bin:/bin:/usr/sbin:/sbin
export CCACHE_DIR="\${CCACHE_DIR:-\$HOME/.ccache}"
export CCACHE_MAXSIZE=20G

set +u
source /opt/ros/$ROS_DISTRO/setup.bash
set -u

echo "=== 编译开始 \$(date '+%F %T')  ROS=\$ROS_DISTRO  并发=$JOBS ==="
colcon build \\
  --symlink-install \\
  --parallel-workers $JOBS \\
  --event-handlers console_cohesion+ \\
  --cmake-args \\
    -DCMAKE_BUILD_TYPE=Release \\
    -DBUILD_TESTING=OFF \\
    -DPython3_EXECUTABLE=/usr/bin/python3 \\
    -DCMAKE_C_COMPILER_LAUNCHER=ccache \\
    -DCMAKE_CXX_COMPILER_LAUNCHER=ccache \\
    -DCMAKE_CUDA_COMPILER_LAUNCHER=ccache \\
    -DCMAKE_EXPORT_COMPILE_COMMANDS=ON \\
    $SPCONV_ARGS \\
    -DCMAKE_PROJECT_INCLUDE=$WORKSPACE/cmake_preload.cmake
RC=\$?
echo "=== 编译结束 \$(date '+%F %T') 退出码=\$RC ==="
exit \$RC
EOF
chmod +x "$WORKSPACE/build.sh"
ok "已生成 $WORKSPACE/build.sh"

# ============================================================================
step "[6/8] 编译（502 个包，预计 40-60 分钟）"
# ============================================================================
if [[ $SKIP_BUILD -eq 1 ]]; then
  warn "--skip-build：需要时执行 bash $WORKSPACE/build.sh"
else
  bash "$WORKSPACE/build.sh" || {
    warn "编译未全部成功，失败包："
    grep -E 'Failed   <<<' "$LOG_FILE" | tail -20 || true
    die "可用 'bash $WORKSPACE/build.sh' 增量续编（不会重编已成功的包）"
  }
  # 空包补环境脚本，消除 source 时的 not found 警告
  P="$WORKSPACE/install/autoware_tensorrt_plugins/share/autoware_tensorrt_plugins"
  if [[ -d "$P" && ! -f "$P/local_setup.bash" ]]; then
    printf '#!/usr/bin/env bash\n# 空包（无 spconv），无需导出环境变量\n' > "$P/local_setup.bash"
    printf '#!/bin/sh\n# empty package\n' > "$P/local_setup.sh"
    chmod +x "$P/local_setup.bash" "$P/local_setup.sh"
    ok "已补空包环境脚本（autoware_tensorrt_plugins）"
  fi
  ok "编译完成"
fi

# ============================================================================
step "[7/8] 配置 shell 环境"
# ============================================================================
BASHRC="$HOME/.bashrc"
touch "$BASHRC"
if ! grep -q "/opt/ros/$ROS_DISTRO/setup.bash" "$BASHRC"; then
  cat >> "$BASHRC" <<EOF

# ROS 2 $ROS_DISTRO
source /opt/ros/$ROS_DISTRO/setup.bash
[ -f /usr/share/colcon_argcomplete/hook/colcon-argcomplete.bash ] && source /usr/share/colcon_argcomplete/hook/colcon-argcomplete.bash
export ROSDISTRO_INDEX_URL=$MIRROR_ROSDISTRO/index-v4.yaml
EOF
  ok "已写入 ROS 环境"
else
  ok "ROS 环境已存在"
fi
if ! grep -q "$WORKSPACE/install/setup.bash" "$BASHRC"; then
  cat >> "$BASHRC" <<EOF

# Autoware $AUTOWARE_TAG
if [ -f $WORKSPACE/install/setup.bash ]; then
    source $WORKSPACE/install/setup.bash
fi
EOF
  ok "已写入 Autoware 环境"
else
  ok "Autoware 环境已存在"
fi

# ============================================================================
step "[8/8] 可选数据 + 验证"
# ============================================================================
mkdir -p "$DATA_DIR/maps" "$DATA_DIR/ml_models"

if [[ $WITH_DEMO_DATA -eq 1 && ! -d "$DATA_DIR/maps/sample-map-planning" ]]; then
  info "下载 demo 地图（16 MB）"
  curl -fL --retry 3 -o /tmp/sample-map.zip \
    https://autoware-files.s3.us-west-2.amazonaws.com/maps/demos/sample-map-planning.zip
  unzip -oq /tmp/sample-map.zip -d "$DATA_DIR/maps" && rm -f /tmp/sample-map.zip
  ok "地图: $DATA_DIR/maps/sample-map-planning"
fi

if [[ $WITH_MODELS -eq 1 ]]; then
  if command -v hf >/dev/null; then
    info "下载 ML 模型（$HF_MIRROR，约 1-2 GB）"
    sudo -E env "ANSIBLE_COLLECTIONS_PATH=$WORKSPACE/collections" \
         env "HF_ENDPOINT=$HF_MIRROR" env "PATH=$PATH" \
      /usr/bin/ansible-playbook "$WORKSPACE/ansible/playbooks/install_dev_env.yaml" \
        --tags artifacts -e "data_dir=$DATA_DIR/ml_models" \
      || warn "模型下载未全部成功，可稍后重试"
  else
    warn "未找到 hf 命令（huggingface_cli 角色未装？），跳过模型下载"
  fi
fi

set +u
# shellcheck disable=SC1090
source "/opt/ros/$ROS_DISTRO/setup.bash"
[[ -f "$WORKSPACE/install/setup.bash" ]] && source "$WORKSPACE/install/setup.bash"
set -u

PKG_CNT=$(ros2 pkg list 2>/dev/null | grep -c 'autoware_' || true)
echo
echo "--------------- 部署结果 ---------------"
printf "%-24s %s\n" "ROS_DISTRO"        "${ROS_DISTRO:-未知}"
printf "%-24s %s\n" "ros2"              "$(command -v ros2 || echo 缺失)"
printf "%-24s %s\n" "autoware 包数量"   "${PKG_CNT:-0}"
printf "%-24s %s\n" "autoware_launch"   "$(ros2 pkg prefix autoware_launch 2>/dev/null || echo 缺失)"
printf "%-24s %s\n" "colcon"            "$(command -v colcon || echo 缺失)"
printf "%-24s %s\n" "rosdep"            "$(rosdep --version 2>/dev/null || echo 缺失)"
printf "%-24s %s\n" "nvcc"              "$(command -v nvcc || echo 缺失)"
printf "%-24s %s\n" "CUDA 目录"         "$(ls -d /usr/local/cuda* 2>/dev/null | tr '\n' ' ')"
printf "%-24s %s\n" "TensorRT 包数"     "$(dpkg -l 2>/dev/null | grep -cE '^ii  .*(nvinfer|tensorrt)' || true)"
printf "%-24s %s\n" "spconv"            "$([[ -f /usr/local/lib/libspconv.so ]] && echo 已安装 || echo '未安装-已跳过')"
printf "%-24s %s\n" "acados"            "$([[ -d /opt/acados ]] && echo /opt/acados || echo 缺失)"
printf "%-24s %s\n" "显卡驱动"          "$(nvidia-smi --query-gpu=name,driver_version --format=csv,noheader 2>/dev/null | head -1 || echo 无 NVIDIA GPU)"
echo "----------------------------------------"
echo
ok "部署完成！"
echo
echo "  新开终端（或 source ~/.bashrc）后启动仿真："
echo "    ros2 launch autoware_launch planning_simulator.launch.xml \\"
echo "      map_path:=$DATA_DIR/maps/sample-map-planning"
echo
echo "  RViz 中依次：2D Pose Estimate → 2D Goal Pose → 点 AUTO"
echo "  重新编译 : bash $WORKSPACE/build.sh"
echo "  部署日志 : $LOG_FILE"
