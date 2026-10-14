# Oil Find 架构

> 本文记录设计约束。性能目标不是实测结论；除非有可复现的基准记录，不应据此宣称百万条索引下的延迟或 macOS 14/15 实机验证。

## 目标

| 维度 | 要求 |
| --- | --- |
| 覆盖 | 默认索引启动卷上的个人文件与应用；依赖目录、包内部、`~/Library`、系统目录可在设置里打开，全开即整盘；免费应用自动索引当前连接的本地外置卷；离线目录由可选扩展提供来源 |
| 速度 | 单来源：3 个字符以上的查询在 1000 万条目上 p95 ≤ 30 ms，单字符 ≤ 80 ms；多来源：85 万 + 两份各 100 万条目时，3 字符以上 p95 ≤ 15 ms，单字符 ≤ 80 ms（验收目标） |
| 实时 | 在线来源的文件新增、删除、改名、移动在 1 秒内反映到索引；卷退出前取消扫描与监听，免费来源撤下并保留目录文件，可选扩展可提供离线来源 |
| 启动 | 启动盘已有索引加载 ≤ 1.5 秒，随后用 FSEvents 历史补齐变动；其他来源在后台载入，不阻塞搜索面板 |
| 内存 | 平均每条目 ≤ 70 字节（含哈希表） |
| 交互 | ⌘Space 默认唤起，面板在屏幕正中，键盘即可完成全部操作 |

免费核心提供文件名与路径搜索。可选私有扩展的产品能力由其独立仓库定义。

### 不做的事

不索引网络卷，不做沙盒化上架或文件内容识别；剪贴板图片由独立的应用层来源处理。外置卷发现、逐盘设置与推出监听由公开应用库负责，核心不依赖 AppKit；磁盘映像只在调试和测试中作为卷索引验证对象。

## 工程结构

```
oil-find/
  Package.swift
  Sources/
    COilFind/                 C：SIMD 子串扫描、目录批量读取、名称比较
      include/coilfind.h
      coilfind.c
    OilFindCore/              Swift：既有索引与文件搜索引擎，不依赖 AppKit
      Classifier.swift     条目分类：kind、包、噪声、隐藏
      IndexStore.swift     SoA 存储、读 API、路径还原
      IndexStore+Build.swift      由扫描结果构建
      IndexStore+Mutation.swift   哈希表、增删改、清扫、压实
      IndexStore+Persistence.swift
      Scanner.swift        并行目录遍历
      Pinyin.swift         汉字转拼音、备用搜索键
      Query.swift          查询语法解析
      Searcher.swift       搜索执行、打分、排序
      FSWatcher.swift      FSEvents 封装
      IndexManager.swift   加载、扫描、监听、保存的编排
      IndexConfig.swift    根路径、排除规则、指纹
      Coverage.swift       未覆盖统计与单路径检查
      SearchCache.swift    增量收窄与结果缓存
      Update/              版本检查、下载、校验与安装
    OilFindApp/               应用库：AppKit、语言管理、SwiftUI 设置与中性扩展点
      ExternalVolumes.swift       本地外置卷发现与 Disk Arbitration 推出监听
      ExternalDriveCatalog.swift  在线索引、逐盘设置、目录持久化与只读通知
      ExternalDriveSettings.swift 外置磁盘免费设置
    OilFind/main.swift        可执行应用的组装入口
    oilfind-cli/              命令行工具，用于验证引擎
  Tests/OilFindCoreTests/
  Tests/OilFindUITests/
  Tests/Scripts/
  site/                       Next.js 官网与更新静态资源
  Resources/Info.plist
  Resources/AppIcon.icns
  scripts/build-app.sh
  docs/
```

`Package.swift`：`swift-tools-version:5.10`，`platforms: [.macOS(.v14)]`。公开 target 为 `COilFind`、`OilFindCore`、`OilFindApp`（library）、`OilFind`（executable）与 `oilfind-cli`，另有核心与应用界面两个测试 target；应用界面测试依赖 `OilFindApp`。应用 bundle id 为 `com.oiloil.find`。

## 开放核心与应用扩展

`Pro/` 是可选的独立私有仓库，不在本公开仓库内，公开 Git 通过 `/Pro/` 忽略它。manifest 用 `Context.packageDirectory` 检测私有模块目录，并通过 `Context.environment` 读取 `OILFIND_FREE=1`，决定是否加入私有 target 与其测试。没有私有模块或显式设置该变量时构建免费版；免费目标的编译标记防止旧构建缓存中的模块影响条件导入。

依赖方向是私有扩展依赖公开应用库与核心。公开库不得依赖或引用私有模块；只有 `Package.swift` 与 `Sources/OilFind/main.swift` 可以提及私有 target。入口只导入模块并调用 `Application.run`，根据构建条件传入可选扩展。

`ApplicationExtension` 提供启动、退出、设置分区、URL、语言及额外搜索来源接口；`searchSources()` 返回来源快照，`onSearchSourcesChange` 通知来源增减、上下线与索引变动。DEBUG 下另有参数预处理方法，让扩展解析并移除自己的调试参数。应用库不理解私有功能状态。公开「外置磁盘」分区放在「索引范围」之后；扩展设置分区放在「外置磁盘」之后、「排除的文件夹」之前；语言变化即时传递，URL 交给扩展处理，无扩展时无操作。扩展只在主线程提交来源快照，功能状态判断不进入扫描或搜索热路径。

`ApplicationExtension.supplementarySearchProvider` 是可选的中性补充搜索接口。宿主在主线程捕获查询、选项与来源，扩展返回可并行执行的工作；补充命中只引用来源 ID 和条目 ID，并可提供延迟生成的附加说明、高亮范围与缩略图标记。名称结果先提交，补充结果按相同查询代次去重后追加；相关度排序保持已显示的名称顺序，其他排序使用相同文件键。刷新时若选中项只在补充结果中，保留当前快照直到两路搜索完成；停用提供方时立即撤下其命中。来源版本不一致和过期查询均不能提交。宿主传递来源变化与可见输入活动；公开库不解释提供方的产品状态或工作内容。

`Searcher.withEntryPredicates` 为同步回调提供按输入顺序编译的条目谓词，复用名称搜索的过滤和路径规则，统一持读锁，不改变原名称搜索计划的执行顺序。结果行附加说明只在渲染时生成，缩略图在图标队列从第一帧读取并按路径与修改时间缓存。

免费版验证使用 `OILFIND_FREE=1 swift build` 与按需筛选的 `swift test`。`Tests/Scripts/test_open_core.py` 检查公开 Git 未追踪 Pro 文件、代码中的私有 target 名称只出现在 manifest 和组装入口，并在 CI 执行。

