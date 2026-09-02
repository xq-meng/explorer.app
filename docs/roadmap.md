# Explorer.app 开发 Roadmap

面向贡献者的范围、里程碑与质量门槛。用户安装与构建说明见 [README](../README.md)。

> 在 macOS 上实现一款采用 Windows Explorer 交互模型、同时遵循 macOS 系统能力与安全规范的原生文件管理器。

## 当前实施进度（2026-08-31）

| 里程碑 | 状态 | 已完成 | 仍需完成 |
|---|---|---|---|
| M0 工程基线 | 已完成 | SwiftPM 工程、AppKit 应用外壳、`Core/Browsing/Operations/UI/App` 单向模块边界、CI、Swift 6 构建与测试、可直接运行的 ad-hoc 签名 `.app` 脚本 | 正式 Xcode 发布工程与 Developer ID 配置留到 M5 |
| M1 只读浏览 | 进行中 | 异步目录加载、稳定文件 ID、取消、可点击表头排序、隐藏文件设置、真实导航、挂载卷与位置快捷方式侧边栏 | 分批目录加载、10 万项目性能报告和更多网络卷验证 |
| M2 视图与标签页 | 进行中 | 多窗口、详细信息/图标视图、按可见范围生成的 Quick Look 缩略图与有界内存缓存、AppKit 原生窗口标签、标签内独立历史与选择、可点击/可编辑面包屑、自定义收藏夹、系统标签排序与拆分，以及全局视图模式与窗格设置恢复 | 最近访问、缩略图磁盘缓存策略，以及标签路径、选中标签、每标签排序、选择、滚动位置和完整历史恢复 |
| M3 文件操作 | 进行中 | 安全操作引擎、串行队列、字节级进度与进度条、用户可见取消、批量冲突与应用到全部、回滚式替换、剪贴板、菜单/右键操作、安全 Undo/Redo、`NSFileCoordinator`、关闭与退出保护、身份校验写前日志，以及普通复制、替换和跨卷移动的启动恢复 | 持久化操作历史、更多外接卷与异常中断场景验证 |
| M4 系统集成 | 进行中 | Quick Look 缩略图、浮动面板和可切换右侧预览窗格、Spotlight 子树搜索、递归搜索兜底、目录变化监听、普通文件 URL 与 file promise 拖放 | Finder、Mail、Safari、Photos 等跨应用拖放兼容性矩阵，外部变化刷新后的滚动位置保持与高频变化验证 |
| M5 发布准备 | 进行中 | 本地开发 `.app` 组装、原创多分辨率应用图标、Info.plist、entitlements、ad-hoc 签名与签名验证、GitHub 预发布与 Homebrew Cask 自动发布、已知问题和回归检查表 | Developer ID、公证、DMG、应用内自动更新、辅助功能和兼容性矩阵；如需沙盒版则补充目录授权 |

当前代码以“可构建、测试通过的开发原型”为目标；尚未达到本文定义的 Beta 退出条件。

`v0.8.0` 开发基线把普通复制、重复和跨卷移动改为隐藏同目录暂存后原子提交，并使用带文件系统身份与递归元数据指纹的写前日志恢复中断事务。同卷替换式重命名和移动也会区分“源尚未移动”与“新目标已经提交”，避免启动恢复误删已移动的源；任何身份不匹配或状态不明确的项目都会原样保留并报告人工处理，而不会按路径猜测删除。

当前预览版的限制集中记录在[已知问题](known-issues.md)，每次发布前按[回归检查表](regression-checklist.md)执行和留档。

