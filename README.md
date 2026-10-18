# WhaleFloat

> **DSH 的 macOS 启动器** —— 一键起 GUI、挂了自动拉起来、插件装好、
> 顺带养了一只盯着余额的小鲸鱼。

![菜单](docs/images/menu.png)

它不是一个桌面挂件，而是一个把 DSH 跑起来并且跑稳的应用程序。
桌宠只是它的一张脸。

几个名字先对齐：**WhaleFloat** 是应用名，菜单栏那只小鱼是它的入口，
**浮窗**指屏幕上那个可拖动的小鲸鱼，**桌宠**说的就是它作为宠物的那一面，
标题栏和通知里显示的中文名是**小鲸鱼**。

---

## 一、它能做什么

### 启动 DSH GUI（核心）

**点菜单栏那只小鱼（左键）** 就能开 DSH，或用菜单里的「启动 DSH GUI」。

它是个**幂等开关**：

```
没在跑  → 冷启动：起 dsh web、抓认证 URL、打开浏览器
已在跑  → 只开页面：绝不碰那个进程
```

「已在跑」这条判断放在起脚本之前：读 `~/.dsh/web.url` 的缓存，
那文件存两行 —— URL 和写它的进程 PID。token 是每个进程新生成的、
事后取不回，所以必须拿 PID 跟端口上实际监听的进程比一遍，
对得上才敢用。毫秒级返回，不用起子进程。

别的情形交给随包内置的启动器脚本：

```
· 端口被别的程序占用 → 把原因弹给你，而不是默默失败
· 重复点击          → 忽略，不会起出两个实例
```

脚本随包发布，不依赖工作区路径 —— 换台机器或挪过目录也不会失效。

### 守护进程

```
装好后由 launchd 托管，配置为「仅在异常退出时拉起」：
  · 程序崩了        → 自动重启
  · 你主动退出      → 不重启（不然关不掉）

首次运行时程序自己把 launchd 配置装好，你不需要跑任何脚本。
```

另有一层**单实例守卫**（文件锁）：即便被 launchd 和手动启动同时拉起，
也只会活下来一个。

### 插件安装

随包携带**一个** DSH 侧的中介插件，首次运行时静默装好：

| 插件 | 作用 |
|---|---|
| `dsh-whalefloat-helper` | 等待提示 / 每轮消耗 / 系统通知，三合一 |

它原先拆成三个（wait-state / turn-usage / notify-bridge），后来合并 —— 
三者订阅的本就是**同一条 `session/event` 事件流**，分开要付三份订阅开销。

装好后自动注册进 DSH 的 web profile，不需要你手动改配置。
**升级时会自动摘掉旧的三个插件**，不会两套并存。

### 余额与消耗监控

```
· 余额       直连 api.deepseek.com（读 ~/.dsh 下的凭据）
· 峰谷价     纯本地算，带节假日表
· 每轮消耗   从插件采集的账本读，逐轮明细
· 折线图     最近 N 轮趋势，X 轴按「时辰」对齐
```

**这部分不依赖 DSH 运行时** —— DSH 没开也能看余额。

峰谷判断分三层降级：

```
系统日历（EventKit，判断「今天」）
  ↓ 拿不到
内置节假日表（2024–2026 官方快照）
  ↓ 也没有
周末兜底
```

### 桌面桌宠

```
单击  → 冒一下余额气泡
双击  → 摸摸头（压扁拉宽 + 音效）
拖动  → 换位置；靠近屏幕边缘自动吸附并翻转朝向
```

![余额气泡](docs/images/bubble-balance.png)

气泡有两种：**余额**（带峰谷标记）和**每轮消耗**（带 token 数与时刻）。

![消耗气泡](docs/images/bubble-turn.png)

角色素材需要自备（原因见「素材」一节）。

### 通知与跳转

```
DSH 回复完 → 推一条系统通知（标题「小鲸鱼」）
点通知本体 → 直接跳到 DSH 看那条对话
在通知里回复 → 文本被注入回对话（走 DSH 官方 followup API）
```

### 菜单结构

左键点图标直接开 DSH，**右键**才弹菜单。完整结构：

```
安装配套插件                        ⌥1
桌宠设置      ▸  显示桌宠
                 导入图片素材…
                 导入音效素材…
                 获取仓库素材…
高级设置      ▸  角色大小 100% / 50%
                 气泡停留 10s / 5s
                 气泡内显示峰谷字
                 气泡内显示时间
                 启用事件音效
                 拖到边缘时吸附
分析…                               ⌥2
────────────────────────
启动 DSH GUI              ⌥3
充值 / 查看用量…           ⌥4
────────────────────────
退出浮窗                  ⌥5
退出 DSH                  ⌥6
────────────────────────
卸载 WhaleFloat…
WhaleFloat <版本号>
```