`AdditionalSearchProvider` 向现有分类栏提供一个额外分类，并返回带稳定身份、展示字段与独立动作的非文件结果。“全部”并行搜索文件和扩展结果，具体文件分类不查询扩展，额外分类只查询扩展。所有结果共用 ResultsView 的行、滚动、选择、刷新与键盘行为，没有独立范围切换或“显示更多”。结果完整返回，表格按需渲染可见行；按现有排序规则合并，非文件结果无法进入文件路径、拖拽、预览或删除动作。新查询按同一代次提交；提供方失效立即撤下其分类与结果。DEBUG 快照通过 `--filter additional` 验证额外分类，私有数据参数由扩展处理并移除。

本地 AI 话题搜索属于免费开源应用，源码在 `Sources/OilFindApp/AITopics/`，测试在 `Tests/OilFindUITests/AITopic*`，资源在应用自己的资源包。`AppDelegate` 管理索引生命周期，搜索和免费设置共用同一管理器，不依赖授权或私有扩展。关闭话题开关撤下分类和命中，退出取消后台任务。来源、增量同步、压缩索引和 CPU 预算见 [AI_TOPICS.md](AI_TOPICS.md)。

## 索引存储 IndexStore

全部数组用 `malloc/realloc` 管理，按条目下标并列存放（SoA）。

| 数组 | 类型 | 长度 | 含义 |
| --- | --- | --- | --- |
| `nameOff` | UInt32 | count + 1 | 名称在 `names` 中的起始偏移；`nameOff[count] == namesLen` |
| `parent` | UInt32 | count | 父条目下标；根条目指向自己 |
| `sizeC` | UInt32 | count | 压缩后的文件大小 |
| `mtime` | UInt32 | count | 修改时间，Unix 秒，越界截断到 0...UInt32.max |
| `flags` | UInt8 | count | 标志位 |
| `depth` | UInt8 | count | 绝对路径的组件数，`/` 为 0，上限 255 |
| `kind` | UInt8 | count | 类型分类 |
| `names` | UInt8 | namesLen | 全部名称的 UTF-8 字节，按条目顺序首尾相接，无分隔符 |
| `altOff` | UInt32 | altCount + 1 | 备用搜索键的偏移 |
| `altOwner` | UInt32 | altCount | 备用搜索键所属的条目下标 |
| `altNames` | UInt8 | altLen | 备用搜索键字节 |
| `table` | UInt32 | max(1024, count × 5 / 4) | (父下标, 名称) → 条目下标 的开放寻址哈希表，空槽为 0xFFFFFFFF |

另有标量：`caseSensitiveNames`（扫描卷的名称比较方式）、`configFingerprint`（配置指纹）、`fsEventsUUID`（FSEvents 流 UUID）、`rootPath`（扫描根的绝对路径，整盘索引为 `/`）、`homeIndex`（当前用户主目录的条目下标，不存在为 0xFFFFFFFF）、`liveCount`、`deletedCount`、`version`（每批变更加一）、`lastEventId`、`scanFinishedAt`。

### 不变量

1. 条目 0 是扫描根，名称为空。
2. 对所有 i > 0，`parent[i] < i`。
3. 条目 i 的名称正好是 `names[nameOff[i] ..< nameOff[i+1]]`。
4. 一个 store 对象生命周期内下标不变。删除只打墓碑标志；压实会生成新的 store 对象。
5. 名称统一为 NFC。含非 ASCII 字节的名称入库前做 `precomposedStringWithCanonicalMapping`。
6. 读操作持读锁，写操作持写锁（`pthread_rwlock_t`）。持锁期间不做文件 I/O。

### 标志位

| 位 | 名称 | 含义 |
| --- | --- | --- |
| 0x01 | dir | 目录 |
| 0x02 | symlink | 符号链接（不跟随） |
| 0x04 | hidden | 名称以 `.` 开头，或带 `UF_HIDDEN` |
| 0x08 | deleted | 墓碑 |
| 0x10 | noise | 位于噪声区域内（从祖先继承） |
| 0x20 | inPackage | 位于某个包的内部（从祖先继承） |
| 0x40 | package | 自身是包（目录且扩展名在包列表里） |
| 0x80 | userArea | 位于当前用户主目录之下（从祖先继承） |

「干净条目」定义：`userArea && !noise && !inPackage && !hidden`。

### 大小压缩

```
encode(size): size < 0x8000_0000 ? UInt32(size) : 0x8000_0000 | min(size >> 12, 0x7FFF_FFFF)
decode(c):    c & 0x8000_0000 == 0 ? UInt64(c) : UInt64(c & 0x7FFF_FFFF) << 12
```

目录的大小记 0。

### kind 取值

| 值 | 名称 | 判定 |
| --- | --- | --- |
| 0 | other | 其余 |
| 1 | folder | 目录且不是包 |
| 2 | app | 扩展名 `app` 的包 |
| 3 | document | pdf doc docx xls xlsx ppt pptx pages numbers key txt md markdown rtf rtfd csv tsv epub mobi odt ods odp tex log |
| 4 | image | png jpg jpeg gif heic heif webp bmp tiff tif svg psd ai sketch fig raw cr2 cr3 nef arw dng ico icns avif |
| 5 | video | mp4 mov mkv avi wmv flv webm m4v mpg mpeg 3gp rmvb |
| 6 | audio | mp3 wav flac aac m4a ogg wma aiff aif opus mid midi caf |
| 7 | code | swift c h m mm cpp hpp cc js jsx mjs cjs ts tsx py rb go rs java kt php html htm css scss less vue svelte astro sh zsh bash json yaml yml toml xml sql lua dart cs r pl gradle plist ipynb |
| 8 | archive | zip rar 7z tar gz bz2 xz tgz zst dmg iso pkg jar war apk ipa |

扩展名取最后一个 `.` 之后的部分，长度 1...8，ASCII 小写后打包成一个 UInt64 作为查表键。包（除 app 外）的 kind 按扩展名查表，查不到为 other。

### 包扩展名

```
app bundle framework plugin kext appex xpc prefpane qlgenerator mdimporter saver component
vst vst3 photoslibrary musiclibrary tvlibrary fcpbundle imovielibrary xcodeproj xcworkspace
playground xcarchive dsym rtfd scptd lproj logicx band screenstudio pages numbers key
```

`pages`、`numbers`、`key` 只在条目是目录时才算包。`lproj` 算包是为了让本地化资源不干扰结果。

### 噪声规则

目录 D 满足以下任一条件时，D 的所有后代带 `noise`：

