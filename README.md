# QWhaleMaiden

QWhaleMaiden 是基于 **DSH-pet 开源插件**与 **vlln/whale-girl 开源项目**二次开发的 macOS 桌面宠物。采用 Swift/AppKit + WKWebView，默认使用蓝鲸娘形象，提供本机 Agent 任务提醒和轻量专注工具。

**适用于 Apple 芯片 Mac（arm64），最低编译目标 macOS 13。Intel Mac 不在当前支持范围。** 当前版本：0.1.2-beta。

## 来源与致谢

- [PC2005-cloud/dsh-pet](https://github.com/PC2005-cloud/dsh-pet)：蓝鲸娘动画素材、动作分类及宿主事件处理参考；本项目保留 106 段动画并转换为 macOS 透明 HEVC MOV。
- [vlln/whale-girl](https://github.com/vlln/whale-girl)：桌宠产品与交互的二次开发来源、人物尺寸及布局参考。

这是独立桌面应用；Swift/AppKit 运行层和本地适配层在本项目中实现。上游许可证与版权声明见 [NOTICE.md](NOTICE.md) 和 [licenses](licenses/)。感谢原作者贡献。

## 功能

- 拖动、甩抛、弹跳、左右移动；按当前显示器可用区域自动计算边界。
- 随机动画、离线碎碎念、互动、睡眠与素材包。
- Agent 通知：Codex、WorkBuddy、Trae CN、WPS灵犀、DSH、千问办公QwenWorkCN（不是千问聊天客户端）。
- 番茄钟（默认 45 分钟）、休息和喝水提醒，提供提示音、动画与气泡。
- 手选城市天气、可选的 macOS 本地日历只读展示。

## 构建与运行

需要 Apple 芯片 Mac、Xcode Command Line Tools，以及构建图标时使用的 Python 3。运行 App 不需要 Python、Node 或 FFmpeg；DSH 插件使用宿主自带的 Node 运行环境。

```sh
./scripts/build.sh
open build/QWhaleMaiden.app
```

生成安装包：

```sh
./scripts/package-pkg.sh
```

产物位于 `dist/QWhaleMaiden-0.1.2-beta-macOS-arm64.pkg`，安装到 `/Applications/QWhaleMaiden.app`。当前脚本使用本地 ad-hoc 签名，未配置 Developer ID、公证或 PKG 发布签名。

## Agent 接入

在设置的「Agent 接入」页安装对应 Hook/插件；宿主如未加载，请在空闲时重启，并通过宿主正常信任界面允许。应用移动或从 build 切换到 /Applications 后，重新安装接入以刷新 helper 路径。

```sh
# 默认仅预览计划；加 --apply 安装，加 --remove --apply 撤销自己的条目。
"build/QWhaleMaiden.app/Contents/Helpers/starbud-event" setup --agent dsh
"build/QWhaleMaiden.app/Contents/Helpers/starbud-event" setup --agent qwenwork
```

| 来源 | 实现与边界 |
|---|---|
| Codex | 只读增量 JSONL，属于非官方格式；部分批准事件和云任务不保证覆盖。已知超大日志行可能暂停读取，仍待修复。 |
| WorkBuddy / Trae CN | Hook 接入；各宿主版本和 IDE/Solo 模式需分别验收。 |
| 灵犀 | 只读 rollout 日志，问答等待保持；非官方格式可能随升级变化。 |
| DSH | 独立 Cordis 会话事件桥接，不要求同时运行另一桌宠。 |
| 千问办公 | QwenWorkCN 自定义插件 Hook；不同引擎的事件能力可能不同。 |

DSH/千问办公已通过隔离插件与原生事件链路测试；真实宿主完整派发、权限恢复和所有模式仍需验证。点击通知当前打开对应应用，不承诺精确定位会话。豆包工作和 ZCode 尚未实现。

## 数据与隐私

运行数据、设置、用户素材包和轮转技术日志存放在用户的 `~/Library/Application Support/QWhaleMaiden/v1`。首次使用新名称会从旧版本只读迁移状态与素材包，保留旧数据，不迁移日志。日志最多约 8 MiB，记录技术诊断，不记录 Agent 对话正文、工具参数或个人日历内容。

日历权限由用户主动启用，不写日程。天气查询使用 Open-Meteo，会发送用户选择的城市坐标；需联网。仓库不包含开发者个人状态、账号配置、凭据、日志、调研解包文件、临时目录或构建产物。

内部 `starbud-event` helper、兼容环境变量及 Bundle ID 暂保留旧标识，便于已有集成升级；产品名、App 名和新数据目录均为 QWhaleMaiden。

## 验证

```sh
./scripts/test-core.sh
./scripts/test-motion.sh
./scripts/test-assets.sh
python3 scripts/test-phase2.py
python3 scripts/test-motion-runtime.py
```

GUI 集成测试使用隔离数据目录并在结束后退出，不读取真实 Agent 会话或申请个人日历权限。模拟事件与几何测试不能替代真实外接屏、物理触控板和宿主模式验收。

## 许可

本项目代码按 MIT 许可开源。上游代码与素材保留各自的 MIT 版权声明，详见 [NOTICE.md](NOTICE.md)。
