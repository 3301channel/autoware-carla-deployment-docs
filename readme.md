# 部署文档

在ununtu24.04直接运行./setup_autoware_2404.sh即可安装autoware（carla需要单独安装）





# Autoware 2.0.0 部署

> 平台：Ubuntu 24.04.5 LTS (noble) + ROS 2 Jazzy
> 目标版本：**Autoware Universe 0.53.1 + Autoware Core 1.10.0**（即 `autoware` 元仓库 tag **2.0.0** 官方锁定组合）
> 编译方式：源码编译，**启用 CUDA 13.0 + TensorRT**

---

## 0. 版本

| 组件 | 版本 | 来源 |
|---|---|---|
| OS | Ubuntu 24.04.5 LTS (noble) | 系统自带 |
| ROS 2 | Jazzy | 清华镜像 `ros2/ubuntu` |
| Autoware Universe | **0.53.1** | GitHub `autowarefoundation/autoware_universe` |
| Autoware Core | **1.10.0** | GitHub `autowarefoundation/autoware_core` |
| Autoware Launch | 0.53.0 | GitHub |
| CUDA Toolkit | **13.0**（`cuda_13.0.r13.0/compiler.36424714_0`） | NVIDIA 官方源 ubuntu2404 |
| TensorRT | **10.13.3.9-1+cuda13.0** | NVIDIA 官方源 |
| NVIDIA 驱动 | **620.70.06**（保持原样，未改动） | `nvidia-dkms-open` 已有 |
| Agnocast | 2.4.1（用户态）+ DKMS 内核模块 | apt / DKMS |
| acados | `/opt/acados`（`libacados.so`、`libblasfeo.so`） | 源码编译（ansible） |

**硬件基线**：AMD64、28 核、62 GB 内存、1.8 TB 磁盘、RTX 4000 Ada Generation。

---

## 1. 阶段一：清理旧环境残留

### 1.1 清理组件

最初的排查命令是：

```bash
dpkg -l | grep -Ei 'ros2|ros-|autoware|cuda|nvinfer|tensorrt|nvidia' | grep -v '^ii'
```

`grep -v '^ii'` 把**所有已安装包（ii）都过滤掉了**，只留下 1 条 `rc`，因此误判为"已卸载只剩残留"。实际情况是：

- CUDA **12.8** 与 **12.0** 两套 deb 包**同时处于已安装状态**
- TensorRT 11.4 / 10.16 全套已安装
- `ros2-apt-source`、`ros-build-essential`、`python3-catkin-pkg`、`python3-colcon-*` 已安装

> 教训：检查"是否已安装"应直接 `dpkg -l | grep -Ei '...'`，不要过滤 `ii`；`grep -v '^ii'` 只用于查看 `rc` 等残留状态。

### 1.2  apt purge

先模拟确认影响面（不波及驱动/内核/桌面）：

```bash
export LC_ALL=C        # 否则中文 locale 下 grep 'Purg'/'Remv' 匹配不到
apt-get -s purge $CUDA_PKGS $TRT_PKGS $ROS_PKGS | grep -E '^(Purg|Remv)' | grep -Ei 'nvidia-gl|nvidia-dkms|xorg-video|desktop'
```

清理脚本：`/home/cn/cleanup_ros_cuda_trt.sh`

```bash
sudo bash /home/cn/cleanup_ros_cuda_trt.sh 2>&1 | tee /home/cn/cleanup.log
```

脚本包含 7 步：
1. `apt purge` CUDA 12.8（NVIDIA 源）+ CUDA 12.0（Ubuntu 源）共 80 余包
2. `apt purge` TensorRT 全部（`libnvinfer10/11`、`libnvonnxparsers*`、`tensorrt-dev` 等）
3. `apt purge` ROS 相关（`ros2-apt-source`、`ros-build-essential`、`python3-catkin-pkg*`、`python3-colcon-*`）
4. `dpkg --purge` 清 `rc` 残留（`libnvidia-compute-565`、`python3-roslaunch`）
5. `apt-get autoremove --purge`
6. 删除无包归属文件（`/usr/lib/nvidia-cuda-toolkit`、`/usr/share/doc/cuda-*`、`/usr/include/{cub,thrust,nv,nvtx3}`）
7. `ldconfig` + 核对清单

**结果**：共卸载 **148 个包**；`/usr/include`、`/usr/lib` 的 CUDA 残留清零；**显卡驱动完好**。

### 1.3 保留

| 文件/包 | 原因 |
|---|---|
| `libcuda.so.*`、`libcudadebugger.so.*`、`libnvidia-*` | NVIDIA 驱动用户态组件，删了会黑屏 |
| `libnvme*.so` | NVMe 存储库，名字像但不是 NVIDIA |
| `libcups*`、`libcurl*`、`libcue*` | 系统库，名字像但不是 CUDA |