- D 的名称在此列表中：`node_modules .git .svn .hg __pycache__ .venv venv site-packages Pods DerivedData .gradle .npm .pnpm-store .yarn .cache .cargo .rustup .Trash Caches Cache .next .nuxt bower_components .idea .build .swiftpm CMakeFiles .tox .mypy_cache .pytest_cache .terraform`
- D 带 `hidden`
- D 的深度为 1 且名称是 `System private usr bin sbin opt Library cores` 之一
- D 的名称是 `Library`，深度为 3，且祖父目录名称是 `Users`

`noise`、`inPackage`、`userArea` 都沿父子关系向下继承。主目录条目自身不带 `userArea`，它的后代带。

## 默认排除

排除的目录不进索引、不下探，FSEvents 中位于其下的事件直接丢弃。

绝对路径（`~` 为当前用户主目录）：

```
/System/Volumes
/Volumes
/dev
/cores
/.vol
/private/var/folders
/private/var/db
/private/var/vm
/private/var/run
/Library/Caches
~/Library/Caches
~/.Trash
```

任意层级的目录名：

```
.Spotlight-V100 .fseventsd .DocumentRevisions-V100 .TemporaryItems .Trashes .MobileBackups
```

默认索引范围由四个默认关闭的设置开关控制：

- `indexDependencyDirs`：依赖与构建目录，按 `IndexConfig.dependencyNames` 的目录名集合排除。
- `indexPackageContents`：包自身可搜索，默认不深入包内部。
- `indexUserLibrary`：默认跳过用户 `Library` 的直属文件和大部分子目录；`Mobile Documents` 与 `CloudStorage` 保留，但受限模式仍排除它们。
- `indexSystemDirs`：默认跳过 `/Library`、`/usr`、`/bin`、`/sbin`、`/private`、`/opt` 及 `/System` 的直属文件和大部分子目录；`/System/Applications` 保留。

这些开关不取消默认的固定排除或设备规则。

设备规则：只下探 `st_dev` 属于 {`/` 的设备, `/System/Volumes/Data` 的设备} 的目录。扫描根不是 `/` 时，只允许扫描根自身的设备。

云端占位目录：带 `SF_DATALESS` 标志的目录入索引但不下探，避免触发下载。

受限模式（没有完全磁盘访问权限时）额外排除：

```
~/Library/Containers
~/Library/Group Containers
~/Library/Daemon Containers
~/Library/Mobile Documents
~/Library/CloudStorage
```

`IndexConfig` 持有根路径、两类排除列表、四个索引范围开关、是否受限模式、用户追加的排除路径与 `excludedExtensions`，并提供 `fingerprint: UInt64`（对上述内容做稳定哈希）。指纹变化意味着在线来源的已保存索引作废并自动重建。空扩展名集合沿用原指纹，避免无配置时重建。

用户可在「排除的文件类型」设置扩展名，默认空集合。取文件名称最后一个 `.` 后的部分，不区分大小写；目录和目录包自身不受影响。扫描、直接 FSEvents 与实时子树扫描都在入库前执行相同规则；无配置时跳过扩展名计算，常见 ASCII 扩展名复用 `Classifier.extensionKey` 的 UInt64 键，长扩展名和非 ASCII 扩展名使用预编译的 Unicode 标量规则比较 UTF-8，不逐项创建 String 或分配堆内存。输入仅在回车或失焦时提交，去掉前导点、按空白和逗号分词、转小写并去重，规范化也保留原生撤销记录。

`SettingsPreferences` 保存全局扩展名集合并通知各 `IndexManager`（可注入独立偏好或禁用共享偏好），所以启动卷与扩展提供的卷索引遵守同一排除设置。在线来源重建；离线来源从原目录快照重新载入，在内存中排除相应文件，不扫描、不覆盖原文件。格式 3 的预留头字段（偏移 120）保存不含扩展名的范围指纹，用于识别只有文件类型配置变化的离线目录；旧目录仍兼容。离线目录未曾保存的文件需在卷重新连接并重建后补齐。

## 线程模型

| 线程 | 职责 |
| --- | --- |
| 主线程 | 界面、结果渲染（读锁内取单行数据） |
| 搜索队列 | 串行，userInteractive；内部用 `DispatchQueue.concurrentPerform` 分块并行 |
| 扫描线程 | 应用后台完整扫描最多 2 个，utility 优先级；独立扫描器默认使用 `activeProcessorCount` |
| 事件队列 | 串行，utility；FSEvents 回调与批量应用变更 |
| 保存队列 | 串行，background |

新查询到来时取消正在执行的旧查询：搜索函数接收 `isCancelled: () -> Bool`，每处理完一个分块检查一次。

宿主通过中性的 `SupplementarySearchProvider.backgroundIndexingChanged` 通知补充搜索提供者主索引正在载入、扫描或重建，便于后台内容处理让出资源。补充命中可携带 `sourceVersion`，合并时必须与名称搜索结果的来源版本一致，避免把旧内容绑定到变化后的文件条目。

## 结果的有效性

`SearchResult` 强引用它所来自的 store。全量重扫或压实后 `IndexManager` 换上新的 store 对象，界面收到通知后重新执行当前查询，旧 store 随旧结果一起释放。

查询、类型与排序不变时，所有被动刷新保持精确像素偏移；滚动、惯性滚动和拖动期间合并并延迟刷新。选择通过缓存的文件身份保持，文件删除后落到原位置相邻行而不滚动；列表变短时保留足够的文档高度，避免被新底部钳制。仅键盘导航、新查询、类型和排序变化会主动滚动。面板打开或查询编辑后为输入状态，空格正常输入；键盘导航或鼠标选行后为浏览状态，默认按空格切换 Quick Look，⌘Y 始终可用。组字时按键交给输入法，预览中的方向键更换文件、Esc 只关闭预览。

## 多来源与任意卷索引

`SearchSource` 以稳定的 `id` 标识来源，携带显示名、在线状态和 store。`SearchHit` 保存来源下标与条目下标，另有可选的命中原因字段；条目下标只在对应 store 内有效。`MultiSearchResult` 强引用所有来源及各来源的 `SearchResult`。各来源并行执行原搜索器，各自保留结果缓存和完整的增量收窄候选；合并在读锁内比较分数、名称字节、时间或大小，平分时按来源顺序与条目下标决定顺序。只有启动盘时，应用直接执行原 `Searcher` 和缓存路径。

应用提交查询、来源快照、结果和统计时使用同一查询代次。来源更新使过期查询失效；选择通过来源 ID 和 store 内下标保持，store 替换时才按原路径解析。离线行名称变淡、路径标注未连接；打开、Finder 定位和预览提示来源未连接，复制仍可用，拖动和移到废纸篓禁用。操作开始前再次核对实时来源，避免旧结果执行到刚拔掉的卷。

