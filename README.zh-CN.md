<p align="center">
  <img src="./assets/readme/hero.svg" width="100%" alt="Oil Find：文件、应用和剪贴板，一处搜索。默认按 ⌘Space 打开。">
</p>

<p align="center">
  <a href="https://github.com/Sigurd-git/oil-Spotlight"><b>本 fork 源码</b></a>
  &nbsp;·&nbsp;
  <a href="https://find.oiloil.org">官网</a>
  &nbsp;·&nbsp;
  <a href="./README.md">English</a>
</p>

本仓库是基于 [Oil Find 上游项目](https://github.com/oil-oil/oil-find) 的公开 fork；本分支保留上游的多来源扩展与 Pro 官网流程，并增加统一搜索和剪贴板历史。fork 构建关闭上游官方应用更新通道，不会自动检查或安装上游官方更新；请从本 fork 源码构建，上游发行版信息见下方 Pro 说明。

Oil Find 是 macOS 原生搜索面板。默认按 ⌘Space 打开；如果该快捷键因 Spotlight 冲突而注册失败，应用会临时尝试 ⇧⌘F，并在设置中提供 Spotlight 系统快捷键设置入口、路径提示和重试。你也可以在「系统设置 → 键盘 → 键盘快捷键 → Spotlight」关闭 Spotlight 搜索快捷键。升级时会保留你已有的自定义快捷键。

按文件名搜索的全部功能都在免费版里，代码开源。外置磁盘接入时可在免费版搜索；拔掉后，免费版无法搜索其中的文件。拔掉后仍可搜索外置磁盘，以及图片和文档内容，属于上游独立付费的 [Oil Find Pro](#oil-find-pro) 扩展；统一搜索、剪贴板历史和 Spotlight 快捷键属于本 fork 的 macOS 应用。

## 为什么快

- **文件名放在一块连续的内存里。** 几十万个名称按列存放，搜索时从头到尾扫一遍，不给每个文件单独创建对象。
- **匹配交给 C 和 NEON。** 字符比较用 Apple 芯片的向量指令批量完成。
- **增量收窄结果。** 每多打一个字，只在上一次的结果里继续找。
- **只更新变化的部分。** 通过 FSEvents 监听文件变化，增量更新索引；应用重启后从上次停下的位置接着补齐。

默认不深入开发依赖目录、应用包内部、资源库和系统目录；可在设置里调整索引范围。文件搜索支持拼音、名称与路径条件、通配符、类型、大小和修改时间筛选。

## 其他搜索范围

搜索面板提供「全部、应用、文件、设置、剪贴板」范围，按 ⌘0…⌘4 切换；文件类型筛选使用 ⌥⌘1…9。文件结果保留 Quick Look 预览、路径复制、访达定位与拖放操作。

按 ⌘⌫ 清空整个搜索框。搜索词默认在面板关闭 1 分钟后过期，再次唤起时自动清空，短时间切换应用会保留输入；不会在输入过程中清空。可在「设置 → 搜索 → 搜索词自动清空」选择关闭后立即、1 分钟、5 分钟、15 分钟或始终保留。分类和筛选偏好保留。

![统一搜索，使用合成示例数据](./assets/readme/launcher-zh.png)

剪贴板历史默认关闭，仅在首次启用后开始记录获准的文本、链接、粘贴板栅格图片，以及本地文件和文件夹的路径引用。升级保留已有开启状态和偏好，原 AES 加密归档中的文本历史仍可使用。从 Finder 复制的一组文件会保存为一条历史，列表显示名称和数量，可按文件名或路径搜索。截图及 PNG、JPEG、TIFF、GIF、HEIC、WebP、BMP 等系统 ImageIO 可解码的栅格图会保留原始编码格式、图片 bytes 和格式/像素尺寸元数据；单图最多 16 MiB、6400 万像素。图片不会自动做 OCR，也不会联网；可主动在截图工具中识字。用 Finder 复制图片文件时仍只保存路径引用，不读取文件。

选中文件历史项后按 ⌘C，会把整组文件恢复为系统剪贴板上的文件 URL；回到 Finder 按 ⌘V 即可复制文件。按 Return 会在检查原目标应用、焦点和辅助功能权限后尝试直接粘贴；检查失败时仅复制到系统剪贴板并提示。历史只保存路径，不备份或读取文件正文；文件移动或删除后无法从历史恢复。恢复复制前在后台检查整组文件是否仍存在；任一路径失效或检查超过 2 秒时，保留当前剪贴板并提示。等待期间修改查询、切换选中项或关闭面板，会在写入前取消旧操作。

图片历史行显示缩略图并支持预览。按 ⌘C 可将真实图片恢复到系统剪贴板，保留原始表示，并在容量允许时提供兼容 PNG。Return 沿用既有的目标应用、焦点和辅助功能权限检查后尝试粘贴；检查未通过时只复制到剪贴板并提示。选中文件历史项按 ⌘C 会恢复整组文件 URL，回 Finder 按 ⌘V 复制文件；Return 同样沿用既有检查。历史只保存文件路径，不备份或读取文件正文；路径移动或删除后无法恢复，恢复复制前会检查整组路径，失败时保留当前剪贴板并提示重新复制。

![使用合成截图展示的剪贴板图片历史](./assets/readme/clipboard-images-zh.png)

默认保留 7 天、最多 500 条；可分别调整为 1…365 天和 1…10,000 条。单条文本的 UTF-8 大小最多 256 KiB；单条文件记录最多 1,000 个路径，所有路径的 UTF-8 总大小最多 256 KiB。历史总量仍最多 32 MiB，图片 bytes 和文件路径引用都在本机加密，并由钥匙串保护。默认排除密码管理器，也可排除其他来源应用；可暂停记录或清空历史。文件承诺中尚未生成的内容，以及标记为敏感、临时或自动生成的剪贴板项目不会采集。

钥匙串访问失败时保留原加密文件，新记录暂存内存，设置中显示保存错误。点击「授权保存历史」后才会请求系统授权；成功读取原历史后，与当前内存记录合并保存。授权失败时继续保留原文件，不覆盖已有历史。

![剪贴板历史，使用合成示例数据](./assets/readme/clipboard-zh.png)

表达式计算和单位换算离线完成。输入网址可打开该网址；网页搜索默认 DuckDuckGo，可选 Google 或 Bing。普通查询可选择网页搜索结果，或用 `web:` 明确搜索；只有执行该结果时才会打开搜索引擎，输入过程中不会发送查询内容。

在「全部」范围输入 `100 usd in to rmb`、`100 USD to CNY` 或 `100美元转人民币` 可换算货币；RMB 作为 CNY 的别名处理。汇率取自 [Frankfurter 提供的 ECB 每日参考汇率](https://frankfurter.dev/)，结果标明日期，Return 或 ⌘C 复制结果。首次完整货币查询会异步获取固定货币列表，金额和完整查询留在本机；普通文件搜索、计算和单位换算不发起汇率请求。公开汇率在本机缓存 24 小时，过期后后台刷新；服务不可用时标明缓存状态，无可用缓存时可按 Return 重试。参考汇率不包含银行手续费或实时交易价格。可在「设置 → 搜索」关闭汇率换算。

![汇率换算界面，使用合成汇率和示例日期](./assets/readme/currency-zh.png)

## 原生截图工具

按 **⌘⇧4**、搜索「截图」或使用菜单栏，捕获选区、窗口、鼠标所在屏幕或手动滚动长截图。截图完成后先编辑，再复制、保存 PNG / JPEG 或钉住。支持箭头、直线、矩形、椭圆、步骤、文字、画笔、高亮、马赛克、实色遮挡、裁剪、Emoji、贴纸、素材、撤销和重做，也可打开文件、剪贴板图片及截图历史继续编辑。Vision 识字由用户主动执行，在本机后台处理。钉图文支持缩放、透明度和所有桌面显示，退出后不自动恢复。

独立截图历史默认加密保存 **7 天、100 张、最多 256 MiB**，设置 → 截图可关闭或调整。可编辑历史保留**打码前原图**，导出文件只含合并后的像素。首次捕获需本人授予屏幕录制权限；系统占用 ⌘⇧4 时，截图设置提供冲突引导，搜索与菜单入口仍可用。详细规则见 [截图、容量与隐私说明](./docs/CAPTURE.md)。

![截图编辑器，使用合成图片](./assets/readme/capture-editor-zh.png)

## 搜索语法

| 输入 | 意思 |
| --- | --- |
| `wd`、`wendang` | 拼音首字母或全拼，能找到「文档」 |
| `foo bar` | 同时包含 foo 和 bar |
| `foo \| bar` | 包含 foo 或 bar |
| `readme !node_modules` | 包含 readme，排除 node_modules 里的 |
| `*.png` | 通配符，匹配整个名称 |
| `~/Desktop/ png` | 只在桌面下面找 |
| `ext:pdf;docx` | 按扩展名 |
| `kind:image` | 按类型：folder、app、doc、image、video、audio、code、archive |
| `file:`、`folder:` | 只要文件，或只要文件夹 |
| `size:>10mb`、`size:1mb..5mb` | 按大小 |
| `dm:today`、`dm:week`、`dm:2026-10-01` | 按修改时间 |
| `regex:^IMG_\d+` | 正则表达式 |

从终端或编辑器复制来的路径可以直接粘贴：`file://` 链接、带引号或转义的路径、末尾带 `:行:列` 的路径都能识别。在搜索框里按 ⌘/ 可以随时打开语法速查。

## 键盘操作

| 按键 | 作用 |
| --- | --- |
| <kbd>⌘</kbd><kbd>Space</kbd> | 打开搜索（默认） |
| <kbd>⇧</kbd><kbd>⌘</kbd><kbd>F</kbd> | ⌘Space 注册失败时的临时回退 |
| <kbd>⌘</kbd><kbd>0</kbd>…<kbd>4</kbd> | 切换全部、应用、文件、设置、剪贴板范围 |
| <kbd>⌥</kbd><kbd>⌘</kbd><kbd>1</kbd>…<kbd>9</kbd> | 选择文件类型 |
| <kbd>Return</kbd> | 执行结果：打开、复制计算结果，或粘贴剪贴板条目 |
| <kbd>⌘</kbd><kbd>Return</kbd> | 文件：在访达中显示 |
| <kbd>⌘</kbd><kbd>Y</kbd> | 文件：Quick Look；剪贴板：预览文本或图片 |
| <kbd>⌘</kbd><kbd>C</kbd> | 优先复制选中文字，否则复制当前结果的路径、文本或网址；剪贴板图片和文件组可恢复为可用的剪贴板内容 |
| <kbd>⌥</kbd><kbd>⌘</kbd><kbd>C</kbd> | 文件：拷贝名称 |
| <kbd>⌘</kbd><kbd>⌫</kbd> | 清空整个搜索框；文件和剪贴板记录的删除使用右键菜单 |
| <kbd>Tab</kbd> | 在文件范围内切换文件类型 |
| <kbd>⌘</kbd><kbd>/</kbd> | 语法速查 |

结果也可以直接拖到别的应用里。

## Oil Find Pro

本节的 Pro 功能、安装包和许可说明对应[上游发行版](https://github.com/oil-oil/oil-find/releases)。本 fork 从公开源码构建时不包含 Pro；其官方应用更新通道保持关闭。

公开应用代码采用 MIT 许可证。Oil Find Pro 是独立的闭源付费扩展，¥49（其他地区 $9.99）一次买断，并提供 7 天免费试用。免费版始终免费、开源；Pro 和免费版使用同一个安装包。

| | 免费版 | Pro |
| --- | :---: | :---: |
| 按文件名搜索：拼音、通配符、正则，按类型、大小、时间筛选 | ✓ | ✓ |
| 本地 AI 话题：Claude Code、Claude 桌面端 Code 会话、Codex、WorkBuddy | ✓ | ✓ |
| 实时更新、Quick Look 预览、拖放、全键盘操作 | ✓ | ✓ |
| 排除文件夹和文件类型、应用内更新 | ✓ | ✓ |
| 外置磁盘：接入时建立索引并可搜索 | ✓ | ✓ |
| 外置磁盘拔掉后仍可搜索 | | ✓ |
| 图片内容：截图、照片里的文字与画面 | | ✓ |
| 文档内容：PDF、Word、PowerPoint、Excel、Pages、Markdown 等 | | ✓ |
| 源码 | 开源，MIT | 闭源 |
| 价格 | 免费 | ¥49（其他地区 $9.99）一次买断 |

Pro 和免费版是同一个安装包：

- 从 Releases 或官网下载后，免费功能直接可用，不激活也不会过期。
- 想用 Pro，在设置的 Oil Find Pro 分区点「免费试用 7 天」，或输入授权码。试用结束只停用 Pro 功能，其他照常。
- 从源码构建得到的是不含 Pro 的免费版。
- 图片和文档都在本机处理，不上传。

购买和详情见 [find.oiloil.org/pro](https://find.oiloil.org/pro)。

## 安装

1. 从 [Releases](https://github.com/oil-oil/oil-find/releases/latest) 下载 `Oil-Find.zip`，解压后把 Oil Find 拖进「应用程序」。
2. 第一次打开时，macOS 会拦下来，因为它没有经过 Apple 公证。到「系统设置 → 隐私与安全性」，在页面下方点「仍要打开」。
3. 按 ⌘Space 开始搜索。如果快捷键注册失败，应用会临时尝试 ⇧⌘F；你也可以按上方说明调整 Spotlight 系统快捷键设置后，在应用设置中重试。
4. 可选：授予「完全磁盘访问权限」后，邮件附件和其他应用的数据也能搜到。不授予也能正常使用。

此 fork 构建关闭了上游官方应用更新通道，不会提示或安装上游官方版本。请从本 fork 获取更新构建（如有），或自行构建。

源码用户可运行 `scripts/uninstall.sh`，确认后删除应用、本地索引、剪贴板历史、偏好设置及剪贴板加密密钥。手动卸载时退出应用并删除「应用程序」里的 Oil Find 和 `~/Library/Application Support/Oil Find`；钥匙串中的 `com.oiloil.find.clipboard-history` 项可一并删除。

## 从源码构建

应用运行需要 macOS 14 或更新版本。源码构建需要包含 macOS 15.4 或更新 SDK 的 Xcode；CI 使用 Xcode 16.4（macOS 15.5 SDK），项目保持 Swift 5 语言模式和 macOS 14 部署目标。

```sh
git clone --branch codex/spotlight-launcher https://github.com/Sigurd-git/oil-Spotlight.git
cd oil-Spotlight
swift test
scripts/build-app.sh   # 生成 build/Oil Find.app
scripts/install.sh     # 构建并安装到「应用程序」
```

构建脚本允许用 `OILFIND_BUILD_SYSTEM` 选择 SwiftPM 后端。若仅使用新版 Command Line Tools，默认后端生成的 SDK 标记未通过正式产物检查，可使用 `OILFIND_BUILD_SYSTEM=native scripts/build-app.sh`；同一选项也适用于安装和剪贴板升级验证脚本。完整 XCTest 仍需 Xcode 提供测试框架。

未配置稳定签名身份时，自己构建的应用使用临时签名；重新构建后可能需要再次授予完全磁盘访问权限和旧剪贴板密钥访问权限。若剪贴板设置显示保存错误，点击「授权保存历史」并手动完成 macOS 钥匙串授权。原加密历史在授权失败时保留，新增内容暂存内存。

需要在本机持续更新时，可配置固定的本地代码签名身份：

```sh
scripts/create-signing-cert.sh --local
OILFIND_REQUIRE_STABLE_SIGNING=1 scripts/build-app.sh
```

私钥保存在登录钥匙串，初始化访问规则仅允许 Apple 的 `/usr/bin/codesign`。本地配置保存在 `~/Library/Application Support/Oil Find Signing/identity.plist`，只包含固定证书指纹及钥匙串路径；不提交到仓库。脚本不添加系统信任根、不改变钥匙串搜索列表，也不放宽剪贴板密钥的访问规则。签名固定 `com.oiloil.find` 和证书 leaf 指纹作为 designated requirement，构建后验证身份；已配置的身份丢失或损坏时停止，`OILFIND_REQUIRE_STABLE_SIGNING=1` 还会在缺少配置时禁止退回临时签名。`OILFIND_LOCAL_SIGNING_CONFIG` 可指定配置文件，`OILFIND_SIGNING_KEYCHAIN` 可用于初始化独立钥匙串。

现代登录钥匙串还按 CDHash 对自签名程序分区；只有固定证书仍不足以让不同构建复用旧密钥授权。本地固定签名构建因此嵌入 `OilFindClipboardKeyService.xpc`，并在配置目录的 `clipboard-key-service/` 缓存已签名的服务。正常更新只复制该服务，不重编或重签；两端 XPC 连接均核验对方的应用标识和实际证书指纹，服务只访问 Oil Find 的固定密钥项目。密钥只通过验证后的本机 XPC 返回内存，不写入文件或日志，历史密文及加密格式保持兼容。

首次使用新签名私钥时，macOS 可能要求本人允许 `codesign` 使用它；首次迁移到密钥服务时也可能需要本人在「授权保存历史」触发的系统弹窗选择「始终允许」。之后普通应用更新沿用同一服务二进制。配置目录另存 `key-service-identity.plist` 身份记录，缓存丢失或与此记录不符时停止，防止自动重建改变 CDHash。服务源码、证书或缓存哈希变化时同样停止，保留旧应用及缓存，需要明确迁移；锁定钥匙串、私钥丢失也需处理。无参数运行 `scripts/create-signing-cert.sh` 在首次创建时额外生成由本人设置密码的加密备份；`--local` 不导出长期私钥备份，完成后仅在钥匙串中保留私钥。已存在身份时仅复用，并说明本次是否已有备份。Git 提交的 SSH/1Password 签名是另一套身份，不受此代码签名配置影响。

提交 PR 前可运行 `scripts/verify-release-app.sh "build/Oil Find.app"` 检查正式产物。`scripts/verify-clipboard-upgrade.sh` 使用隔离钥匙串和临时稳定签名，验证真实加密历史在退出和升级后恢复；不使用或修改用户的剪贴板历史。引擎对照脚本为 `scripts/compare-engine-performance.py`，运行方法和测量边界见 [验收记录](./docs/SPOTLIGHT_VALIDATION.md)。

## 隐私

- 文件搜索引擎仅读取文件名、大小和修改时间，不读取文件内容；索引保存在本机的 `~/Library/Application Support/Oil Find/`。Pro 图片和文档内容也在本机处理，不上传。
- 剪贴板历史默认关闭；启用后保存获准的文本、链接、支持的粘贴板图片和本地文件/文件夹路径引用，在本机加密并由钥匙串保护。图片保留原始编码 bytes，不做 OCR 或联网；Finder 复制图片文件仍只保存路径引用。文件引用只保存路径，不读取正文或备份文件。可暂停、清空或排除来源应用，升级保留已有开启状态和偏好。
- 来源应用按复制时的前台应用估计，无法保证识别所有敏感内容。密钥不可用或历史损坏时保留原文件并显示错误，新内容暂存内存。
- 网页搜索默认 DuckDuckGo，也可选择 Google 或 Bing。普通查询会提供网页搜索候选，输入 `web:` 可明确请求搜索；只有用户执行该候选时才打开搜索引擎，输入过程中不发送查询内容。
- 汇率换算可在搜索设置中关闭；完整货币表达式会异步请求 Frankfurter 的固定 ECB 汇率列表，不发送金额、完整查询、剪贴板或文件内容。缓存只保存公开汇率、来源日期和取得时间；结果标明参考日期及缓存状态。
- fork 构建不会连接上游官方应用更新服务。Pro 授权会定期联网校验，只发送授权码、设备标识和设备名。

## 目前的限制

- 只支持 Apple 芯片和 macOS 14 及以上。
- 免费文件搜索仅按名称检索；外置磁盘接入时可搜索，若要在拔掉后继续搜索，以及图片和文档内容搜索，属于上游 Oil Find Pro。网络卷暂不支持。
- 剪贴板历史是独立的可选功能，文件记录只保存路径引用。路径移动或删除后无法恢复；整组路径检查失败时保留当前剪贴板，需重新复制文件。

## 项目结构

| 目录 | 内容 |
| --- | --- |
| `Sources/COilFind` | C 代码：批量读取目录、名称比较、搜索评分 |
| `Sources/OilFindCore` | 扫描、索引、文件查询、实时更新、持久化与应用更新 |
| `Sources/OilFindApp` | AppKit 应用库、搜索面板、跨来源协调器、剪贴板与系统集成 |
| `Sources/OilFind` | 可执行应用的组装入口 |
| `Sources/oilfind-cli` | 命令行工具，用来测速和排查问题 |
| `site` | 官网 [find.oiloil.org](https://find.oiloil.org) |

索引的数据结构和设计约束见 [docs/ARCHITECTURE.md](./docs/ARCHITECTURE.md)，开发约定见 [AGENTS.md](./AGENTS.md)。

## 参与贡献

欢迎向本 fork 提 Issue 和 Pull Request，改进文件搜索和统一搜索功能。上游专注文件搜索；搜索已拔掉磁盘中的文件、图片和文档内容属于上游 Pro 功能，由其私有仓库维护，上游不接受实现这些功能的 Pull Request。

本次扩展的自动化、性能及真机验证范围见 [docs/SPOTLIGHT_VALIDATION.md](./docs/SPOTLIGHT_VALIDATION.md)。

## 许可证

本仓库的代码使用 [MIT](./LICENSE) 许可证。Pro 模块不在本仓库里，不开源；Releases 和官网的安装包包含它。