### 1.4 收尾

`~/.bashrc` 中删除 ROS/Autoware 遗留环境变量（保留 ccache 相关）：

```bash
# 删除
# >>> fishros initialize >>>
# <<< fishros initialize <<<
export RMW_IMPLEMENTATION=rmw_cyclonedds_cpp
export CMAKE_PREFIX_PATH="/opt/acados:${CMAKE_PREFIX_PATH}"
export ACADOS_SOURCE_DIR="/opt/acados"
export LD_LIBRARY_PATH="/opt/acados/lib:${LD_LIBRARY_PATH}"
export ROSDISTRO_INDEX_URL=https://mirrors.tuna.tsinghua.edu.cn/rosdistro/index-v4.yaml

# 保留
export CCACHE_DIR="$HOME/.ccache"
export CC="/usr/lib/ccache/gcc"
export CXX="/usr/lib/ccache/g++"
```

---

## 2. 阶段二：安装 ROS 2 Jazzy

### 2.1 环境约束

| 地址 | 连通性 | 影响 |
|---|---|---|
| `raw.githubusercontent.com` | ❌ 000 | 无法用官方 `ros2-apt-source.deb` 与默认 rosdep 规则 |
| `packages.ros.org` | ⚠️ 时通时断 | 不宜作为唯一源 |
| `mirrors.tuna.tsinghua.edu.cn` | ✅ 200 | 选为 ROS 2 与 rosdistro 镜像 |
| `github.com` | ✅ 200（较慢） | 可拉源码 |
| `gitlab.com/.../raw/...` | ❌ 403 | Autoware CUDA 角色会踩坑 |
| `huggingface.co` | ❌ 000 | Autoware ML 模型下载失败 |
| `hf-mirror.com` | ✅ 200 | ML 模型备用镜像 |
| `autoware-files.s3.us-west-2.amazonaws.com` | ✅ 200 | demo 地图/rosbag 可用 |

### 2.2 签名密钥

`http://packages.ros.org/ros.key` 是 **2019 年旧钥（2025-06-01 已过期）**，不能用于 Jazzy。正确来源是 rosdistro 仓库内的 `ros.key`（有效期至 2030）：

```bash
KEYRING=/usr/share/keyrings/ros-archive-keyring.gpg
curl -fsSL https://mirrors.tuna.tsinghua.edu.cn/rosdistro/ros.key | gpg --dearmor --yes -o "$KEYRING"
chmod 644 "$KEYRING"
```

> 指纹：`C1CF6E31E6BADE8868B172B4F42ED6FBAB17C654`（RSA4096，Open Robotics）

### 2.3 apt 源（deb822 格式）

`/etc/apt/sources.list.d/ros2.sources`：

```
Types: deb
URIs: https://mirrors.tuna.tsinghua.edu.cn/ros2/ubuntu
Suites: noble
Components: main
Architectures: amd64
Signed-By: /usr/share/keyrings/ros-archive-keyring.gpg
```

### 2.4 安装与验证

```bash
sudo apt-get update
sudo apt-get install -y ros-jazzy-desktop ros-dev-tools
```

**结果**：381 个 `ros-jazzy-*` 包安装成功；`ros2`/`rviz2`/`colcon`/`rosdep 0.27.0` 就位；端到端验证通过（`talker`/`listener` 收发 `Hello World`）。

### 2.5 rosdep 初始化

新版 `rosdep init` 会从 GitHub 下载规则清单并失败，因此手工写规则文件（`/etc/ros/rosdep/sources.list.d/20-default.list`，root 需先建目录）：

```
yaml https://mirrors.tuna.tsinghua.edu.cn/rosdistro/rosdep/osx-homebrew.yaml osx
yaml https://mirrors.tuna.tsinghua.edu.cn/rosdistro/rosdep/base.yaml
yaml https://mirrors.tuna.tsinghua.edu.cn/rosdistro/rosdep/python.yaml
yaml https://mirrors.tuna.tsinghua.edu.cn/rosdistro/rosdep/ruby.yaml
```

```bash
sudo mkdir -p /etc/ros/rosdep/sources.list.d
# 写入上述内容后
ROSDISTRO_INDEX_URL=https://mirrors.tuna.tsinghua.edu.cn/rosdistro/index-v4.yaml rosdep update
```

> 注意：原始文件还包含 `gbpdistro .../releases/fuerte.yaml fuerte`，该条目属于 **ROS1 已停止维护的 Fuerte**，下载会 `Connection reset` 并让 `rosdep update` 返回 1。**删除该行**后退出码为 0。

### 2.6 `~/.bashrc` 

```bash
# ROS 2 jazzy
source /opt/ros/jazzy/setup.bash
source /usr/share/colcon_argcomplete/hook/colcon-argcomplete.bash
export ROSDISTRO_INDEX_URL=https://mirrors.tuna.tsinghua.edu.cn/rosdistro/index-v4.yaml
```