`IndexManager` 的可选 `volumeUUID` 使配置指纹与卷身份绑定，不因挂载路径变化作废；载入时重设 store 根路径。每个来源使用独立的本机索引文件，`startOffline()` 只后台载入目录，不启动扫描或 FSEvents。在线卷使用 `FSEventStreamCreateRelativeToDevice`，将设备相对事件路径还原到当前挂载点，并兼容本机回调返回的绝对挂载路径；保存该设备的事件位置与日志 UUID。日志 UUID 不同、游标超出设备历史或日志不可用时重新扫描；事件丢失和根变化也触发恢复扫描。每次全量扫描或恢复扫描都先启动 SinceNow 实时流，再读取目录；按路径合并扫描期间的事件，缓冲上限为 8 MiB。旧流的排队回调通过代次隔离，扫描完成后沿用新流，避免再次回放同一段丢失历史而连续重扫。新流真正丢失事件或缓冲超限仍触发下一轮恢复；未解决丢失前不推进旧目录的持久化游标，替换目录在发布前完成可用缓冲的对账。扫描器与事件子树更新器都支持取消，文件描述符关闭与系统调用同步，避免句柄重用竞态。卷发现与推出前通知由公开应用库实现，核心只负责取消、停止和保存。

公开 `ExternalDriveCatalog` 免费管理当前连接的本地、可见、非启动卷，保留 M21 的 UUID 识别、过滤与安全推出规则。总开关默认打开；设置和目录继续使用 `~/Library/Application Support/Oil Find/external-drives/drives.json` 与 `<UUID>.oilfind`，升级不迁移或重写目录。推出审批同步停止整盘或指定分区，并立即撤下在线来源；启动时未连接的目录不载入。重新挂载沿用目录与设备事件游标，有效历史只补齐变化，无历史按核心规则重扫。逐盘关闭或移除会删除该盘目录，移除后的已挂载卷直到下一次连接才重新加入。

`ExternalDriveCatalogReading` 只向扩展提供已知磁盘身份、启用与连接状态、目录 URL 和主线程变化通知。公开层不加载离线来源；可选扩展独立载入未连接盘的本机目录，通过现有 `searchSources()` 提供来源。重新连接、移除或关闭时撤下对应离线来源，宿主合并启动卷、公开在线卷与扩展来源。

## 查询语法与诊断

空格是 AND，`|` 是同一子句里的 OR，OR 两侧可以有空白；不支持括号布尔表达式。含 `/` 的词按路径组件匹配，可组合名称、操作符。`src/` 匹配目录后代，`/src/main` 匹配 src 下以 main 开头的条目。

输入先执行粘贴归一化（去整体引号、file URL 百分号解码、Shell 转义、扩展名后的行列后缀）。含空格的整段路径只在实际存在时作为一个路径词：先查当前索引，未命中时在读锁外最多 stat 一次；不存在时按空格分词。`Query.raw` 是归一化文本。

`!词` 排除文件名包含该词的条目，以及任意上级文件夹名称与该词完全相同（不区分大小写）的条目；上级检查在正向条件通过后执行，使用字节与 parent 链，不创建 String 或逐项分配。单名称保持原有 C 批量评分；名称加 ASCII 名称否定也批量评分，再只检查匹配候选的否定条件。`!path:词` 仍按路径包含匹配，`!src/` 按路径组件排除；拼音匹配用于名称，上级名称按实际名称精确比较。`file:词` / `folder:词` 正向单原子展开为名称 AND 类型筛选，OR 和取反时保持组合原子。

类型为 folder、app、doc、image、video、audio、code、archive；CLI 的 `--kind` 还接受 0…8，非法值报错并非零退出。其余语法：双引号、`*` / `?`、`ext:`、`file:`、`folder:`、`size:`、`dm:`、`path:`、`case:`、`regex:`，见 README。

解析返回可执行 Query 与结构化诊断。无效 regex、kind、size、dm 原子不阻断其他条件；仅无效条件时保留不可匹配的名称条件，不显示最近文件。编辑器通过 UTF-16 光标范围和组字状态延迟诊断，光标仍在词内（含词末）或组字时不报告。诊断、结果与当前查询一起提交；无结果时显示诊断空状态，有结果时底栏显示第一条诊断。⌘/ 打开/关闭语法速查，Esc 先关闭速查；内容与官网语法表逐字一致。

## 未覆盖统计

扫描与增量更新按权限（EPERM/EACCES）、四个范围开关、用户排除、SF_DATALESS 云端目录、/Volumes 下真实挂载点聚合。排除的文件类型单独计数，并可在单路径检查中解释其扩展名。统计单位是实际遇到的被跳过入口，不枚举其后代；增量更新累加观察次数，重扫重置。每类最多 5 个不同示例，满额后只增加计数，路径不写日志。受限配置的额外权限排除归入没有权限。范围排除以配置检查优先匹配的原因计一次；包自身保持可搜索，其未深入内部计作包入口。

统计归属 IndexStore，跟随扫描替换、压实与版本保存；索引格式 3 在原数组后附加有长度上限的统计 JSON，兼容读取格式 2（统计为空），只保留一份索引。设置只展示非零行，范围行展开后按开关显示示例；卷统计按当前挂载点刷新，排除在线且已有索引的来源根路径，不改写 store 中的统计。单路径检查优先交给已提供的来源的中性 `SearchSource.explain(path:)` 回调，限定在该来源根路径内并使用自身索引配置；已知但未连接且没有来源的磁盘显示名称与未连接原因；其余路径由启动卷解释，未接入的外置磁盘和网络卷归为不在索引范围内。磁盘检查在索引锁外执行。

## 更新

发布说明唯一来源为 `site/content/releases.ts`，版本倒序排列，官网 `/changelog` 与 `/en/changelog` 直接读取。`scripts/package.sh` 必须使用已有的「Oil Find Self-Signed」证书签名，从 zip 的实际大小、SHA-256 与当前发布说明生成 `site/public/updates/latest.json`；缺少说明或证书时失败。清单为静态 HTTPS 资源，`Cache-Control: no-cache`，zip 沿用下载目录缓存。应用不使用 Apple Developer ID、Sparkle 或第三方更新包。

`OilFindCore/Update` 提供语义版本、清单、偏好、网络、安装与重启类型。`Resources/Info.plist` 的 `OilFindUpdateChannel=spotlight-fork` 标记使 fork 构建不检查或安装上游官方更新；这类构建需通过本 fork 提供的构建包更新（如有）或自行构建。支持更新的上游构建中，版本遵守 SemVer，预发布版本低于正式版，忽略版本元数据；仅语义版本相同时比较 build。最低系统要求高于当前系统时不提示。`automaticUpdates` 默认为 true；启动 30 秒后检查一次，随后每 24 小时检查。`skippedUpdateVersion` 仅阻止该版本的自动提示，不影响手动检查。网络失败自动检查静默，手动检查报告原因。

