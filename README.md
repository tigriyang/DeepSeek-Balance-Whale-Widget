# WhaleFloat —— 小鲸鱼桌面浮窗

一个**独立于 DSH** 的 macOS 原生浮窗程序：右下角常驻鲸鱼娘，按需冒泡显示
余额、今日已用、峰谷倒计时、当前时间、每轮对话消耗。

## 它做什么

| 触发 | 行为 |
|---|---|
| 第一次单击 | 冒泡显示**余额** → 10 秒后自动收回 |
| 第二次单击 | **按压形变**（交互反馈） |
| 一轮对话结束 | 冒泡显示**本轮消耗** |
| 双击 | 立即收回 |
| 右键 | 功能菜单 |
| 其余时间 | 只有鲸鱼，**无气泡残留** |

### 气泡内容

```
DeepSeek 余额
¥ 81.77
今日已用 ¥8.54
谷 23:38          ← 峰谷字 + 时间同行
```

- **峰谷**只显示一个字「峰」/「谷」（可在设置里关）
- **时间**与峰谷同行（省一行高度，给文字留横向空间）
- 放不下时**逐档降字号**而不是截断（见下「自适应字号」）

## 为什么是独立程序

原先用 Python + pyobjc 做过一版，能跑但三个问题：常驻进程重（8GB 机器）、
依赖 Python 环境、功能只能逐个补。改成 Swift 原生程序后：启动快、内存小、
可打包成标准 `.app`、由 launchd 管理自启。

## 架构

```
Sources/WhaleFloat/
├── App.swift             入口 + 刷新循环 + 状态检测
├── WhaleView.swift       浮窗视图（双底图、气泡文字、点击反馈）
├── FloatWindow.swift     无边框置顶窗口 + 设置持久化
├── BubblePresenter.swift 冒泡时序调度
├── Data.swift            凭据 / 余额接口 / 峰谷计算
├── TurnCost.swift        每轮消耗（读账本）
├── BubbleShapeView.swift 气泡形状（NSBezierPath 绘制）
├── TouchReaction.swift   摸摸头：形变 + 音效
├── SettingsWindow.swift  原生偏好面板
├── LedgerWindow.swift    记账明细窗口
├── WaitState.swift       等 DSH 提问/授权时的状态
└── Menu.swift            菜单 + 启动 DSH
```

## 数据来源（都不依赖 DSH 运行时）

| 数据 | 来源 |
|---|---|
| API key | `~/.dsh/.credentials.yaml` 的 `DEEPSEEK_API_KEY`（环境变量优先） |
| 余额 | 直连 `https://api.deepseek.com/user/balance` |
| 峰谷 | **纯本地计算**（工作日 9-12/14-18 高峰、周末与法定假日全谷价，含 2026 假日表与调休表） |
| 每轮消耗 | 读账本 `~/.dsh/.whalefloat-usage.json` 的 `events`（回退旧鲸鱼账本） |
| 提问/授权 | 读 `~/.dsh/.whalefloat-wait.json`（由 `dsh-wait-state` 插件写） |

**账本由两个自建插件产生**（都在 `~/.dsh/plugins/`）：

| 插件 | 作用 |
|---|---|
| `dsh-turn-usage` | 监听 `assistant/message` 的 usage，按峰谷价折算写入账本 |
| `dsh-wait-state` | 监听 `tool/call`(ask_user_question) / `approval/asked`，写等待状态 |

**为什么用「插件写文件 + 程序读文件」而不是别的**：

- DSH 的会话记录是 zstd 多帧压缩，而 macOS 没有独立 libzstd、
  Swift 的 Compression 框架也不支持 zstd —— 自己解析代价大；
- 事件流只有 DSH 内部拿得到，独立程序无法直接订阅；
- 于是让 DSH 侧的小插件当代言人，落成明文 JSON。简单、稳定，
  而且账本格式与原先网页版鲸鱼的一致，历史数据无损回退。

## 关键实现细节

### 角色与气泡分层（照原作思路）