---

## 3. 阶段三：Autoware 

### 3.1 用元仓库锁定版本（推荐）

`autowarefoundation/autoware` 的 tag **2.0.0** 中 `repositories/autoware.repos` 明确锁定：

```yaml
core/autoware_core:
  version: 1.10.0
universe/autoware_universe:
  version: 0.53.1
launcher/autoware_launch:
  version: 0.53.0
core/agnocast:
  version: 2.4.1
```

### 3.2 克隆与导入

```bash
mkdir -p ~/autoware && cd ~/autoware
git clone --depth 1 -b 2.0.0 https://github.com/autowarefoundation/autoware.git .
mkdir -p src
vcs import src < repositories/autoware.repos
```

> 网络提示：`autoware_universe` 仓库较大（约 500 MB），直连 GitHub 约 80 KB/s，容易因 DNS 抖动失败。
> 可用加速地址重拉后改回官方 remote：
> ```bash
> git clone --depth 1 -b 0.53.1 https://ghfast.top/https://github.com/autowarefoundation/autoware_universe.git autoware_universe
> git -C autoware_universe remote set-url origin https://github.com/autowarefoundation/autoware_universe.git
> ```

**结果**：30 个仓库、`src/` 约 991 MB、502 个 ROS 包（`package.xml` 计数）。
校验：

```bash
git -C src/universe/autoware_universe describe --tags   # 0.53.1
git -C src/core/autoware_core describe --tags           # 1.10.0
```

---

## 4. 阶段四：ansible

### 4.1 官方方式

Autoware 2.0.0 的环境配置不再用 `setup-dev-env.sh`，而是直接跑 playbook：

```bash
sudo apt-get install -y ansible
ansible-galaxy collection install --force ./ansible -p /home/cn/autoware/collections
export ANSIBLE_COLLECTIONS_PATH=/home/cn/autoware/collections

sudo -E ansible-playbook ansible/playbooks/install_dev_env.yaml \
  -e cuda_install_drivers=false \
  --skip-tags ros2,ros2_dev_tools,artifacts
```

### 4.2 参数

| 参数 | 原因 |
|---|---|
| `-e cuda_install_drivers=false` | playbook 里 cuda 角色默认 `cuda_install_drivers: true`，会安装 `cuda-drivers` **覆盖现有 620.70.06 驱动** |
| `--skip-tags ros2,ros2_dev_tools` | 这两个角色会从 `packages.ros.org` 拉 `ros2-apt-source` 并重装 ROS；本地 ROS 已通过清华镜像装好，跳过更稳 |
| `--skip-tags artifacts` | 该角色从 `huggingface.co` 下载 ML 模型，本机不可达 |

### 4.3 playbook

```
version_lock → ros2 → ros2_dev_tools → rmw_implementation → build_tools
→ agnocast → dev_tools → qt5ct_setup → acados → geographiclib
→ cuda(13.0) → tensorrt(10.13.x) → spconv → artifacts → demo_artifacts
```

### 4.4 安装

| 组件 | 结果 |
|---|---|
| CUDA 13.0 | `/usr/local/cuda-13.0`，`nvcc` 可用 |
| TensorRT | 7 个包，`10.13.3.9-1+cuda13.0` |
| Agnocast | `agnocast-kmod-v2.4.1`、`agnocast-heaphook-v2.4.1`（DKMS） |
| acados | `/opt/acados`（`libacados.so`、`libblasfeo.so`） |
| RMW | `rmw_cyclonedds_cpp` 已装 |
| spconv | **跳过**（见 §6.2） |
| rosdep | `All required rosdeps installed successfully` |

---

## 5. 阶段五：编译

### 5.1  `~/autoware/build.sh`

```bash
#!/usr/bin/env bash
set -o pipefail
cd /home/cn/autoware || exit 1
# 关键：PATH 中不能有 ~/.local/bin（内含 uv 装的 python3.12）
export PATH=/usr/local/cuda/bin:/usr/bin:/bin:/usr/sbin:/sbin
export CCACHE_DIR=${CCACHE_DIR:-$HOME/.ccache}
export CCACHE_MAXSIZE=20G

set +u
source /opt/ros/jazzy/setup.bash      # setup.bash 引用未定义变量，必须临时关闭 set -u
set -u

colcon build \
  --symlink-install \
  --parallel-workers 16 \
  --event-handlers console_cohesion+ \
  --cmake-args \
    -DCMAKE_BUILD_TYPE=Release \
    -DBUILD_TESTING=OFF \
    -DPython3_EXECUTABLE=/usr/bin/python3 \
    -DCMAKE_C_COMPILER_LAUNCHER=ccache \
    -DCMAKE_CXX_COMPILER_LAUNCHER=ccache \
    -DCMAKE_CUDA_COMPILER_LAUNCHER=ccache \
    -DCMAKE_EXPORT_COMPILE_COMMANDS=ON \
    -DCMAKE_DISABLE_FIND_PACKAGE_spconv=ON \
    -DCMAKE_DISABLE_FIND_PACKAGE_cumm=ON \
    -DCMAKE_PROJECT_INCLUDE=/home/cn/autoware/cmake_preload.cmake
```