版本检查只有一个 GET 请求，使用临时 URLSession，禁用缓存、cookie 和凭证，不携带设备标识、语言或本机路径；User-Agent 为 `OilFind/<版本>`。上游正式应用清单地址固定为 `https://find.oiloil.org/updates/latest.json`，仅上游发行构建启用；fork 标记关闭检查和安装。启用更新时仅接受 HTTPS 下载与清单同一主机的 zip，不跟随重定向。调试版不执行更新检查；快照与临时目录端到端演练入口仅在 DEBUG 编译，正式版没有清单地址覆盖入口。

用户确认安装后，URLSession 下载到临时目录并报告进度；流式校验大小与 SHA-256。在当前应用旁建立同卷、0700 权限的临时工作目录，检查压缩包路径与符号链接后用 `ditto -x -k` 解压。Security 从 `SecCodeCopySelf` 取得当前运行代码，再取得其 designated requirement；新包必须签名有效且满足该要求（同一 bundle id 与证书 leaf 哈希），Info.plist 的 bundle id 必须为 `com.oiloil.find`，版本高于当前并与清单一致。

安装先记录收据，移动当前应用到工作目录的 `previous.app`，再把新应用移到原位置。第二次移动失败立即还原备份；如果还原本身发生文件系统错误，则保留备份，不删除工作目录。当前应用或所在目录不可写时停止，不尝试提权。文件操作与签名校验通过协议注入，所有校验发生在替换之前。

替换后启动分离的等待进程，以位置参数传入路径，等待当前进程退出再用 `open -n -W` 打开原位置的新应用；当前进程正常退出时仍执行索引保存。新进程尽早记录 PID，启动完成后按匹配目标路径、版本和 build 的收据写入独立的 `launch-confirmed` 标记，等待进程收到确认后删除备份与临时目录。清理失败不影响已确认启动的新应用，下次启动再清理。等待进程启动失败时应用还原旧包；`open` 失败、新进程提前退出或 60 秒内没有启动确认时，等待进程停止未完成启动的新进程，还原并重开旧包。旧包按失败标记显示原因并清理临时目录。下载与校验失败清理临时文件，替换失败保留可用应用与必要备份。

`UpdateManager` 在主线程拥有检查、可更新、下载、安装、最新和失败状态；网络与安装不阻塞界面，重复操作在处理中禁用。下载与安装期间禁止提前退出，启动等待进程后才允许正常退出；下载文件在退出前显式清理，不依赖异步任务的 defer。支持更新的构建由菜单显示可用版本与下载进度，更新窗口复用同一状态，设置通用区域提供自动检查开关、提示、手动检查和当前版本；fork 构建隐藏更新入口。双语界面文案集中在 `Sources/OilFindApp/L10n.swift`。


## 应用与官网

### 统一搜索与来源边界

`SearchCoordinator`、`SearchScope` 与 `SearchSnapshot` 都位于 `Sources/OilFindApp/` 的应用层，不属于 `Sources/OilFindCore/`。协调器是搜索面板与各来源之间的编排层，接收当前范围、输入、编辑光标和组字状态，将文件请求送入串行文件队列，将应用、设置、剪贴板及本地工具请求送入来源队列，并以 `SearchSnapshot` 交回 UI。文件查询与来源查询有各自的请求代次和取消判断。快照保留文件结果及其紧凑条目下标，只把有限的应用、设置和工具结果提升为行对象；来源结果不复制或展开整份文件索引。协调器不拥有索引存储，也不把其他来源写入 `IndexStore`。

此次扩展沿用现有 `Sources/OilFindCore/` 文件引擎，不改变其公共接口。紧凑文件来源适配既有 `IndexManager`、`SearchCache` 和 `Searcher`；应用层负责组合不同来源、展示结果和处理范围切换。不得把新增应用能力描述成 Core 文件引擎 API 的变化。

| 来源 | 输入与职责 | 生命周期及边界 |
| --- | --- | --- |
| 文件 | 紧凑文件来源包装现有 `IndexManager` / `IndexStore`，提供名称查询、文件类型筛选、Quick Look 和现有文件操作 | 索引加载、扫描、FSEvents、保存沿用索引生命周期；只读取名称、大小、修改时间等索引字段，不读文件内容 |
| 应用 | `ApplicationCatalog` 枚举可启动应用并按查询排序 | 应用启动时后台枚举并观察目录，应用退出时停止；目录变化合并刷新并更新修订号，不改变文件索引范围 |
| 剪贴板 | `ClipboardHistory` 监视获准的纯文本、链接、受支持的栅格图片及本地文件/文件夹路径引用，搜索与管理历史；一组多文件作为一条记录 | 默认关闭，首次启用后开始记录，保留已有开启状态和偏好并兼容已有 AES 加密文本归档。默认保留 7 天和 500 条，可设为 1…365 天和 1…10,000 条。每条文本 UTF-8 最多 256 KiB；每条文件记录最多 1,000 个路径，所有路径 UTF-8 总计最多 256 KiB；合计最多 32 MiB。截图及 PNG/JPEG/TIFF/GIF/HEIC/WebP/BMP 等系统 ImageIO 可解码的栅格图保留原始编码 bytes 和格式、像素尺寸元数据；单图最多 16 MiB 和 64 百万像素。不做 OCR 或联网。图片行有缩略图并支持预览；⌘C 恢复图片原始表示及兼容 PNG，Return 沿用既有目标应用、焦点和辅助功能权限检查。Finder 复制的图片文件仍只保存路径，不读取文件；一般文件引用不读取或备份正文。文件承诺中尚未生成的内容不采集；concealed、transient、autogenerated 标记及来源应用排除继续生效，默认排除已知密码管理器。CryptoKit AES-GCM 加密本机归档（含图片 bytes 和文件路径引用），密钥保存在仅此设备使用的钥匙串项目；暂停、清空、失效密钥和应用退出都由该来源管理 |
| 计算与单位 | `LauncherTools` 在当前输入满足语法时解析算式与单位换算 | 不创建网络请求；与文件索引和剪贴板存储无关 |
| 汇率 | `CurrencyQuery` 识别完整货币表达式，`CurrencyRateProvider` 提供 ECB 每日参考汇率，通过 EUR 交叉换算 | 只在全部范围、启用汇率且非组字时按需异步取固定货币列表；网络、JSON 和公开汇率缓存不阻塞文件队列，退出时取消请求 |
| 网页搜索与网址 | `LauncherTools` 识别网址与 `web:` 显式搜索；统一范围下也可显示普通查询的网页搜索候选 | 键入过程不发网络请求。默认 DuckDuckGo，可选 Google 或 Bing；仅当用户执行候选操作时打开 HTTPS URL |
| 设置 | `SystemSettingsCatalog` 匹配系统设置条目与别名 | 仅在设置范围或全部范围查询时生成候选；打开系统设置的入口按系统支持的 URL 与回退地址处理 |

