# MACDancer

MACDancer 是一个面向 macOS 的 MAC 地址隐私工具。它以标准主窗口应用的方式运行：打开后直接显示接口状态和后台服务状态，菜单栏图标默认开启，也可在设置中关闭。

项目仓库名为 `MACLiar`，应用与 Xcode 工程名称为 **MACDancer**。

> **重要：** 修改 MAC 地址可能导致网络立即中断，也可能被 DHCP、NAC、MAC 白名单或企业网络策略拒绝。本项目不会承诺任意网络都能接受新地址。请先阅读本文的安全限制，并只在你能够承受短暂断网的场景下执行手动修改。

## 功能概览

- 正常的 macOS 主窗口与 Dock 图标；不再依赖“仅菜单栏”模式。
- Dashboard、Interfaces、Automation、Settings 四个主区域，显示当前 MAC、硬件 MAC、接口策略、后台服务和 XPC 健康状态。
- 只读刷新：工具栏“刷新”或 `⌘R` 从系统重新读取接口 MAC，不联系 daemon、不扫描 Wi-Fi、不写配置、不主动断网。
- 受限后台 daemon：GUI 不直接写网卡；每次 MAC 写入都检查命令结果并读回确认，成功后才更新 GUI 与历史。
- 随机 MAC 使用 48-bit、单播、locally administered address（LAA），并排除当前地址、硬件地址和本机接口冲突。可选 Vendor-OUI 兼容模式会降低隐私并有冲突风险。
- 每接口保留最近 20 条已验证成功的地址历史，支持从历史恢复、输入指定地址、恢复硬件地址和清空历史。
- 自动化策略可在睡眠前、唤醒后或接口变为安全的非活动状态时排队执行；不会用固定计时器强制修改正在使用的网络。
- 在“恢复…”中可将接口交还 macOS 管理。MACDancer 只能打开系统设置并提供指引，不能通过公开 API 设定或验证 macOS 的 Private Wi-Fi Address「关闭 / 固定 / 轮替」。

## 当前范围与安全限制

1. 首次安装 daemon 后，所有接口均为 `systemManaged`：不会因为安装、启动或刷新而修改任何真实网卡。
2. 自动策略绝不修改默认路由接口或已关联、正在使用的 Wi-Fi；它只保留待处理任务，等接口处于安全的非活动状态再执行。
3. 手动随机化、从历史恢复或指定 MAC 可以请求作用于活动接口，但 GUI 会明确警告可能短暂断网，并要求确认。
4. 对**已连接的 Wi-Fi**，macOS/无线驱动可能拒绝 MAC 修改，或只在断开关联后才允许生效。MACDancer 不会调用 `disassociate()`、Wi-Fi power cycle、忘记网络或自动重连来绕过这一限制。因此，已连接 Wi-Fi 上的“立即随机化”可能失败；这是保守的安全行为，不表示 GUI 未刷新。
5. SSID 固定 MAC 不在当前版本范围内。
6. 不要同时启用 LinkLiar 的旧 daemon 和 MACDancer 的自动策略；MACDancer 检测到旧服务后会拒绝启用或修复自己的自动服务，避免两个服务竞争同一接口。

## 系统要求

- macOS 14 Sonoma 或更高版本；重点适配 macOS Sequoia。
- Xcode 16 或更高版本；当前版本已使用 Xcode 16.4 验证。
- 本机可用的 Apple 签名 Team。App 与 `MACDancerDaemon` 必须使用**同一个** Team。
- 首次安装后台服务时，需有管理员授权，并可能需要在“系统设置”中批准后台项目/系统服务。

## 从源码构建和运行

以下步骤适用于第一次在自己设备上编译本项目的用户。

### 1. 获取代码

```sh
git clone https://github.com/Jaaayden/MACLiar.git MACDancer
cd MACDancer
```

### 2. 配置本机签名

复制本机专用配置文件：

```sh
cp Configuration/Local.xcconfig.example Configuration/Local.xcconfig
```

编辑 `Configuration/Local.xcconfig`，填写自己的 Team ID：

```xcconfig
DEVELOPMENT_TEAM = YOUR_TEAM_ID
```

也可以不填写该文件，而是在 Xcode 的 Signing & Capabilities 中，分别为 **MACDancer** 与 **MACDancerDaemon** 选择同一个 Team。两种方式选其一即可。

`Configuration/Local.xcconfig` 已被 `.gitignore` 忽略；它是本机私有配置，绝不能提交 Team ID、证书、Provisioning Profile、签名参数或任何凭据。

### 3. 在 Xcode 中构建

1. 用 Xcode 打开 `MACDancer.xcodeproj`。
2. 在 scheme 下拉菜单中选择 `MACDancer`，运行目标选择“我的 Mac”。
3. 确认 App 和 `MACDancerDaemon` 的 Team 一致，且没有遗留他人的 signing identity。
4. 按 `⌘R` 构建并运行。应用启动后应显示主窗口和 Dock 图标。