### 5.2 结果

| 指标 | 值 |
|---|---|
| 编译包数 | **502 / 502，退出码 0** |
| 耗时 | 21 min 05 s（增量续编；首次全量累计约 50 min） |
| 产物 | `install/` 485 MB、`build/` 3.8 GB |
| autoware 包（`ros2 pkg list`） | **370 个** |
| CUDA 目标文件 | **50 个** `*generated*.cu.o` |

### 5.3 测试

```bash
ros2 launch autoware_launch planning_simulator.launch.xml \
  map_path:=$HOME/autoware_data/maps/sample-map-planning rviz:=false
```

结果：**0 进程崩溃**、**30 个节点/组件**运行、**110 个话题**发布。日志中的 ERROR 均为 `diagnostic_graph_aggregator` 的速率检查（未设初始位姿/目标时的正常状态）。



---

## 6. 使用方法

### 6.1 环境

`~/.bashrc` 末尾（**顺序必须是先 ROS 后 Autoware**）：

```bash
# ROS 2 jazzy
source /opt/ros/jazzy/setup.bash
source /usr/share/colcon_argcomplete/hook/colcon-argcomplete.bash
export ROSDISTRO_INDEX_URL=https://mirrors.tuna.tsinghua.edu.cn/rosdistro/index-v4.yaml

# Autoware 2.0.0
if [ -f /home/cn/autoware/install/setup.bash ]; then
    source /home/cn/autoware/install/setup.bash
fi
```

> 若在**修改前**就打开的终端里执行，会出现 `Package 'autoware_launch' not found`，`source ~/.bashrc` 即可。

### 6.2 启动仿真

```bash
ros2 launch autoware_launch planning_simulator.launch.xml \
  map_path:=$HOME/autoware_data/maps/sample-map-planning
```

RViz 中的操作顺序：

1. 等 20–30 秒，面板显示 `WaitingForRoute`
2. `2D Pose Estimate` → 设定初始位姿（状态变 `WaitingForEngage`）
3. `2D Goal Pose` → 设定目标（生成路线）
4. 点 `AUTO` 进入自动驾驶
5. 车辆开始沿轨迹行驶

### 6.3 验证命令

```bash
ros2 pkg prefix autoware_launch          # /home/cn/autoware/install/autoware_launch
ros2 pkg list | grep -c autoware_        # 370
ros2 node list | wc -l                   # 启动后 50-60
ros2 topic list | wc -l                  # 启动后约 110
ros2 topic hz /localization/kinematic_state
```

### 6.4 重新编译（增量）

```bash
bash ~/autoware/build.sh 2>&1 | tee -a ~/autoware/build.log
```

### 6.5 关于"图像识别结果可视化"

- `planning_simulator` **没有相机**，用 `autoware_dummy_perception_publisher` 造假目标，`ros2 topic list | grep -i image` 为 **0**
- `RecognitionResultOnImage` 这个名字属于 **Autoware.AI 1.x**，在当前版本全文搜索无匹配；RViz/rqt 的 Image 面板标题只是**话题名**，显示 `No Image` 表示该话题无发布者
- 当前版本正确话题：
  - 原始图像：`/sensing/camera/<相机名>/image_raw`（或 `/image_rect_color`、`/image_raw/compressed`）
  - 交通灯 ROI 可视化：`/<roi_visualizer 命名空间>/output/image`
- 想看到图像，需改用带相机的数据源：

```bash
# 终端 1
ros2 launch autoware_launch logging_simulator.launch.xml \
  map_path:=$HOME/autoware_data/maps/sample-map-planning \
  vehicle_model:=sample_vehicle sensor_model:=sample_sensor_kit

# 终端 2（需先下载 demo rosbag）
ros2 bag play $HOME/autoware_data/recordings/sample-rosbag

# 终端 3
ros2 run rqt_image_view rqt_image_view
```

---

## 7. 已知限制与待办