用的是**系统 NSMenu**，不是自绘面板：点外面自动关、二级菜单、
勾选状态、深色模式下的材质都由 macOS 提供。

### 快捷键

菜单展开时可用：

| 键 | 动作 |
|---|---|
| ⌥1 | 安装配套插件 |
| ⌥2 | 分析 |
| ⌥3 | 启动 DSH GUI |
| ⌥4 | 充值 / 查看用量 |
| ⌥5 | 退出浮窗 |
| ⌥6 | 退出 DSH |

---

## 二、安装部署

### 方式一：手动（三步）

```bash
# 1. 下载 dmg（或从 Release 页面点下载）
curl -L -o /tmp/WhaleFloat.dmg \
  https://github.com/tigriyang/DeepSeek-Balance-Whale-Widget/releases/latest/download/WhaleFloat.dmg

# 2. 挂载并拷进应用程序目录
hdiutil attach /tmp/WhaleFloat.dmg -nobrowse
cp -R "/Volumes/小鲸鱼/WhaleFloat.app" /Applications/
hdiutil detach "/Volumes/小鲸鱼"

# 3. 启动（首次会自己装 launchd 自启）
open -a WhaleFloat
```

**或者更简单**：双击 dmg，把「小鲸鱼」拖进「应用程序」。

> 这个链接永远指向最新版：发版脚本会同时上传一份固定名 `WhaleFloat.dmg`。
> 想装某个特定版本，去 [Releases](../../releases) 页挑。

### ⚠️ 首次打开会被 Gatekeeper 拦

这个应用**没有 Apple 开发者证书**，双击会提示「无法验证开发者」。

**解决办法**：在「应用程序」里**右键点击 → 打开**，再点一次「打开」。
之后就不会再拦了。

（也可以去「系统设置 → 隐私与安全性」底部点「仍要打开」。）

### 方式二：交给 AI 全自动部署

把下面这段整段复制给任意**有文件读写和命令执行能力**的 AI（Claude Code / Cursor / DSH 等）：

````markdown
帮我在这台 macOS 上安装 WhaleFloat（DSH 的启动器应用），按以下步骤执行，
每步做完确认结果再继续，遇到问题停下来说明原因：

1. 下载最新安装包：
   curl -L -o /tmp/WhaleFloat.dmg \
     https://github.com/tigriyang/DeepSeek-Balance-Whale-Widget/releases/latest/download/WhaleFloat.dmg

2. 挂载：hdiutil attach /tmp/WhaleFloat.dmg -nobrowse
   记下挂载点（通常是 /Volumes/小鲸鱼）

3. 把 WhaleFloat.app 从挂载点复制到 /Applications/（已存在就替换）

4. 卸载镜像并清理：hdiutil detach <挂载点>; rm -f /tmp/WhaleFloat.dmg

5. 去掉隔离属性（否则会提示「无法验证开发者」）：
   xattr -dr com.apple.quarantine /Applications/WhaleFloat.app

6. 启动它：open -a WhaleFloat
   （首次运行它会自己安装 launchd 自启配置，并静默装好配套插件）

7. 验证：
   · ps -axo command= | grep WhaleFloat  → 应有进程
   · 菜单栏应出现一个小鱼图标
   · ls ~/Library/LaunchAgents/ai.dsh.whalefloat.plist → 应存在

8. 如果 DSH 尚未安装，提醒我，不要擅自安装。

注意：不要用 sudo（除了第 5 步可能需要的 xattr），全程在用户目录下操作。
````

### 卸载

```bash
bash uninstall.sh            # 清掉本体 + 自启 + 插件 + 设置 + 缓存，共 7 类痕迹
bash uninstall.sh --keep-data  # 想保留设置和导入的角色时才加参数
```

也可以从菜单里点「卸载 WhaleFloat…」。

### 命令行

```bash
open -a WhaleFloat --args --analysis   # 启动并直接打开用量窗口
/Applications/WhaleFloat.app/Contents/MacOS/WhaleFloat --quit   # 让在跑的那份退出
```

`--quit` 走的是正常的 terminate 流程，设置和窗口位置会被保存。

---

## 三、架构与 fork 关系

### 组成

```
WhaleFloat.app                Swift 6 + AppKit 原生程序
├── Main.swift            程序入口
├── SingleInstance.swift  文件锁守卫
├── App.swift             应用委托（生命周期、菜单动作、数据刷新）
├── FloatWindow.swift     浮窗
├── WhaleView.swift       角色 + 气泡的绘制与交互
├── Menu.swift            菜单构建（系统 NSMenu）
├── AppInfo.swift         常量与金额格式化
├── DSHLauncher.swift     启动器
├── ProcessManager.swift  进程管理
├── Data.swift            余额请求与峰谷判断
├── TurnCost.swift        账本读取
├── WaitState.swift       等待状态读取
├── NotifyBridge.swift    系统通知
├── PluginInstaller.swift 插件安装
├── HolidayCalendar.swift 节假日表
├── SystemHoliday.swift   系统日历（EventKit）
├── AnalysisWindow.swift  分析窗口
├── SparkChartView.swift  折线图
├── BubblePresenter.swift 气泡时序
├── BubbleShapeView.swift 气泡形状
└── TouchReaction.swift   摸摸头反应

外部：
└── dsh-whalefloat-helper  DSH 插件：等待状态 / 每轮消耗 / 系统通知
```