**网页版原作的分层**：角色图是**纯角色**（`/dsh-whale/image.png`），
气泡由 **SVG 独立绘制**（`dshwv-shapewrap` 内的 path/ellipse）。
显示/隐藏只控制气泡层，角色完全不受影响。

**本程序同样分层**：

```
content（形变容器）
├── imageView    角色层：role-clean.png（纯角色，含呆毛）
├── bubbleShape  气泡层：BubbleShapeView（NSBezierPath 画椭圆 + 三个圆点）
└── stack        文字层：余额 / 已用 / 峰谷字 / 时间
```

气泡几何照 `DSniang02.png` 实测比例（画布 1026 见方）：
椭圆中心 `(453, 255)`、半径 `(365, 240)`，三个圆点由气泡底部指向角色头顶。

**为什么不能从带气泡的合成图里抠**：
`DSniang02.png` 是把气泡与角色压在一起的展示图，气泡描边与**呆毛**在像素上紧邻甚至相连：

```
y=462:  (263-649)泡泡   (664-686)呆毛根   (779-816)呆毛
y=450:  (234-808)       ← 泡泡和呆毛连成一段，无法分离
```

试过 6 种切法（形态学膨胀、逐行边界、段级清除、x 封顶…），**每种的瑕疵只是换位置**：
margin 大→描边干净但切呆毛根；margin 小→呆毛完整但描边残留。
这是几何上的无解，不是调参不够 —— 换成分层设计后问题整体消失。

### 自适应字号

文字排在**椭圆**里，而文字块是矩形 —— 上下行会顶到弧线。两道处理：

1. **按椭圆方程算该高度处的可用宽度**：
   `w = 2a·√(1 − (h/2b)²)`（h 取文字块总高），再乘 0.92 留出呼吸空间
2. **逐档降字号**：macOS 的 `NSTextField` 没有 iOS 那种 `adjustsFontSizeToFitWidth`，
   只能自己量 —— 逐 0.5pt 调小直到文字宽度落进可用宽度（下限 6pt）

⚠️ 降字号要在**内容设置之后**触发：`layout()` 的时机可能早于文字赋值，
只靠 layout 会拿到旧文本量宽度，表现为「标题还是被截」。

### Timer 必须用 common 模式

```swift
// 错的：默认模式的 Timer 在窗口拖动 / 菜单追踪期间会被挂起
Timer.scheduledTimer(withTimeInterval: 10, ...)

// 对的
let t = Timer(timeInterval: 10, repeats: false) { ... }
RunLoop.main.add(t, forMode: .common)
```

因为点击鲸鱼时会调 `performDrag`，RunLoop 进入 `eventTracking` 模式，
默认 Timer 就停了 —— 气泡永远不会自动消失。

## 构建与安装

```bash
# 编译 + 打包 + 安装到 ~/Applications
./build-app.sh

# 运行
open ~/Applications/WhaleFloat.app
```

## 开机自启

```bash
cp ai.dsh.whalefloat.plist ~/Library/LaunchAgents/
launchctl load -w ~/Library/LaunchAgents/ai.dsh.whalefloat.plist
```

程序为 `LSUIElement`（不进 Dock），launchd 以 `Aqua` 会话运行，
`KeepAlive` 崩溃自动拉起。

## 等待提示（提问 / 授权）

DSH 向用户提问或请求授权时，浮窗冒泡提示。文案照网页版鲸鱼的出厂默认：

```
[ 对话名 ]
正在等待老大回答    /    正在等待老大授权
```

**实现**：WhaleFloat 是独立程序，拿不到 DSH 的事件流；
所以由 DSH 侧的小插件 **`dsh-wait-state`**（`~/.dsh/plugins/dsh-wait-state/`）
监听 `session/event` 并落成 `~/.dsh/.whalefloat-wait.json`，程序每秒读该文件。