| 项目 | 状态 | 说明 / 处理方式 |
|---|---|---|
| **spconv** | 未安装 | CUDA 13 上游无 `cu130` 发行版，官方 24.04 同样跳过；`tensorrt_plugins`/`bevfusion`/`vad`/`ptv3` 的 spconv 加速分支不编译 |
| **ML 模型** | 未下载 | `centerpoint`、`yolox`、`traffic_light_classifier` 等需要模型；用 `HF_ENDPOINT=https://hf-mirror.com` 下载，**必须显式指定目录**（默认会写到 `/root/autoware_data`） |
| **demo rosbag** | 未下载 | `sample-rosbag.zip`（约 5 GB），用于 `logging_simulator` 与图像链路验证 |
| **agnocast DKMS** | 待修正 | `dkms status` 显示 `agnocast/2.3.5: broken`、`agnocast/2.4.1: built`（未 install），`/lib/modules/.../agnocast.ko.zst` 仍是旧 2.3.5（`modinfo` version 2.3.5），与用户态 2.4.1 不匹配。修复：<br>`sudo dkms remove agnocast/2.3.5 --all`<br>`sudo dkms install agnocast/2.4.1`<br>`sudo depmod -a`<br>校验 `modinfo agnocast \| grep version` 为 2.4.1 |
| demo 地图 | ✅ 已下载 | `~/autoware_data/maps/sample-map-planning`（16 MB，含 lanelet2 + pcd） |

---

## 8. 文件与脚本清单

| 路径 | 作用 | 是否还需保留 |
|---|---|---|
| `~/autoware/` | Autoware 工作区（`src/` 991 MB，`build/` 3.8 GB，`install/` 485 MB） | ✅ 必须 |
| `~/autoware/build.sh` | 编译脚本（含全部 workaround 参数） | ✅ 必须 |
| `~/autoware/cmake_preload.cmake` | 绕过 tinyxml2_vendor bug | ✅ 必须（重编需要） |
| `~/autoware/setup_env_sudo.sh` | 环境依赖安装（ansible + 三个保护参数） | 可选 |
| `~/autoware/fix_spconv.sh` | 清理坏 spconv 包（最终未使用，改用 CMake 参数） | 可删 |
| `~/autoware/{build,setup_env,vcs_import,clone_universe}.log` | 部署日志 | 可选 |
| `~/autoware_data/maps/sample-map-planning` | demo 地图 | ✅ 必须 |
| `/home/cn/cleanup_ros_cuda_trt.sh` + `cleanup.log` | 阶段一清理 | 可删 |
| `/home/cn/install_ros2_jazzy.sh` + `ros2_install.log` | 阶段二安装 | 可删 |
| `/home/cn/fix_rosdep.sh` + `rosdep_fix.log` | rosdep 修复 | 可删 |
| `~/.bashrc.bak.*` | 修改前的 bashrc 备份 | 可删 |
| `CARLA安装文档.md` | CARLA 0.9.15/0.9.16 下载地址、完整性校验、解压启动、排错 | ✅ 保留 |

## 9. 常见报错与处理

### 9.1 acados 克隆失败：`gnutls_handshake() failed`

**现象**（`install_dev_env` 在 acados 角色处中断）：

```
TASK [autoware.dev_env.acados : Clone acados repository (shallow) with submodules] ***
fatal: [localhost]: FAILED! => {"changed": false,
 "cmd": ["/usr/bin/git", "fetch", "--depth", "1", "--force", "origin",
         "+refs/tags/v0.5.3:refs/tags/v0.5.3"],
 "msg": "Failed to download remote objects and refs:  fatal: unable to access
         'https://github.com/acados/acados.git/':
         gnutls_handshake() failed: The TLS connection was non-properly terminated."}

PLAY RECAP *********************************************************************
localhost  : ok=61  changed=10  unreachable=0  failed=1  skipped=15  rescued=0  ignored=0

[FAIL] install_dev_env 失败，详见 /home/cn/autoware/deploy-20261111-164145.log
```

**原因**

不是 acados 或 playbook 的问题，而是 **GitHub 连接被中途掐断**（TLS 握手未完成）。报错里 `ok=61` 说明前面的 version_lock / ros2_dev_tools / build_tools / agnocast / dev_tools / qt5ct_setup 等角色都已成功，只是卡在唯一需要访问 GitHub 的一步。

**处理：切换 / 调整代理节点即可**

`ansible` 的 git 任务是 `become: true`，**以 root 身份执行**，所以用户态设的 `http_proxy` 不会生效，必须把代理配到 **root 的 git 全局配置**上。

```bash
# 1. 先确认本机代理监听的端口（示例：sing-box 监听 10808）
ss -lntp | grep -E '1080[0-9]|789[0-9]'
#   SOCKS5 端口 → socks5h://127.0.0.1:10808
#   HTTP   端口 → http://127.0.0.1:7890

# 2. 给 root 的 git 配代理
sudo git config --global http.proxy  socks5h://127.0.0.1:10808
sudo git config --global https.proxy socks5h://127.0.0.1:10808

# 3. 验证能否访问（能列出 tag 就说明通了）
sudo git ls-remote --tags https://github.com/acados/acados.git v0.5.3
```