文件来源是应用层 `SearchCoordinator.refreshFiles` 对现有 `IndexManager`、`SearchCache` 和 `Searcher` 的紧凑适配；它沿用原来的索引生命周期。应用目录和剪贴板由独立来源对象管理；计算、网址与网页搜索是纯输入解析工具，并不维持后台服务。切换到仅来源范围时旧文件查询会被新代次取消，结果快照只暴露所选范围；全部范围可以并列组合文件和其他来源。应用启动时启动来源生命周期；用户启用的剪贴板记录在面板隐藏后继续运行，退出应用时停止并提交待保存数据。提供方错误只影响对应来源，不得使文件索引失效。

上游 1.6.0 的公开 `ExternalDriveCatalog` 与可选扩展共同提供额外文件来源；AppDelegate 合并它们，并将来源变化发送到统一协调器与设置模型。连接卷的结果可以在启动卷索引尚未加载时独立发布，保留全部范围和文件筛选。推出审批先同步停止索引、撤下在线来源，再排队刷新界面；旧显示在刷新前已经无法执行文件操作。公开外置磁盘设置放在索引分区，其开关和逐卷目录沿用上游存储；剪贴板路径引用与该目录分离，不读取文件正文。应用退出同时停止剪贴板等补充来源和外置卷目录，固定 XPC 密钥服务不参与文件索引生命周期。

应用与文件的重复项使用共同的文件路径身份去重。少量已提升的应用先解析成文件 ID，随后对结果的紧凑 ID 数组做一次 SIMD 批量扫描，生成有限的移除位置；扫描不创建逐文件行对象。可见行按需解析路径。后续来源发布按稳定身份恢复用户选择，文件来源暂时不可用时保留文件身份与视口，文件返回后恢复；用户再次导航会取消旧恢复锚点。

被动刷新保留视口像素位置；结果缩短时暂时保留足够的表格高度，滚动、拖拽期间合并延期刷新和文案更新。新查询重置该高度，用户主动导航仍可移动选择及视口。文件来源撤销后，剩余来源的异步查询完成前可保留旧显示，但当前来源校验立即拒绝失效文件操作。应用启动也在执行前核对当前应用目录，避免已移除或排除的应用从暂留结果中启动。

Space 预览只在用户开始浏览结果且开启对应偏好时触发，文件与剪贴板行支持该操作；应用、系统设置、计算和网页行继续允许输入空格。键入、面板重新打开和语法示例会退出浏览状态，中文组字期间按键交给输入法。Home/End 按统一结果总行数导航，文件类型排除沿用上游 `excludedExtensions` 及其索引配置，不增加文件正文读取。

⌘⌫ 复用搜索框清空按钮的执行路径，清空所有文字并重新搜索，保留输入焦点和分类；不论光标位于开头、中间或选中部分文字，均不执行文件回收或历史删除。中文组字继续交给输入法，普通 Backspace 沿用文本编辑。文件和剪贴板删除仅通过对应右键菜单执行。

`SearchQueryRetention` 默认保留搜索词至面板关闭满 60 秒。`panelDidHide` 记录隐藏时间，`panelWillShow` 读取当前偏好并检查过期，只在重新唤起时清空查询和重新发布结果，不用轮询计时器，也不会打断可见面板内的输入。可选立即、60/300/900 秒及始终保留，未知偏好值回退到 60 秒；分类与文件筛选保留。测试注入时钟，不等待真实过期时间。

汇率结果使用独立的稳定身份，加载、成功和失败重试状态只刷新补充来源，协调器仍按查询代次和来源请求版本拒绝过期提交。`100 usd in to rmb`、`100 USD to CNY` 和 `100美元转人民币` 映射为明确的货币对，RMB 是 CNY 的别名。请求固定为 Frankfurter 的 ECB EUR 基准货币列表，不包含金额、完整输入、文件或剪贴板数据；参考日期和缓存状态在行副标题中展示。公开汇率缓存 24 小时，过期数据用于明确标注的离线回退，失败短期退避并提供 Return 重试；同币种计算无需网络。普通计算与单位换算保持离线。快照和自动测试采用合成汇率，不读取用户缓存或联网。

剪贴板默认关闭，首次启用是开始记录的入口；启动监视时先记录 pasteboard change count 基线，不收集启用前的内容。升级保留已有开启状态和偏好，AES-GCM 归档兼容已有文本历史。历史接收获准的单项纯文本（链接作为普通文本保存）、粘贴板截图和系统 ImageIO 可解码的栅格图片，以及本地文件和文件夹的路径引用；采集时只解析实际 file URL / legacy filenames 路径引用，不为每次采集逐个 stat 文件。Finder 复制的图片文件仍只作为路径引用保存，不读取文件。图片保留原格式编码 bytes 与格式、像素尺寸元数据，格式包括 PNG/JPEG/TIFF/GIF/HEIC/WebP/BMP 等可解码栅格图；单图上限为 16 MiB 和 64 百万像素，历史总量上限为 32 MiB。图片不做 OCR 或联网。图片历史行提供缩略图和预览；⌘C 恢复原始图片表示及兼容 PNG，Return 沿用已有目标应用、焦点和辅助功能权限检查后尝试直接粘贴，未通过时只复制并提示。一组多文件保存为一条历史，列表显示名称和数量，搜索匹配文件名与路径；文件引用不备份或读取文件正文，也不扩展文件索引的读取范围。每条文本 UTF-8 上限 256 KiB；每条文件记录最多 1,000 个路径，路径 UTF-8 总计最多 256 KiB。文件承诺中尚未生成的内容，以及 concealed、transient、autogenerated 标记排除。默认排除密码管理器来源，并可在设置中选择其他应用排除；这些规则同样约束图片和文件引用。暂停后不接收新项目；清空后删除本地密文记录。

后台钥匙串读取同时禁止 LAContext 和传统 macOS Keychain 的交互，传统接口的进程内交互状态在串行请求后恢复。访问失败时保留原密文并显示错误，新增记录只留在内存；设置中的「授权保存历史」是唯一请求交互授权的入口。该入口创建新的存储实例，只有成功读取原归档后才合并当前记录并恢复保存；拒绝授权或损坏归档都不能覆盖原文件。等待显式授权时退出应用不会同步等待系统安全对话框。