| 事件 | 含义 |
|---|---|
| `tool/call` 且 name=`ask_user_question` | 提问开始 |
| `tool/result` | 提问结束 |
| `approval/asked` | 授权请求 |
| `approval/*` | 授权结束 |
| `turn/start` · `turn/end` | 一律复位 |

⚠️ 该插件是**新增的插件行，需重启 DSH 才生效**。

## 摸摸头

点击鲸鱼时的反馈 —— **形变参数照抄网页版原作**（对应它的「按压音效」）：

```javascript
// whale-widget.js
var SQUISH = 'scaleY(0.88) scaleX(1.05)'
```
```css
.dshwv-body {
  transform-origin: 50% 100%;                     /* 底部居中锚定 → 底边不动 */
  transition: transform .22s cubic-bezier(.34,1.56,.64,1);  /* 带过冲的弹性 */
}
```

| 行为 | 参数 |
|---|---|
| 按下 | y 压到 0.88、x 拉到 1.05，底边不动、水平居中 |
| 松开 | 0.22s 弹回，曲线 `cubic-bezier(.34,1.56,.64,1)`（过冲产生 Q 弹感） |
| 音效 | `press-down.mp3`（0.24s）+ `press-up.mp3`（0.11s） |

音效取自网页版出厂默认的「小黄鸭」音效组（`PRESET_FRAGMENTS` 里的 `ya1`/`ya2`），
可在设置里用「启用事件音效」整体开关。

### 交互分两段

| 次序 | 条件 | 行为 |
|---|---|---|
| 第一次点击 | 气泡未显示 | 出气泡（余额 / 已用 / 峰谷字 / 时间） |
| 第二次点击 | 气泡已显示 | 按压形变（交互反馈的补充） |
| 双击 | 任意 | 立即收起 |

### 淡入淡出

分层之后很直接：气泡 = **形状层 + 文字层**，两者一起淡入淡出，
角色层毫发无损。

> 早先从合成图抠气泡时，这里需要小心安排「谁先谁后」——
> 否则会出现「背景先没了、文字还在淡出」的错序。
> 换成分层设计后，这个次序问题**自然消失**（也没有了"切底图"这一步）。

### 形变作用于内容容器

角色图与气泡文字同处一个 `content` 容器，形变的是**容器**
（网页版形变的也是整个 `.dshwv-body`）。
早先只形变角色底图，结果角色压扁了、文字纹丝不动，看着像文字卡住。

### 三个实现坑

1. **`layout()` 会抹掉形变** —— 它无条件 `imageView.frame = bounds`，
   每次布局都把 squash 重置。加 `isSquishing` 标记，形变期间跳过重置。
2. **`performDrag` 会吞掉 `mouseUp`** —— 回弹不能只挂在 `mouseUp` 上，
   否则形变卡住不恢复。改为放在 `performDrag` 返回之后（它返回即松手）；
   `mouseUp` 作为兜底。（同一个坑踩过两次：吸附也是。）
3. **`isFlipped` 是 NSView 的既有属性**（坐标系方向），自定义同名属性会报
   `cannot override with a stored property`。镜像状态改叫 `characterMirrored`。

### 镜像翻转

吸到屏幕左边缘时，角色水平镜像（面朝屏幕内侧）。
**只翻角色底图，不动文字** —— 网页版是整体翻转（文字同步反向），
这里按可读性做了取舍。

## 菜单项

- 刷新余额
- **设置…（⌘,）**
- **启动 DSH GUI** —— 调 `dsh-launcher.sh`（它会抓认证 URL 并开浏览器）
- **记账明细…** —— 汇总 + 逐轮明细
- **导入角色图片…** —— 选一张图作为角色（存到 `~/.dsh/whalefloat-assets/custom.png`）
- **充值 / 查看用量…** —— 打开 `platform.deepseek.com/usage`
- **完全退出（并关闭 DSH）** —— 清场：结束启动器 + DSH，然后退出自己
- 退出浮窗
- 版本号（只读）

> 不再有「显示/隐藏气泡」「显示/隐藏浮窗」这类显隐项 ——
> 点击鲸鱼即出气泡、双击收起、自动收回也在跑，菜单里重复这些只是噪音。