代理就绪后，**只需重跑 acados 一个角色**，不必全流程重来：

```bash
cd /home/cn/autoware
sudo -E env \
  "ANSIBLE_COLLECTIONS_PATH=/home/cn/autoware/collections" \
  "LANG=C.UTF-8" "LC_ALL=C.UTF-8" \
  /usr/bin/ansible-playbook ansible/playbooks/install_dev_env.yaml \
    -e cuda_install_drivers=false \
    --tags acados
```

校验结果：

```bash
ls /opt/acados/lib/libacados.so        # 应存在
ls /opt/acados/lib/libblasfeo.so
ls /opt/acados/bin/t_renderer          # 可执行
```

确认无误后，把代理配置撤掉，避免影响后续国内镜像下载：

```bash
sudo git config --global --unset http.proxy
sudo git config --global --unset https.proxy
```

**备用方案 A：走 GitHub 加速镜像（无需代理）**

```bash
sudo git config --global url."https://ghfast.top/https://github.com/".insteadOf \
     "https://github.com/"
# 装完后撤回
sudo git config --global --unset url."https://ghfast.top/https://github.com/".insteadOf
```

**备用方案 B：`t_renderer` 单独下载失败时手工补**

acados 角色还会用 `get_url` 从 GitHub Releases 拉 `t_renderer`，同样可能被掐断：

```bash
sudo curl -L --retry 3 -o /opt/acados/bin/t_renderer \
  https://github.com/acados/tera_renderer/releases/download/v0.2.0/t_renderer-v0.2.0-linux-amd64
sudo chmod +x /opt/acados/bin/t_renderer
```

**本机实际状态说明**

2026-11-11 16:41 这次失败发生在**重跑**时：`/opt/acados/lib/` 下已有 `libacados.so`、`libblasfeo.so`、`libhpipm.so`，说明 acados 在 10:58 那次就已编译安装成功，本次仅因 `git fetch` 被掐断而中断。此类情况用代理重跑 `--tags acados` 即可收敛，不会重复编译。

**恢复全流程**

脚本是幂等的，代理调好后可直接再跑一遍：

```bash
bash ~/桌面/Autoware部署文档.md/setup_autoware_2404.sh
```

---

### 9.2 网络类报错的通用对照

本机实测的连通性与对应处理：

| 报错关键字 | 涉及地址 | 处理 |
|---|---|---|
| `gnutls_handshake() failed` / `TLS connection was non-properly terminated` | `github.com` | 换代理节点；或 `git config` 走 `ghfast.top` |
| `301 Moved Permanently` + `位置：未指定` | `carla-releases.s3.eu-west-3.amazonaws.com` | 该桶已废弃，改用 `downloads.carlasim.com`（见《CARLA安装文档.md》） |
| `Connection reset` / `Failed to connect` | `raw.githubusercontent.com`、`huggingface.co` | 走清华镜像 / `hf-mirror.com`；rosdep 用镜像规则 |
| `403 Forbidden` | `gitlab.com/.../raw/...` | 已在脚本中用本地 `file://` 源替换（Vulkan/EGL 描述文件） |
| `Failed to update apt cache` | Chrome / VS Code / josm 等无关源 | 脚本内 `apt_update_resilient` 自动临时禁用后重试 |

---

## 附：环境变量最终状态

```bash
ROS_DISTRO=jazzy
AMENT_PREFIX_PATH=/home/cn/autoware/install/...:/opt/ros/jazzy
ROSDISTRO_INDEX_URL=https://mirrors.tuna.tsinghua.edu.cn/rosdistro/index-v4.yaml
CCACHE_DIR=/home/cn/.ccache
CUDA_HOME=/usr/local/cuda            # PATH 由 /usr/local/cuda/bin 提供
```







# CARLA 安装与验证

> 平台：Ubuntu 24.04.5 LTS (noble) + NVIDIA RTX 4000 Ada / 驱动 620.70.06

---

## 1. 版本与官方大小

以下字节数由官方服务器 `content-length` / `content-range` 实测得到（2026-11-11）：

| 文件                           | 官方字节数        | 折算      |
| ------------------------------ | ----------------- | --------- |
| `CARLA_0.9.15.tar.gz`          | **8,386,636,048** | 7.81 GiB  |
| `AdditionalMaps_0.9.15.tar.gz` | 7,375,946,087     | 6.87 GiB  |
| `CARLA_0.9.16.tar.gz`          | **8,346,095,504** | 7.77 GiB  |
| `AdditionalMaps_0.9.16.tar.gz` | 14,818,817,800    | 13.80 GiB |

> 版本选择：
>
> - 做 **CARLA ↔ Autoware 联合仿真**：优先 0.9.15（生态适配更成熟）
> - 只用模拟器本身：0.9.16（含 NVIDIA Cosmos / NuRec 等新特性）
> - 两个版本的二进制都在 Ubuntu 20.04/22.04 下编译，24.04 上需补几个旧依赖（见 §7）