本地持续构建可使用 `scripts/create-signing-cert.sh --local` 配置登录钥匙串中的固定签名身份。临时 PKCS#12 传输和一次性密码仅存放在 0700 临时目录中，密码通过文件传给独立的 Security helper，不进入进程参数；helper 禁止交互导入，为新签名私钥指定仅 `/usr/bin/codesign` 的初始访问规则。结束时删除临时私钥、传输文件和密码，不修改系统 trust、搜索列表或现有剪贴板密钥 ACL。公开本地配置以 0600 plist 保存证书 SHA-1 和钥匙串路径。

`build-app.sh` 用证书指纹选择身份，并显式嵌入 `identifier "com.oiloil.find" and certificate leaf = H"…"` 的 designated requirement，签名后验证该要求。指纹缺失、配置损坏或身份不可用时保留原产物；自动更新使用 `OILFIND_REQUIRE_STABLE_SIGNING=1`，配置缺失也不生成临时签名。

打包仅复制当前 package 声明的资源 bundle，并写入与主程序、固定服务相同的暂存应用。资源缺失或 package 描述失败时停止，保留旧应用及其资源；全部资源与签名校验完成后再提升整个 bundle，避免更新过程中修改旧产物。

现代登录钥匙串对无法归类为 Apple 开发者签名的代码仍采用 `cdhash:` partition，固定自签名证书的不同二进制也不能仅靠相同 DR 访问旧项目。本地固定签名构建使用 `scripts/prepare-key-service.sh` 编译并签名 `OilFindClipboardKeyService.xpc`，首次缓存到签名配置目录的 `clipboard-key-service/`；其 manifest 记录公开证书、源码及可执行文件 SHA-256，并在缓存外原子保存 `key-service-identity.plist` 固定身份记录。后续构建核验三者、身份记录和服务签名后原样嵌入，不能重签嵌套服务。已有缓存尚无身份记录时，只在完整校验通过后补记；已有身份记录但缓存缺失时拒绝重建。缓存损坏、源码变更、证书变化都失败并保留旧产物，服务升级需显式迁移及必要的本人授权。

`ClipboardKeyAccess.swift` 是应用和独立服务共用的钥匙串操作与协议源，不依赖文件引擎或界面。服务只接受同 UID、`com.oiloil.find` 且使用其同一实际 leaf 证书的主程序，主程序也用对应服务标识与证书核验服务。连接采用 macOS 13 起的 `NSXPCConnection.setCodeSigningRequirement`，由 XPC 核验实时 peer；不以 PID 或路径替代身份。仅传递创建标志、显式交互标志和 32 字节密钥/错误；调用者不能指定其他 service/account。密钥只进入应用内存供原 AES-GCM 存储使用，不导出到文件、命令行或日志。客户端在后台存储队列等待，超时、中断及迟到回复均使本次请求失败且不影响下一次；读取失败不降级为直接访问。设置授权按钮是服务交互的入口。未配置本地身份的构建、CLI 和明确指定隔离钥匙串的测试保留原直接路径，原历史格式及密钥项目不变。

服务的 `XPCService.JoinExistingSession` 必须为 true，使其加入主应用的登录会话并可在明确请求时展示系统授权。钥匙串操作对交互状态进行串行、临时切换并恢复原值。连接中断或失效立即标记对应 lifetime，拒绝尚未开始的排队请求；已开始的 Security 调用无法取消。修改服务会话配置后必须重新启动父应用，现存 launchd job 不会因磁盘上的 bundle 变化自动采用新配置。

用户对文件历史项执行 ⌘C 时，将整组路径恢复为真正的文件 URL pasteboard 项，使用户回 Finder 按 ⌘V 能复制文件。Return 沿用直接粘贴流程：在用户明确选择粘贴后验证原目标应用仍在运行、窗口焦点与辅助功能权限，再发送 ⌘V；不会读取目标应用内容。权限或焦点等检查失败时只复制到系统剪贴板，并明确提示仅完成复制。无论使用 ⌘C 还是 Return，整组文件存在性校验都在专用后台队列执行，逐项检查取消状态；2 秒失败期限防止网络位置一直等待。后台系统调用不能强行中断，但超时或取消后的完成回调不能修改剪贴板。写入前重新检查查询代次、分类、选中条目的身份和内容，以及面板的显示、焦点与隐藏状态；修改查询、切换选中项、删除历史或关闭面板取消旧操作。任一路径失效时不替换当前剪贴板、不继续粘贴，并提示重新复制文件。路径移动或删除后无法从历史恢复文件。

默认全局快捷键为 ⌘Space，默认注册值来自 UserDefaults 注册域；已保存的 `hotKeyCode` 与 `hotKeyModifiers`（包括用户自定义值）会覆盖注册默认值。若默认 ⌘Space 注册失败，AppDelegate 会临时尝试注册旧快捷键 ⇧⌘F，并显示实际绑定状态；该回退不写入或覆盖保存的快捷键。设置页提供 Spotlight 系统快捷键入口、路径提示、重试及自定义录制。快捷键录制器的 Delete 重置为新的 ⌘Space。⌘0…⌘4 按应用层 `SearchScope.allCases` 顺序切换全部、应用、文件、设置、剪贴板范围；⌥⌘1…9 选择文件类型。Tab 在文件范围切换文件类型；数字快捷键按修饰键和面板上下文分发。

### 官网边界

Oil Find 是 MIT 许可证下的免费开源软件，搜索始终可用。应用不包含试用、付款、激活、设备身份或授权网络请求。启动时静默尽力删除旧版授权文件、偏好与试用钥匙串项，失败不影响使用。

`AppLanguage` 管理系统默认、简体中文和英文三种语言选择；语言偏好保存在 UserDefaults，`Sources/OilFindApp/L10n.swift` 是免费应用界面文案的唯一来源。语言变化通知搜索面板、菜单、欢迎页、设置及更新窗口即时重新显示文案。

`site/` 是 Next.js App Router、React 和 TypeScript 官网，使用 pnpm 开发，运行时依赖包括 `next`、`react`、`react-dom` 与用于 Pro 许可接口的 `stripe`。中文首页为 `/`，英文首页为 `/en`；首页包含可交互的文件查询演示及搜索范围演示，并保留上游 Pro 介绍、结账、许可激活与恢复流程。演示数据必须是代码中定义的合成样例；不得访问访问者剪贴板、文件系统、输入历史或调用搜索引擎 API。网页搜索演示只在提交后导航到所选引擎。中文、英文页面均说明剪贴板默认关闭、加密存储和用户控制。更新日志位于 `/changelog` 与 `/en/changelog`。旧 `/activated`、`/recover` 及对应英文路径永久重定向到各自语言首页。fork 应用包关闭上游官方应用更新，不会从上游更新服务器安装版本。Pro 结账和许可接口使用 Stripe；本地开发按官网文档配置所需环境变量。