若 Xcode 报签名错误，先检查 `Configuration/Local.xcconfig` 的 Team ID；再检查两个 target 的签名 Team 是否一致。不要把自己的 Team ID 写进 `Base.xcconfig`、工程文件或提交记录。

### 4. 安装并批准后台服务

后台服务只在用户明确安装后才会注册。

1. 打开应用 Dashboard，在“后台服务”卡片中点击“安装后台服务”。
2. 根据 macOS 提示输入管理员凭据。
3. 如显示“需要批准”，点击“打开系统设置”，在系统设置的 Login Items / Background Items（不同 macOS 版本文字略有不同）中允许 MACDancer。
4. 回到应用，状态应显示 XPC 可达、daemon 健康、协议版本匹配。
5. 若服务已注册但无响应，可点击“修复连接”。它会有序地重新注册服务；不会恢复 MAC、删除策略或清空历史。

“卸载后台服务”仅注销 daemon，默认保留当前 MAC、策略、待处理配置和历史记录，也不会隐式恢复硬件地址。需要恢复时，请先在接口的“恢复…”面板中明确选择目标。

## Personal Team 与正式发布的边界

使用免费 Apple ID / Personal Team 时，可以在自己的 Mac 上从 Xcode 构建和调试 GUI；特权 LaunchDaemon 能否在该开发环境启动，还取决于本机证书、Xcode 的开发执行策略和 macOS 的启动约束，不能视为稳定的安装或分发路径。若系统报告 `Launch Constraint Violation`，不要通过手工安装 plist 或绕过系统安全检查来强行启动。此方式适合本地开发与验收，不适合把构建产物复制给其他人使用。

若要发布可在其他 Mac 上安装的正式版本，需要加入 Apple Developer Program，并使用相应的 Developer ID 签名、Hardened Runtime、归档和 notarization 流程。请不要把 Personal Team 的 `.app`、helper、证书或 Provisioning Profile 当作可分发安装包。

## 使用要点

- **刷新当前状态：** 点击工具栏刷新或按 `⌘R`。这只是读取当前 MAC，适合检查 daemon 完成操作后的最终状态。
- **随机化：** 在接口卡片中选择“立即随机化”。如果目标是当前活跃接口，先确认你可以接受连接短暂中断；对已连接 Wi-Fi，驱动可能直接拒绝，建议在维护窗口或断开 Wi-Fi 后处理。
- **恢复：** 每个接口的“恢复…”可选择交还 macOS 管理、恢复硬件地址、从本接口历史选择或输入指定地址。恢复硬件地址和交还系统管理会设为 `systemManaged`；从历史或指定地址恢复后，会转为指定地址策略，避免立即被随机策略覆盖。
- **Private Wi-Fi Address：** 选择“交还 macOS 管理”后，在系统设置中手动选择关闭、固定或轮替。公开 API 不允许 MACDancer 程序化选择、读取或验证这些每网络设置。
- **菜单栏图标：** 默认显示，设置中可关闭。它使用 SF Symbol，避免自己构建时因自定义图像资源缺失而丢失。

### 快捷键

| 快捷键 | 操作 |
| --- | --- |
| `⌘W` | 关闭当前窗口；后台 daemon 继续运行 |
| `⌘Q` | 退出 GUI；后台 daemon 继续运行 |
| `⌘,` | 打开 Settings |
| `⌘R` | 只读刷新 MAC 地址 |
| `⌘1` / `⌘2` / `⌘3` / `⌘4` | 切换 Dashboard / Interfaces / Automation / Settings |
| `⌘C` | 复制当前聚焦的 MAC 地址 |
| `Esc` | 关闭确认、恢复或编辑弹窗 |

## 配置与隐私

daemon 的配置和历史保存在：

```text
/Library/Application Support/local.macdancer.MACDancer/configuration.json
```

该目录由 daemon 以 root 所有者和严格权限管理，使用原子写入。MACDancer 不迁移或读取 LinkLiar 的旧配置。卸载 daemon 不会删除这里的数据；如需移除数据，请在充分理解影响并确认没有服务仍在使用后，手动处理。

## 测试

运行安全测试：

```sh
./bin/safe-test
```

该脚本只构建并执行无 host app 的 `MACDancerCoreTests`。测试通过 fake daemon、接口提供者、随机源、时钟和命令执行器覆盖 MAC 生成、历史、自动化状态机、XPC 事件和读回确认；不会启动 App 或 daemon，也不会注册服务、修改 MAC、断开 Wi-Fi、开关网卡或使用 `networksetup`。

本项目不把“在 Ethernet 上真实改 MAC”当成 Wi-Fi 的安全验证：两者的系统路径不同，已关联 Wi-Fi 往往必须断开关联。任何真实硬件 MAC 写入测试都应仅在隔离的非生产设备、非关键网络和具备恢复访问方式的条件下，由操作者明确批准后手动执行。

## 安全

更多威胁模型、网络安全不变量和报告建议见 [SECURITY.md](SECURITY.md)。请勿在公开 issue 中披露可复现的高风险网络破坏、权限绕过或敏感信息泄露细节。