---

## 2. 下载

### 2.1 正确的地址（关键）

```bash
# ✅ 现行地址
https://downloads.carlasim.com/Linux/CARLA_0.9.15.tar.gz
https://downloads.carlasim.com/Linux/AdditionalMaps_0.9.15.tar.gz

# ❌ 已废弃（返回 301 且不带 Location，wget/curl 全部无法跟随）
https://carla-releases.s3.eu-west-3.amazonaws.com/Linux/CARLA_0.9.15.tar.gz
```

旧地址的实际表现：

```
--2026-11-11 11:20:12--  https://carla-releases.s3.eu-west-3.amazonaws.com/Linux/CARLA_0.9.15.tar.gz
已发出 HTTP 请求，正在等待回应... 301 Moved Permanently
位置：未指定
错误：重定向 (301) 但没有指定位置。
```

这不是网络问题，是**桶已停用**，换域名即可。

### 2.2 下载命令

```bash
cd ~

# 先清掉半截的旧文件，避免续传到坏数据上
ls -l CARLA_0.9.15.tar.gz 2>/dev/null && rm -f CARLA_0.9.15.tar.gz

# 方式一：aria2c 多线程（推荐，支持断点、自动重试）
sudo apt-get install -y aria2
aria2c -x16 -s16 -k1M https://downloads.carlasim.com/Linux/CARLA_0.9.15.tar.gz

# 方式二：wget
wget -c https://downloads.carlasim.com/Linux/CARLA_0.9.15.tar.gz
```

> 一次下载 7.8 GiB，网络不稳时务必用 `aria2c`，它比 `wget -c` 的续传更可靠。

---

## 3. 校验（必做）

**顺序不能省：先验大小 → 再验内容 → 最后解压。**

### 3.1 字节数必须精确相等

```bash
stat -c '%s' CARLA_0.9.15.tar.gz
# 期望：8386636048
```

### 3.2 整个压缩流完整性校验

```bash
# 遍历 8 GB 内容，返回 0 且无任何输出才算好包（约 1–2 分钟，不落盘）
tar -tzf CARLA_0.9.15.tar.gz > /dev/null && echo "包完整 ✅" || echo "包损坏 ❌"
```

等价命令：

```bash
gzip -t CARLA_0.9.15.tar.gz && echo "gzip CRC 通过 ✅"
```

### 3.3 正常包应能列出的开头条目

```
CHANGELOG
CarlaUE4/
CarlaUE4/Binaries/
CarlaUE4/Binaries/Linux/
CarlaUE4/Binaries/Linux/CarlaUE4-Linux-Shipping.sym
CarlaUE4/Binaries/Linux/CarlaUE4-Linux-Shipping
CarlaUE4/Binaries/Linux/CarlaUE4-Linux-Shipping.debug
CarlaUE4/Content/...
PythonAPI/...
```

只要 `tar` 中途报 `归档文件中异常的 EOF`、`invalid compressed data--format violated`，包就是坏的。

---

## 4. 实际踩过的坑：大小正确但内容损坏

某次 `~/CARLA_0.9.16.tar.gz` 的排查记录，可作为判断模板：

| 检查项                 | 结果                             | 说明                                                     |
| ---------------------- | -------------------------------- | -------------------------------------------------------- |
| 文件大小               | 8,346,095,504 字节               | 与官方 **完全一致**，不是没下完                          |
| gzip 文件头            | `1f8b 0800 ... 0003`             | 正常                                                     |
| `gzip -t`              | ❌ `invalid stored block lengths` | 在压缩流 **264,437,760 字节（252.2 MiB）** 处损坏        |
| `tar -tzf`             | ❌ 只列出 7 个条目                | 断在 `CarlaUE4-Linux-Shipping.debug`                     |
| 与官方同区段逐字节比对 | 252 MiB 之后 **99.6% 字节不同**  | 400 MiB / 2 GiB / 文件尾部抽样一致率仅 0.39%（随机巧合） |

**结论：不是截断，是「下完了但后半段是错误数据」**，常见诱因：

1. 用 `wget -c` / `aria2c -c` 在已损坏的文件上续传（越续越坏）
2. 从 U 盘/移动硬盘拷贝（`file` 曾显示该包带 FAT 文件系统痕迹）
3. 下载过程磁盘/内存写错误

这种损坏**无法局部修补**（坏区从 252 MiB 延伸到文件末尾），只能整包重下。

排查用命令：