**为什么需要那个插件**：DSH 的事件只有它自己知道，
插件在 DSH 进程内监听后写成文件，本程序读文件 —— 两边解耦，
DSH 没开时程序照常工作（只是少了实时数据）。

### 数据流

```
余额     WhaleFloat ──直连──▶ api.deepseek.com     （不经 DSH）
峰谷     WhaleFloat ──本地计算──▶ 节假日表 / 系统日历
每轮消耗  DSH ──插件──▶ ~/.dsh/.whalefloat-usage.json ──▶ WhaleFloat
等待状态  DSH ──插件──▶ ~/.dsh/.whalefloat-wait.json  ──▶ WhaleFloat
通知      DSH ──插件──▶ ~/.dsh/.whalefloat-notify.json ──▶ 系统通知
回复      系统通知 ──▶ ~/.dsh/.whalefloat-reply.json ──▶ DSH（followup）
```

所有跨进程通信都是**文件**，没有 socket、没有 XPC —— 
调试时 `cat` 一下就看得见。

### 与上游的关系

**本仓库是 [MeteorNOX/DeepSeek-Balance-Whale-Widget](https://github.com/MeteorNOX/DeepSeek-Balance-Whale-Widget)
的 fork** —— 一次**移植**，不是重写。

| | 上游 | 本项目 |
|---|---|---|
| 形态 | DSH 网页插件 | 独立 macOS 程序 |
| 语言 | JavaScript | Swift + AppKit |
| idea / 交互设计 / 美术素材 | **原创** | **继承自上游** |
| 代码 | —— | 按 Swift 重写，无 JS 复用 |
| 账本格式 | —— | **保持兼容**，历史数据无需转换 |

**为什么保留 fork 关系**：角色立绘、音效、交互节奏都来自上游，
这是做这次移植的前提。用 fork 而不是另建仓库，是为了让这份继承
关系在 GitHub 上始终可见 —— **语言变了，源头没变**。

上游的 JS 实现已从本分支移除。现在仓库里是移植后的 Swift 代码，
外加一个挂在 DSH 进程里的中介插件 `plugins/dsh-whalefloat-helper`（JS），
两者之间只通过 `~/.dsh` 下的几个 JSON 文件通信。

### 素材

**本仓库不含角色立绘与音效。**

上游的 `PROVENANCE.md` 明确划分：**代码是 MIT，但 `assets/` 不在 MIT 覆盖内** ——
原文是「按 as-is 随插件分发，**仅用于运行本插件；不授予再许可**」。

所以这里排除。素材要自己放进来，三条路：

1. **桌宠设置 →「获取仓库素材…」**：打开素材文件夹与上游页面，
   把下载到的图放进 `~/.dsh/whalefloat-assets/`
2. 手上已有图：**桌宠设置 →「导入图片素材…」**，选一张，程序替你放进去
3. 音效同理：**桌宠设置 →「导入音效素材…」**

缺素材时程序仍可用，退化成「只有菜单栏图标」的形态，功能一个不少。

### 签名说明

发布包用 **ad-hoc 签名**，没有 Apple 开发者证书。这意味着：

```
· 首次打开要右键 → 打开（见安装一节）
· 系统无法验证「这是原版」，理论上可被篡改
· 但权限（日历）只需授权一次 —— 分发的 app 不会重建，CDHash 固定
```

**本地开发**时构建脚本会用一张自签名证书（`setup-cert.sh` 可生成），
那是为了让反复构建时 TCC 权限不被重置 —— 只对开发者有意义，
对分发没有帮助（那张证书不在用户机器上）。

---

## 四、界面

### 菜单

![菜单](docs/images/menu.png)

**左键点图标** → 直接打开 DSH GUI；**右键** → 弹出这个菜单。

### 分析窗口

![分析页](docs/images/analysis.png)

---

## 许可

本项目代码按 **MIT** 发布（见 [LICENSE](LICENSE)）。
角色立绘与音效不在本仓库，也不在 MIT 覆盖范围内。

如上游作者对本仓库的移植方式有异议，请提 issue，我会立即调整或移除。

## 名称

**WhaleFloat** 是本项目的名称，首次公开发布于 2026 年。
时间证据可见本仓库的提交历史（每条都带时间戳与作者）。