网站演示的固定样例数、状态和交互反馈不是应用索引内容，也不能被描述成真实设备上的性能测量。范围演示使用人工定义的文件、应用、设置和剪贴板样例；计算与换算显示示例结果，不在浏览器执行真实计算。网站输入期间不联网；只有用户提交网页搜索表单时才按所选引擎导航。项目的 macOS 部署目标不等于 macOS 14 或 15 实机验证；百万级索引和延迟描述只有在对应机器、索引、命令、样本及结果可复现时才可作为实测结论。

版本与 build 来自 `Resources/Info.plist`。`scripts/build-app.sh --debug` 打包的调试版提供 `--snapshot` 界面快照；正式版没有该入口。正式版在签名前移除包含本机源码路径的调试符号；调试版保留调试信息。`scripts/package.sh` 生成版本安装包、通用下载包与更新清单，不执行部署。

构建要求包含 macOS 15.4 及以上 SDK，运行部署目标仍为 macOS 14。CI 使用 macos-15 和显式 Xcode 16.4（SDK 15.5），同时检查 Release 编译、正式应用签名和 ZIP 解压后的产物。应用先在临时目录构建并验签，成功后替换旧产物；失败保留旧产物并清理临时目录。

## 原生截图模块

蒙层的选中区域以 2% 黑色及 `.copy` 混合绘制，保持非零像素透明度。不能用 `.clear` 挖洞，否则原生窗口命中可能穿透选窗高亮，使下方应用收到鼠标并触发失焦取消；直接向视图投递事件无法覆盖这一步。像素及 WindowServer 原生鼠标命中回归覆盖悬停与待确认状态，应用日志只保留会话阶段、取消原因、尺寸及错误码。捕获后端继续排除整个应用，因此这层鼠标表面不会污染成品。

`CaptureCoordinator` 管理捕获代次、选区蒙层、流会话、多个编辑窗口、OCR 和钉图文。`CaptureBackend` 可注入，生产实现以 ScreenCaptureKit 的 macOS 14 `SCScreenshotManager.captureImage`、`SCContentFilter` 和 `SCStream` 工作，不调用 15.2 / 26 新增捕获接口。屏幕权限只在主动执行捕获时请求。窗口按真实屏幕层次识别，跨屏选区使用 Quartz 全局坐标和最高参与缩放比例，透明保留显示器间空隙；过滤 Oil Find 整个应用以排除后来创建的蒙层、工具条与钉图窗口。

选区蒙层采用 `.nonactivatingPanel` 的 `NSPanel`，显式将内容视图设为第一响应者并接受首次鼠标点击，不依赖异步应用激活。局部键盘监听只处理当前会话的已知动作，无窗口事件回退到当前 key window；内容视图保留 `keyDown` / `cancelOperation` 响应链兜底。蒙层失去 key 状态后在下一主队列回合检查全部蒙层，跨屏焦点转移继续会话，其他失焦取消捕获。另监听工作区激活通知，并通过可注入的前台进程读取核对当前状态及上次激活进程；重复激活与晚到通知不取消选窗，自身激活更新状态但不取消，真正切到其他应用时仍取消，即使蒙层暂时保留 key 状态。关闭移除全部监听及观察。失焦取消不重新激活旧应用，不使用全局键盘监控或新增隐私权限。

`LauncherRow.action(CaptureAction)` 仅在全部范围匹配固定命令、英文及拼音键，执行时分派给协调器；不进入文件动作，也不增加文件查询对象或改索引格式。`HotKey.Identifier.search`、`.capture` 和 `.captureCopy` 使用不同事件 ID，Carbon 回调必须同时匹配 signature 和 ID。普通截图与直接复制截图的快捷键偏好独立保存，期望绑定、实际状态、系统冲突和录制分别管理；系统偏好只读。普通选区待确认时可重选，确认只分派一次。蒙层区分清除选择与重选区域：Space 清除选择并切换模式，忽略长按重复事件；R、重选按钮及待确认后的重画返回区域模式，避免选窗状态粘滞。键盘监听只消费蒙层窗口事件，鼠标处于屏幕空隙时仍选取可用蒙层窗口接收取消；`.copyRegion` 松开鼠标后直接复制 PNG，再按原政策保存两种历史，整个路径不创建编辑器。编辑器重选打开新文档，保留旧文档和未保存标注；所有捕获与编码回调仍核对查询代次。

`CaptureScrollStitcher` 只接收连续稳定帧。先采样筛选重叠候选，再验证所有行且要求唯一；保留固定边缘一次，仅追加新行。匹配不确定、动态或重复内容时不追加、不改变最后成功帧；尺寸和容量检查失败时保留已有内容。仅会话内开启屏幕流，用户负责滚动，工具不发送滚动事件。

`CaptureDocument` 保存编码原图、像素坐标裁剪和可编辑标注对象；`CaptureEditorModel` 以文档快照实现撤销重做，预览按需缩小解码，多个文档使用原生标签窗口。`CaptureRenderer` 在独立像素画布合并标注、裁剪和遮挡，导出 PNG / JPEG 不携带原图、图层或原文件元数据。`CaptureMaterial` 仅包含所选对象及被引用资源。OCR 主动使用 Vision，在后台执行并提供可编辑文本；钉图文窗口只存于当前进程。

`CaptureArchive` 使用已有 `ClipboardKeyProviding` 主密钥，HKDF 的 history / materials 用途分别派生 AES-GCM 存储密钥。不增加钥匙串项目或修改固定服务、证书、访问规则。目录 0700、文件 0600；加密索引和 UUID 文档、缩略图文件分别存储。先写全新的不可变加密文件，再原子提交索引，成功后才删除旧版本；失败保留原索引和旧文件。索引仅解码元数据，文档及可见缩略图按需加载。密钥或旧存档损坏会保护原档并显示错误，不能生成替代密钥覆盖。可编辑历史保留打码前原图，界面和隐私说明必须明确告知。

默认截图历史为 7 天 / 100 张 / 256 MiB，设置可关闭或调整。原剪贴板策略继续独立生效；生成图片使用自身标记并显式记录，只有开启且未暂停、来源未排除且满足原 16 MiB / 32 MiB 容量时才进入剪贴板历史。未完成捕获、取消或仅复制 OCR 文本不保存整张截图。安装前必须检查两种历史的保存状态以及未保存编辑，完整流程见 `docs/CAPTURE.md`。DEBUG 额外提供纯合成截图快照及固定服务跨构建恢复探针，正式版不包含这些入口。