### 为什么需要「完全退出」

启动器与 DSH 框架都**不属于本程序**，退出浮窗时不会被带走。于是可能出现：

- 启动器留在后台，还会让浏览器开页面（看起来像「一直在冒网页」）；
- DSH 实例常驻，用户以为已经关掉了。

所以单独给一个清场入口。实现要注意一点：**不能用 pkill** ——
它按进程名匹配，而 `dsh-launcher.sh`、`dsh web` 在进程名里是截断的，匹配不到。
改用 `ps -axo pid=,command=` 拿完整命令行再筛。
（这个坑踩过：先前用 `pkill -f` 清理，进程一个没死，于是「后台一直冒网页」。）

### KeepAlive 的正确写法

launchd 的 `KeepAlive` 写 `<true/>` 的含义是「无论如何都保持运行」——
**退出后会被立刻拉回来**，表现为「起停没做好、自己又起来了」。

```xml
<key>KeepAlive</key>
<dict>
    <key>SuccessfulExit</key>
    <false/>      <!-- 仅异常退出（崩溃）才拉起 -->
</dict>
```

## 设置面板

原生偏好窗口，改动即时生效并落盘（无「保存」按钮）。

| 分区 | 项 |
|---|---|
| 外观 | 大小（120–360 pt）、角色（双素材切换） |
| 气泡 | 自动收回时长（3–60 秒）、单击显示余额、一轮结束显示消耗、按压时冒泡、气泡内显示峰谷、气泡内显示时间 |
| 吸附 | 拖到屏幕边缘时吸附 |
| 提醒 | 余额预警阈值、今日预算（各有越过阈值时的一次性提醒） |
| 音效 | 事件音效总开关 |

配置文件：`~/.dsh/whalefloat.json`（JSON，可手改）。

### 与网页版菜单的对应

| 网页版 | 本程序 |
|---|---|
| 角色 / 大小 | 设置 → 外观 |
| 音效与提示 | 设置 → 音效（提示音待补） |
| 气泡全局开关 / 按压泡泡设置 | 设置 → 气泡 |
| 吸附与翻转 | 设置 → 吸附（暂只有吸附，无镜像翻转） |
| 资源管理（余额预警 / 今日预算） | 设置 → 提醒 |
| 避让滚动条 / 隐藏菜单按钮 | **不适用** —— 那是网页内布局的概念，原生浮窗没有 |

## 素材准备（**必需**）

本仓库**不含角色立绘与音效**——那些来自网页版鲸鱼插件 `dsh-whale-widget`，
版权不属于这里。运行前请自备以下文件放进 `Resources/`：

| 文件 | 用途 | 说明 |
|---|---|---|
| `role-clean.png` | 默认角色 | **纯角色**、透明背景、正方形 |
| `DSniang1.png` | 备选角色 | 同上 |
| `press-down.mp3` | 按下音 | 任意短音效 |
| `press-up.mp3` | 松开音 | 任意短音效 |
| `AppIcon.icns` | 应用图标 | 可由立绘合成，也可省略 |

缺素材时程序仍能构建，但角色显示不出来。

## 更多

- **[迭代记录](docs/迭代记录.md)** —— 每一轮为什么改、踩了什么坑。
  里面记着几次走错方向的完整过程（抠气泡、材质 API、菜单容器），
  比结论更有参考价值。

## 已知取舍

| 取舍 | 原因 |
|---|---|
| 菜单不会「点外面自动关」 | 省掉辅助功能权限；关菜单靠再点一次浮窗或点菜单项 |
| 角色素材不入库 | 版权属于原插件 |
| 「启动 DSH GUI」会中断当前对话 | DSH 重启了，躲不掉 |
| 峰谷表是 2026 年的 | 跨年后需更新 `PeakValley.holidays` |
| 每轮消耗依赖 `dsh-turn-usage` 插件 | 它不在时该行显示空白 |