```bash
# 1. gzip 头
xxd -l 32 CARLA_0.9.16.tar.gz

# 2. 精确到字节的损坏位置
python3 - <<'EOF'
import zlib
p='CARLA_0.9.16.tar.gz'
d=zlib.decompressobj(16+zlib.MAX_WBITS); off=0
with open(p,'rb') as f:
    while True:
        b=f.read(65536)
        if not b: break
        try: d.decompress(b)
        except Exception as e:
            print('损坏偏移:', off, f'({off/1024**2:.1f} MiB)', e); break
        off+=len(b)
EOF

# 3. 与官方同区段比对（先下载一段做参照）
curl -sL -r 209715200-419430399 -o /tmp/ref.bin \
  https://downloads.carlasim.com/Linux/CARLA_0.9.16.tar.gz
cmp /tmp/ref.bin <(dd if=CARLA_0.9.16.tar.gz bs=1M skip=200 count=200 2>/dev/null) | head
```

---

## 5. 解压

```bash
mkdir -p ~/carla
tar -xzf CARLA_0.9.15.tar.gz -C ~/carla

# 确认关键文件
ls ~/carla/CarlaUE4.sh
ls ~/carla/PythonAPI/carla/dist/
```

- 解压后约 **20–25 GB**，预留 30 GB 空间
- 解压过程无任何输出属正常（约 3–6 分钟）
- 建议保留压缩包直到确认能正常启动

---

## 6. 启动与验证

```bash
cd ~/carla

# 有桌面环境
./CarlaUE4.sh

# 无显示器（服务器 / 远程）
./CarlaUE4.sh -RenderOffScreen

# 常用参数
./CarlaUE4.sh -quality-level=Low -ResX=1280 -ResY=720
./CarlaUE4.sh -carla-rpc-port=2000 -nosound
```

Python 客户端验证：

```bash
python3 - <<'EOF'
import carla
c = carla.Client('localhost', 2000); c.set_timeout(10.0)
print('服务器版本:', c.get_server_version())
print('客户端版本:', c.get_client_version())
print('当前地图  :', c.get_world().get_map().name)
EOF
```

使用随包附带的 Python API（推荐，版本严格一致）：

```bash
cd ~/carla/PythonAPI/carla/dist
ls                        # carla-0.9.15-cp310-cp310-*.whl
python3.10 -m venv ~/carla-venv
source ~/carla-venv/bin/activate
pip install carla-0.9.15-cp310-*.whl
```

> wheel 是 `cp310`，Ubuntu 24.04 自带的 Python 3.12 **装不上**，需 conda/pyenv 单独建 3.10 环境。

---

## 7. 常见问题

| 现象                                                     | 原因               | 处理                                                         |
| -------------------------------------------------------- | ------------------ | ------------------------------------------------------------ |
| `301 Moved Permanently` + `位置：未指定`                 | 使用旧 S3 地址     | 换 `https://downloads.carlasim.com/Linux/...`                |
| 大小对但 `tar` 报 EOF / `invalid compressed data`        | 包内容损坏（§4）   | 删掉重下，别续传                                             |
| `error while loading shared libraries: libXinerama.so.1` | 24.04 精简了旧库   | `sudo apt install libxinerama1 libxerces-c-dev libfontconfig1` |
| 缺 `libssl.so.1.1`                                       | 22.04 时代的依赖   | 从 22.04 仓库取 `libssl1.1` 单独安装                         |
| `Vulkan` / `libvulkan.so.1` 报错                         | 未装 Vulkan 运行时 | `sudo apt install libvulkan1 vulkan-tools && vulkaninfo \| head` |
| `Failed to open Vulkan device`                           | 驱动/权限问题      | `nvidia-smi` 确认驱动正常；确认在图形会话内运行              |
| 启动黑屏或秒退                                           | 缺 GPU 上下文      | 改用 `-RenderOffScreen` 或 `-quality-level=Low`              |
| 端口 2000 被占用                                         | 上一个实例未退     | `./CarlaUE4.sh -carla-rpc-port=3000` 换端口                  |
| 解压后磁盘爆满                                           | 解压需 20–25 GB    | 先 `df -h` 确认根分区剩余 ≥ 30 GB                            |

---

## 8. 命令速查

```bash
# 下载
aria2c -x16 -s16 -k1M https://downloads.carlasim.com/Linux/CARLA_0.9.15.tar.gz

# 校验
stat -c '%s' CARLA_0.9.15.tar.gz          # 8386636048
tar -tzf CARLA_0.9.15.tar.gz > /dev/null && echo OK

# 解压
mkdir -p ~/carla && tar -xzf CARLA_0.9.15.tar.gz -C ~/carla

# 运行
cd ~/carla && ./CarlaUE4.sh -RenderOffScreen

# 清理
rm -f CARLA_0.9.15.tar.gz
```

> 与 Autoware 的联合仿真（`carla-autoware` 桥接、ROS 2 Jazzy 适配）另文说明，参见《Autoware部署文档.md》第 7 章「已知限制与待办」。