界面产品研究参考：[ronhash10/MacExplorer](https://github.com/ronhash10/MacExplorer)（MIT）。当前工程借鉴其位置侧边栏、面包屑和预览窗格的产品模式，但继续使用独立的 AppKit 视图与 actor 服务层实现。

## 1. 产品目标

Explorer.app 的首要目标不是复刻 Windows 界面素材，而是复用其高效率的文件管理方式：位置快捷方式、地址栏、详细信息列表、标签页、键盘操作、文件操作队列和冲突处理。

应用同时需要符合 macOS 用户预期：支持 Command 系列快捷键、Quick Look、应用包、废纸篓、系统默认打开方式、iCloud 文件和系统隐私权限。

### MVP 成功标准

- 可以稳定浏览本地磁盘、外接磁盘和已挂载网络磁盘。
- 支持位置快捷方式侧边栏、地址栏、标签页、详细信息和图标两种视图。
- 支持新建、重命名、复制、移动、剪切、粘贴、拖放和移入废纸篓。
- 支持 Quick Look、当前目录子树搜索和外部文件变化刷新。
- 所有文件 I/O 均不阻塞主线程。
- 包含 10 万个项目的目录仍可取消加载、响应导航，不出现界面假死。
- 文件操作失败、冲突、权限不足或磁盘离线时，用户能够理解当前状态并安全恢复。

## 2. 首版范围

### 包含

- 多窗口、单窗口多标签页
- 收藏夹、磁盘和网络位置快捷方式
- 后退、前进、向上、刷新
- 可输入路径的地址栏与面包屑导航
- 详细信息视图和图标视图
- 名称、类型、大小、修改时间排序
- 显示或隐藏隐藏文件
- 多选、全选、框选和键盘导航
- 新建目录、重命名、复制、移动、重复、移入废纸篓
- 应用内拖放以及与 Finder、Mail、Safari 等应用之间的拖放
- 文件操作进度、取消、错误与同名冲突处理
- 空格 Quick Look 和可选右侧预览窗格
- Spotlight 搜索与目录枚举兜底
- 标签页、历史、排序和视图状态恢复
- macOS 常用快捷键及 Windows 风格快捷键

### 暂不包含

- 自建全盘文件索引
- SFTP、FTP 或自定义 SMB 客户端
- 压缩包直接编辑
- 管理员提权文件操作
- 第三方 Shell Extension 兼容层
- 自定义云盘同步服务
- 完整文件标签与 ACL 编辑器
- 将应用注册成 macOS 的系统默认文件浏览器

## 3. 技术基线

### 技术栈

- 语言：Swift
- UI：AppKit 为主，SwiftUI 用于设置页和轻量界面
- 并发：Swift Concurrency
- 最低系统：macOS 14
- 测试：XCTest、XCUITest、性能测试
- 默认发布方式：开发者网站分发，Developer ID 筿名并完成公证

如果未来需要进入 Mac App Store，则另行提供沙盒构建：通过 `NSOpenPanel` 获取用户授权目录，并用 security-scoped bookmark 持久化访问权限。

### 核心系统框架

- `AppKit`：窗口、位置侧边栏、列表、图标网格、菜单、键盘和拖放
- `Foundation`：目录枚举、文件属性和基础文件操作
- `QuickLook` / `QuickLookThumbnailing`：预览和缩略图
- `UniformTypeIdentifiers`：文件类型判断
- `CoreServices.FSEvents`：目录层级变化监听
- `NSMetadataQuery`：Spotlight 搜索
- `NSWorkspace`：系统打开方式、图标及废纸篓集成
- `NSFileCoordinator`：iCloud、File Provider 及并发文件访问协调

## 4. 目标架构

```text
ExplorerApp                  组合根、窗口/标签协调、会话与历史状态
├── ExplorerUI               纯 AppKit 展示、输入事件和浏览命令
├── ExplorerBrowsing         只读目录、搜索、卷、变化监听、缩略图
│   └── ExplorerCore         文件模型、目录快照、Provider 协议
└── ExplorerOperations       写操作、队列、剪贴板、冲突与 Undo 计划

Future: ExplorerPlatform     沙盒授权、Security Bookmark、Workspace 集成
```

### 架构原则

- `ExplorerUI` 不依赖文件系统模块，也不直接调用 `FileManager`；`ExplorerApp` 是唯一组合根。
- 只读浏览和可变写操作分属 `ExplorerBrowsing`、`ExplorerOperations`，避免一个宽泛的 Services 模块持续膨胀。
- 使用文件资源标识符和卷标识符组合生成稳定 ID，路径只作为位置，不作为唯一身份。
- UI 状态运行在 `@MainActor`；加载、搜索、缩略图和文件操作由独立 actor 执行。
- 目录加载返回不可变 `DirectorySnapshot`，界面通过 diff 增量更新。
- 所有耗时任务都必须可取消；切换目录或关闭标签页时立即取消无效任务。
- `FileProviderProtocol` 与 UI 解耦，为未来的远程文件源或压缩包浏览保留扩展点。

## 5. 里程碑计划

以下计划按一名熟悉 macOS 开发的工程师估算，总计约 10 周。每个阶段只有在退出条件全部满足后才进入下一阶段。

### M0：产品与工程基线（第 1 周）

目标：建立可持续开发的项目骨架，并冻结 MVP 的关键产品决策。

工作项：

- 创建 Xcode 工程、应用 target、单元测试和 UI 测试 target。
- 确定 Bundle ID、最低 macOS 版本、签名方式和发布渠道。
- 建立模块目录、代码规范、日志和错误模型。
- 定义 `FileItem`、`FileItemID`、`DirectorySnapshot` 和 `FileProviderProtocol`。
- 制作主窗口低保真原型：工具栏、侧边栏、内容区、预览区、状态栏。
- 建立持续集成：构建、单元测试和静态检查。

交付物：

- 可启动的空壳应用。
- 核心数据模型和接口。
- 主窗口布局原型。
- 自动构建与测试流水线。

退出条件：

- Debug 和 Release 均可干净构建。
- 核心模块不依赖具体视图类。
- 团队对 MVP 功能、发布方式和最低系统版本没有未决问题。

### M1：只读浏览核心（第 2～3 周）

目标：完成稳定、异步、可取消的本地文件浏览闭环。

工作项：

- 实现 `LocalFileProvider` 和 `DirectoryLoader`。
- 批量读取名称、类型、大小、修改时间、隐藏状态、包和符号链接属性。
- 实现收藏夹、挂载卷和网络位置快捷方式侧边栏。
- 实现后退、前进、向上、刷新和直接输入路径。
- 实现详细信息列表、多选、排序和隐藏文件开关。
- 实现首批优先展示及后续批量补齐。
- 切换目录时取消旧加载任务。
- 对无权限目录、离线卷和损坏符号链接提供可理解的错误状态。

交付物：

- 可浏览本地目录的只读应用。
- 导航历史和目录快照机制。
- 大目录性能测试基线。

退出条件：

- 普通本地目录首批内容目标在 200ms 左右出现。
- 10 万项目目录加载时界面保持响应，且任务可取消。
- 快速前进、后退和切换目录不会展示过期结果。
- 符号链接循环不会导致递归失控。

### M2：图标视图、标签页与状态恢复（第 4 周）

目标：完成 Explorer 风格的主要浏览体验。

工作项：

- 使用 `NSCollectionView` 实现图标视图。
- 实现按可见范围请求缩略图，并提供内存与磁盘缓存。
- 实现标签页的新建、关闭、复制和重新打开。
- 每个标签页独立保存路径、历史、选择、排序和视图模式。
- 实现收藏夹、最近访问和已挂载卷列表。
- 实现窗口、分栏宽度和标签页会话恢复。
- 补齐右键菜单、菜单栏命令和快捷键路由。

交付物：

- 详细信息和图标两种视图。
- 多标签页浏览。
- 启动后会话恢复。

退出条件：

- 快速滚动期间不会为屏幕外项目集中生成缩略图。
- 标签页之间不存在选择状态或加载结果串扰。
- 强制退出后重新启动不会因损坏的会话数据而无法进入应用。

### M3：文件操作引擎（第 5～6 周）

目标：安全完成用户对磁盘内容的修改。

工作项：

- 建立统一 `FileOperation` 模型和串行/受控并发操作队列。
- 实现新建目录、重命名、复制、移动、重复和移入废纸篓。
- 实现剪贴板复制、剪切和粘贴。
- 实现同名文件冲突：替换、保留两者、跳过、应用到全部。
- 实现操作进度、取消、错误重试和操作历史。
- 处理跨卷移动、只读卷、磁盘空间不足和目标突然离线。
- 对需要协调的文件操作接入 `NSFileCoordinator`。
- 建立部分完成操作的清理和恢复策略。

交付物：

- 独立于 UI 的文件操作引擎。
- 文件操作中心和冲突处理界面。
- 覆盖关键异常路径的单元与集成测试。

退出条件：

- 默认删除只进入废纸篓，不直接永久删除。
- 取消或失败不会悄悄覆盖已有文件。
- 跨卷移动只有在复制成功后才删除源文件。
- 应用在文件操作期间退出后，重新启动可以识别并清理临时状态。
- 文件操作中的错误能够定位到具体项目，并允许继续处理剩余项目。

### M4：拖放、预览、搜索与变化监听（第 7～8 周）

目标：完成与 macOS 生态和外部文件变化的集成。

工作项：

- 实现列表和图标视图之间的内部拖放，并将位置快捷方式作为可选拖放目标。
- 实现与 Finder 之间的文件 URL 拖放。
- 接收来自 Mail、Safari、Photos 等应用的 file promise。
- 接入空格 Quick Look 和右侧 `QLPreviewView`。
- 使用 `NSMetadataQuery` 实现 Spotlight 搜索。
- 对未索引或限定目录提供后台枚举搜索兜底。
- 使用目录监听和 FSEvents 感知外部变化。
- 将变化合并后生成新快照，避免重复刷新和选择丢失。

交付物：

- 完整拖放闭环。
- Quick Look 与预览窗格。
- 可取消、可持续更新的搜索体验。
- 外部变化自动刷新。

退出条件：

- 拖放行为能够根据修饰键明确区分复制和移动。
- 搜索取消后不会继续更新旧页面。
- 外部改名、创建和删除不会造成崩溃或永久重复项目。
- 文件变化刷新后尽可能保持当前选择和滚动位置。

### M5：权限、兼容性与发布准备（第 9～10 周）

目标：达到可供外部用户测试的 Beta 品质。

工作项：

- 完成 Developer ID 签名、公证和自动更新方案。
- 如需要沙盒版本，实现目录授权和 security-scoped bookmark 生命周期。
- 测试 APFS 大小写敏感/不敏感卷、外接磁盘、只读卷和 SMB。
- 测试应用包、别名、符号链接、隐藏文件、扩展属性和权限错误。
- 测试 iCloud 未下载文件和其他 File Provider 占位文件。
- 完成 VoiceOver、键盘焦点、高对比度、深色模式和本地化检查。
- 完成崩溃日志、隐私说明、诊断导出和反馈入口。
- 编写用户手册、快捷键清单和已知问题。

交付物：

- 已签名并公证的 Beta 安装包。
- 发布检查表、用户手册和已知问题列表。
- 性能、兼容性和稳定性测试报告。

退出条件：

- 在干净 macOS 用户账户中可以正常安装、启动和卸载。
- 关键操作经过至少一次外部磁盘、SMB 和 iCloud 场景验证。
- 无已知的数据损坏或静默覆盖问题。
- 所有 P0/P1 缺陷关闭，P2 缺陷有明确处理计划。

## 6. Beta 之后的演进

### V1.0：稳定版

- 根据 Beta 反馈修复导航、选择、拖放和文件操作问题。
- 完善批量重命名、撤销和键盘可配置能力。
- 优化百万级目录、网络磁盘和低速外接存储表现。
- 增加操作日志和更精确的错误恢复。
- 完成中英文界面与正式发布材料。

### V1.1：效率增强

- 分栏或双面板模式。
- 文件夹固定、工作区和标签页组。
- 高级筛选器与保存的搜索。
- 哈希计算、路径复制和批量重命名规则。
- 更完整的文件信息与权限查看。

### V2.0：可扩展文件源

- 压缩包只读浏览，稳定后再考虑编辑。
- SFTP 或其他远程文件源。
- 插件式上下文菜单动作。
- 可选 File Provider 扩展，用于将自有远程存储暴露给 Finder 和其他应用。

## 7. 测试矩阵

### 文件系统场景

- 空目录、普通目录、10 万项目目录、超深层级目录
- 大小写敏感与不敏感 APFS
- 文件名大小写冲突和 Unicode 规范化差异
- 应用包、普通目录、符号链接、别名、损坏链接
- 稀疏文件、大文件、零字节文件、扩展属性和 ACL
- 无读取权限、无写入权限、锁定文件和只读卷
- 外接磁盘拔出、磁盘空间不足、卷重新挂载
- SMB 断线和高延迟
- iCloud 或第三方云盘的未下载占位文件

### 交互场景

- 快速切换目录、标签页和视图模式
- 加载、搜索、缩略图和复制过程中的取消
- 多选、框选、键盘扩展选择和选择恢复
- 外部应用同时改名、移动或删除当前项目
- 拖放到自身子目录、相同目录、不同卷和无权限目录
- 文件操作期间退出、崩溃或强制终止

## 8. 性能与质量门槛

- 主线程不得执行目录遍历、文件复制、缩略图生成或 Spotlight 查询。
- 普通本地目录首批可见内容目标为约 200ms。
- 10 万项目目录中，导航和取消操作必须保持响应。
- 滚动时只加载可见区域及有限预取范围内的缩略图。
- 所有异步结果在提交 UI 前验证所属标签页和请求版本。
- 所有覆盖、永久删除和不可逆操作必须经过显式确认或明确策略。
- 不允许存在已知的静默数据丢失、错误目标写入或源文件提前删除问题。

## 9. 风险与应对

| 风险 | 影响 | 应对策略 |
|---|---|---|
| App Sandbox 限制全盘浏览 | 产品体验受限 | 首版采用官网分发；沙盒版本设计为用户授权根目录模式 |
| 大目录加载阻塞 | 界面假死、内存过高 | 后台分批加载、可取消任务、虚拟化视图和增量快照 |
| iCloud/网络文件 I/O 延迟不可控 | 打开目录或操作长时间等待 | 所有 I/O 异步化，展示加载状态，支持取消与超时后的重试 |
| 文件操作并发冲突 | 数据覆盖或丢失 | 统一操作队列、`NSFileCoordinator`、临时文件和提交阶段 |
| 路径变化导致身份错乱 | 重复项目、选择丢失 | 使用资源 ID 与卷 ID，路径只作为可变属性 |
| FSEvents 事件合并或缺失细节 | UI 与磁盘状态不一致 | 将事件作为重新核对信号，重新生成目录快照而非直接猜测变化 |
| Windows 与 macOS 快捷键冲突 | 用户学习成本或系统行为异常 | 默认提供 macOS 映射，同时补充可配置的 Windows 风格映射 |

## 10. 发布检查表

- [x] Swift 6 严格警告构建和 149 项自动化测试通过
- [x] GitHub 预发布产物与 Homebrew Cask 版本、SHA-256 自动同步
- [x] 已知问题和发布回归检查表已纳入文档
- [ ] Developer ID 签名和公证验证通过
- [ ] 首次启动权限说明清晰
- [ ] 新建、改名、复制、移动、废纸篓和冲突处理回归通过
- [ ] 外接磁盘、SMB 和 iCloud 场景验证通过
- [ ] 深色模式、VoiceOver 和纯键盘操作可用
- [ ] 崩溃日志和诊断导出不包含用户文件内容
- [ ] 隐私政策、许可证和第三方依赖清单齐备
- [ ] 自动更新具备签名验证和失败回滚策略
- [ ] 用户手册、快捷键清单和已知问题已发布

## 11. 官方技术参考

- [AppKit Outline View](https://developer.apple.com/documentation/appkit/outline-view)
- [AppKit NSCollectionView](https://developer.apple.com/documentation/appkit/nscollectionview)
- [FileManager](https://developer.apple.com/documentation/foundation/filemanager)
- [NSFileCoordinator](https://developer.apple.com/documentation/foundation/nsfilecoordinator)
- [Improving performance and stability when accessing the file system](https://developer.apple.com/documentation/foundation/improving-performance-and-stability-when-accessing-the-file-system)
- [Quick Look Thumbnailing](https://developer.apple.com/documentation/quicklookthumbnailing)
- [QLPreviewPanel](https://developer.apple.com/documentation/quicklookui/qlpreviewpanel)
- [NSMetadataQuery](https://developer.apple.com/documentation/foundation/nsmetadataquery)
- [File System Events](https://developer.apple.com/documentation/coreservices/file_system_events)
- [Uniform Type Identifiers](https://developer.apple.com/documentation/uniformtypeidentifiers)
- [Accessing files from the macOS App Sandbox](https://developer.apple.com/documentation/security/accessing-files-from-the-macos-app-sandbox)
- [Supporting Drag and Drop Through File Promises](https://developer.apple.com/documentation/appkit/supporting-drag-and-drop-through-file-promises)
- [File Provider](https://developer.apple.com/documentation/fileprovider)
