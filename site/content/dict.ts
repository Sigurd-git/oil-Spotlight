import updateManifest from '@/public/updates/latest.json';

export type Language = 'zh' | 'en';

export interface HomeItem {
  icon: string;
  name: string;
  path: string;
  meta: string;
  meta2?: string;
  act: { href?: string; scroll?: string; fill?: string };
}

interface LandingCopy {
  captureTitle: string;
  captureBody: string;
  capturePrivacy: string;
  captureShortcut: string;
  title: string;
  description: string;
  placeholder: string;
  sort: string;
  dl: string;
  downloadNote: string;
  openSource: string;
  toastDemo: string;
  noneTitle: string;
  noneBody: string;
  folder: string;
  app: string;
  'nav.speed': string;
  'nav.syntax': string;
  'nav.github': string;
  'nav.download': string;
  'nav.lang': string;
  'speed.h': string;
  'speed.sub': string;
  'speed.frame': string;
  'stat.scan': string;
  'stat.mem': string;
  'stat.live': string;
  'speed.fine': string;
  'syn.h': string;
  'syn.sub': string;
  'source.download': string;
  'source.github': string;
  'note.open.h': string;
  'note.open': string;
  'note.opensource.h': string;
  'note.opensource': string;
  'note.fda.h': string;
  'note.fda': string;
  'note.privacy.h': string;
  'note.privacy': string;
  'legal.github': string;
  'legal.download': string;
  lead: string[];
  chips: string[];
  hints: [string, string][];
  syntax: [string, string, string][];
  home: HomeItem[];
  statusHome: (n: number) => string;
  statusDemo: (n: number) => string;
  statusReplay: (hits: string) => string;
  items: (n: string | number) => string;
  today: (time: string) => string;
  yesterday: (time: string) => string;
  date: (month: number, day: number) => string;
  bytes: (n: string) => string;
  scopeTitle: string;
  scopeSubtitle: string;
  scopeTabs: string[];
  scopeAllItems: string[];
  scopeKeyboard: string;
  scopeApps: string[];
  scopeSettings: string[];
  scopeClips: string[];
  scopeSampleTag: string;
  scopeClipboardNote: string;
  scopeCalcLabel: string;
  scopeCalcResult: string;
  scopeDemoCurrencyResult: string;
  scopeDemoCurrencyRate: (date: string) => string;
  scopeDemoCopyHint: string;
  scopeDemoCopied: string;
  scopeDemoCopyUnavailable: string;
  scopeDemoUnsupported: string;
  scopeWebLabel: string;
  scopeEngineLabel: string;
  scopeSubmit: string;
  scopeUrlLabel: string;
  scopeUrlOpen: string;
  scopeEngines: string[];
  scopeOfflineNote: string;
}

export const GITHUB_URL = 'https://github.com/oil-oil/oil-find';

export const dict: Record<Language, LandingCopy> = {
  zh: {
    captureTitle: '原生截图、标注与可编辑历史',
    captureBody: '选区、窗口、鼠标所在屏幕和手动滚动长截图；选区可重新选择，编辑器重选保留原文档。箭头、文字、画笔、高亮、马赛克、实色遮挡、裁剪、Emoji、贴纸及素材复用。普通截图先编辑，再复制、PNG / JPEG 保存或钉住；直接截图模式松开鼠标后复制，不打开编辑器。已有图片与剪贴板图片也可继续编辑。识字由用户主动执行，在本机使用 Vision。',
    capturePrivacy: '独立截图历史默认加密保存 7 天、100 张，最多 256 MiB；可编辑历史保留打码前原图，导出文件只含合并后的像素。钉图文仅在本次运行显示。此图是合成应用快照，网站不会截取屏幕。',
    captureShortcut: '⌘⇧4 选区并编辑；⌃⇧⌘4 直接复制截图。两者可分别设置；如被系统截屏占用，在设置 → 截图查看冲突引导，搜索命令和菜单栏仍可用。首次捕获需要本人授予屏幕录制权限。',
    title: 'Oil Find：文件、应用、剪贴板，一处搜索',
    description: '按 ⌘Space 打开 macOS 搜索面板。搜索文件与应用，选择性保存剪贴板文本、链接、图片和本地文件路径引用，离线计算和单位换算；网页搜索只在你提交时打开。免费版采用 MIT 许可证并始终免费；Pro 是独立的闭源付费扩展。',
    'nav.speed': '功能', 'nav.syntax': '语法', 'nav.github': 'GitHub', 'nav.download': '下载', 'nav.lang': 'EN',
    lead: ['文件、应用、剪贴板，', '一处搜索'],
    placeholder: '在这里试试：wd、png、readme',
    sort: '相关度 ⇅',
    dl: '免费下载 macOS 版',
    downloadNote: 'macOS 14 及以上 · Apple 芯片',
    openSource: '免费开源',
    'speed.h': '从文件到计算，按需切换',
    'speed.sub': '文件和应用留在搜索面板里；剪贴板记录默认关闭；计算与单位换算离线完成。汇率换算可单独关闭，完整表达式只请求固定的 ECB 公开汇率，缓存 24 小时；结果显示汇率日期与缓存状态。网页搜索由你明确提交。',
    'speed.frame': '',
    'stat.scan': '文件名索引', 'stat.mem': '剪贴板', 'stat.live': '计算、汇率与网页搜索',
    'speed.fine': '下面的范围演示只使用网页内置的合成样例，不会读取你的文件、剪贴板或搜索历史。',
    'syn.h': '想找得更准，就多写一点',
    'syn.sub': '点一行，把它填进上面的搜索框。',
    'note.privacy.h': '隐私', 'note.privacy': '文件引擎只读取名称、大小和修改时间。剪贴板记录默认关闭，启用后保存获准的文本、链接、粘贴板图片和本地文件/文件夹路径引用，在本机加密并由钥匙串保护；图片保留原始编码内容，不自动做 OCR 或联网，可主动在截图工具中识字，单图最多 16 MiB、6400 万像素，历史总量最多 32 MiB；Finder 复制图片文件仍只保存路径，不读取正文。敏感、临时、自动生成标记、来源应用排除及尚未生成的文件承诺限制继续生效。汇率来源只接收固定的公开币种列表，不发送金额或完整查询。网页搜索只在你选择并提交后打开；fork 构建不连接上游官方应用更新服务。 独立截图历史和素材使用派生密钥加密；可编辑历史保留打码前原图，导出仅含最终像素。截图历史默认 7 天、100 张、256 MiB，可关闭。屏幕录制只在主动截图时请求，钉图文退出后不恢复。',
    'source.download': '下载 macOS 版',
    'source.github': '在 GitHub 上查看',
    'note.open.h': '第一次打开', 'note.open': '应用还没有经过苹果公证。双击后如果被拦下，去「系统设置 → 隐私与安全性」，在底部点「仍要打开」。只需要一次。',
    'note.opensource.h': '开源', 'note.opensource': '免费版的代码在 GitHub 上，MIT 许可证，欢迎提问题和改进。Pro 功能不开源。',
    'note.fda.h': '完全磁盘访问', 'note.fda': '可选。不开也能用，只是搜不到邮件和其他应用的数据。',
    'legal.github': 'GitHub', 'legal.download': '下载 macOS 版',
    chips: ['全部', '文件夹', '应用', '文档', '图片', '代码'],
    hints: [['↩', '打开'], ['↑↓', '选择'], ['Tab', '切换筛选']],
    statusHome: n => `从这里开始 · ${n} 项`,
    statusDemo: n => `演示数据 · 共 ${n} 项`,
    statusReplay: hits => `合成演示 · ${hits} 项`,
    toastDemo: '这里是演示 · 装上之后按 ↩ 直接打开文件',
    noneTitle: '没有匹配的结果',
    noneBody: '这里只有十几个演示文件。装上之后，搜的是你自己的 Mac。',
    items: n => `${n} 项`,
    today: t => `今天 ${t}`, yesterday: t => `昨天 ${t}`, date: (m, d) => `${m}月${d}日`,
    folder: '文件夹', app: '应用', bytes: n => `${n} 字节`,
    scopeTitle: '选一个范围试试',
    scopeSubtitle: '应用搜索词默认在面板关闭 1 分钟后过期，可在设置中调整。此处是合成演示，网站不会读取本机文件或剪贴板。',
    scopeTabs: ['全部', '应用', '文件', '设置', '剪贴板', '计算示例', '网页搜索'],
    scopeAllItems: ['README.md · ~/Documents', '日历 · 日程与会议', '剪贴板示例 · 文本、链接与图片', '12 × 8 + 5 · 离线结果 101'],
    scopeKeyboard: '⌘0…⌘4 切换范围 · ⌥⌘1…9 选择文件类型',
    scopeApps: ['日历 · 日程与会议', '计算器 · 最近使用', '代码编辑器 · 项目'],
    scopeSettings: ['键盘快捷键 · 键盘', '隐私与安全性 · 系统设置', '显示器 · 显示'],
    scopeClips: ['会议安排：周四下午 2 点', 'https://example.com/research', '截图示例 · PNG 图片'],
    scopeSampleTag: '合成示例',
    scopeClipboardNote: '应用中的剪贴板历史默认关闭，升级保留已有开启状态和偏好，并兼容原 AES 加密文本历史。启用后记录获准的文本、链接、截图及 ImageIO 可解码的栅格图片（如 PNG、JPEG、TIFF、GIF、HEIC、WebP、BMP），以及本地文件/文件夹路径引用。图片保存原始编码内容和格式、像素尺寸元数据；单图最多 16 MiB、6400 万像素，历史总量最多 32 MiB。图片不会自动做 OCR 或联网，可主动在截图工具中识字；行内显示缩略图并支持预览；⌘C 恢复真实图片及兼容 PNG 表示。Finder 复制的图片文件仍只存路径，不读取文件。一组多文件显示名称和数量，可按名称或路径搜索；文件历史项按 ⌘C 恢复文件 URL，回 Finder 按 ⌘V 复制文件。Return 沿用既有目标应用、焦点和辅助功能权限检查后尝试粘贴，检查失败时只复制并提示。文件移动或删除后无法恢复；整组路径检查失败会保留当前剪贴板，并提示重新复制。敏感标记、来源应用排除和暂停规则仍生效，可暂停、清空或排除来源应用。此处内容仅为合成演示。',
    scopeCalcLabel: '输入算式或换算示例', scopeCalcResult: '离线结果',
    scopeDemoCurrencyResult: '合成演示结果', scopeDemoCurrencyRate: (date: string) => `演示汇率：1 USD = 7.00 CNY · 日期：${date}。固定示例值，不联网，也不是当前汇率。RMB 对应 CNY。`,
    scopeDemoCopyHint: '按 Return 或 ⌘C 复制演示结果。', scopeDemoCopied: '已复制合成结果。', scopeDemoCopyUnavailable: '浏览器未允许复制；请手动选择结果。',
    scopeDemoUnsupported: '此处只演示 100 USD 转 CNY；其他货币表达式没有合成结果。真实应用可按设置启用汇率换算。',
    scopeWebLabel: '搜索词', scopeEngineLabel: '搜索引擎', scopeSubmit: '提交并打开搜索',
    scopeUrlLabel: '网址会直接打开', scopeUrlOpen: '打开示例网址',
    scopeEngines: ['DuckDuckGo', 'Google', 'Bing'],
    scopeOfflineNote: '普通计算与单位换算离线完成；应用汇率换算是单独开关。此网站演示不联网。网页搜索不会随键入发送内容。',
    home: [
      { icon: 'download', name: '下载 Oil Find', path: '免费开源。macOS 14 及以上，Apple 芯片', meta: updateManifest.version, meta2: '1.5 MB', act: { href: '/downloads/Oil-Find.zip' } },
      { icon: 'timer', name: '一个面板，多种搜索范围', path: '文件、应用、设置、剪贴板、离线计算和网页搜索', meta: '范围', act: { scroll: 'scopes' } },
      { icon: 'pinyin', name: '拼音也能搜', path: '输入 <code>wd</code> 找到「文档」，输入 <code>xmwd</code> 找到「项目文档」', meta: '中文', act: { fill: 'wd' } },
      { icon: 'live', name: '剪贴板由你决定', path: '默认关闭；文本、链接、图片和文件路径引用在本机加密保存，可暂停或清空', meta: '选择启用', act: { scroll: 'scopes' } },
      { icon: 'lock', name: '计算离线，汇率可选', path: '普通计算与单位换算离线运行；汇率换算可单独关闭', meta: '本地优先', act: { scroll: 'scopes' } },
      { icon: 'syntax', name: '查询语法', path: '<code>*.pdf</code>　<code>ext:png</code>　<code>!node_modules</code>　<code>dm:today</code>　<code>~/Desktop/</code>', meta: '进阶', act: { scroll: 'syntax' } },
      { icon: 'file', name: '开源', path: 'MIT 许可证，代码在 GitHub 上', meta: 'GitHub', act: { href: GITHUB_URL } },
    ],
    syntax: [
      ['wd', '拼音首字母，找到「文档」', '拼音'],
      ['readme !node_modules', '包含 readme，排除 node_modules 里的', '排除'],
      ['*.png', '通配符，匹配整个名称', '通配'],
      ['~/Desktop/ png', '只在桌面下面找', '路径'],
      ['dm:today ext:md', '今天改过的 Markdown', '时间'],
    ],
  },
  en: {
    captureTitle: 'Native screenshots, annotations and editable history',
    captureBody: 'Capture a region, window, the display under the pointer or a manually scrolled page. Reselect before capturing or from the editor while keeping your document. Add arrows, text, pen strokes, highlights, mosaic, solid redaction, crop, Emoji, stickers and reusable materials. Regular capture opens the editor; quick capture copies on mouse release without editing. Existing images and clipboard pictures can be edited too. Vision OCR runs on this Mac only when requested.',
    capturePrivacy: 'Independent screenshot history is encrypted, with defaults of 7 days, 100 images and 256 MiB. Editable history retains originals before redaction; exports contain flattened pixels only. Pins last for this session. This is a synthetic app snapshot; the website does not capture your screen.',
    captureShortcut: '⌘⇧4 selects and edits; ⌃⇧⌘4 copies directly. Configure each separately. If macOS uses a shortcut, Settings → Capture explains how to resolve it; search commands and the menu bar still work. The first capture requires your Screen Recording authorization.',
    title: 'Oil Find: files, apps and clipboard in one search panel',
    description: '⌘Space searches files, apps, settings & clipboard. Opt-in encrypted text and image history; web opens on submit. Fork disables upstream updates.',
    'nav.speed': 'Features', 'nav.syntax': 'Syntax', 'nav.github': 'GitHub', 'nav.download': 'Download', 'nav.lang': '中文',
    lead: ['Files, apps and clipboard, ', 'in one search panel'],
    placeholder: 'Try it here: wd, png, readme',
    sort: 'Relevance ⇅',
    dl: 'Download Free for macOS',
    downloadNote: 'macOS 14 or later · Apple silicon',
    openSource: 'Free and open source',
    'speed.h': 'Switch from finding to doing',
    'speed.sub': 'Search files and apps in one panel. Clipboard capture is opt-in; calculations and unit conversions work offline. Currency conversion is a separate setting: complete expressions request fixed public ECB rates, cached for 24 hours, and results show the rate date and cache status. Web searches open only when you submit.',
    'speed.frame': '',
    'stat.scan': 'File-name index', 'stat.mem': 'Clipboard', 'stat.live': 'Calculation, currency and web search',
    'speed.fine': 'The scope demo below uses built-in synthetic examples only. It never reads your files, clipboard or search history.',
    'syn.h': 'Write a little more to find exactly that',
    'syn.sub': 'Click a row to try it in the search field above.',
    'note.privacy.h': 'Privacy', 'note.privacy': 'The file engine reads names, sizes and modification dates only. Clipboard history is off by default; when enabled, it saves eligible text, links, clipboard images and path references to local files and folders, encrypted locally and protected with Keychain. Images retain their original encoded bytes; they are not automatically OCR-processed or sent over the network; local OCR is available when explicitly requested, and each image is limited to 16 MiB and 64 megapixels within a 32 MiB history cap. Finder copies of image files remain path references and are not read. File references store paths without backing up files or reading contents. Concealed, transient and autogenerated markers, source app exclusions and ungenerated file-promise exclusions still apply. Currency requests contain only a fixed list of public currency pairs, never the amount or full query. Web search opens only after you choose and submit; fork builds do not connect to the upstream official app-update service. Independent screenshot history and materials are encrypted with derived keys. Editable history retains originals before redaction; exports contain flattened pixels only. Defaults are 7 days, 100 images and 256 MiB, and recording can be disabled. Screen Recording is requested only on capture; pins are not restored after exit.',
    'source.download': 'Download for macOS',
    'source.github': 'View on GitHub',
    'note.open.h': 'Opening it the first time', 'note.open': 'The app isn’t notarized by Apple yet. If macOS blocks it, go to System Settings → Privacy & Security and click “Open Anyway” at the bottom. Once is enough.',
    'note.opensource.h': 'Open source', 'note.opensource': 'The free version’s code is on GitHub under the MIT license. Issues and pull requests are welcome. Pro features are not open source.',
    'note.fda.h': 'Full Disk Access', 'note.fda': 'Optional. Without it, Mail and other apps’ data can’t be searched.',
    'legal.github': 'GitHub', 'legal.download': 'Download for macOS',
    chips: ['All', 'Folders', 'Apps', 'Documents', 'Images', 'Code'],
    hints: [['↩', 'Open'], ['↑↓', 'Select'], ['Tab', 'Switch filter']],
    statusHome: n => `Start here · ${n} items`,
    statusDemo: n => `Demo data · ${n} ${n === 1 ? 'item' : 'items'}`,
    statusReplay: hits => `Synthetic demo · ${hits} items`,
    toastDemo: 'This is a demo · once installed, ↩ opens the file',
    noneTitle: 'No results',
    noneBody: 'There are only a few demo files here. Once installed, it searches your own Mac.',
    items: n => `${n} items`,
    today: t => `Today ${t}`, yesterday: t => `Yesterday ${t}`,
    date: (m, d) => `${['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'][m - 1]} ${d}`,
    folder: 'Folder', app: 'App', bytes: n => `${n} bytes`,
    scopeTitle: 'Choose a scope to try',
    scopeSubtitle: 'App queries expire after the panel closes for 1 minute, adjustable in Settings. This is a synthetic demo; the site never reads local files or the clipboard.',
    scopeTabs: ['All', 'Apps', 'Files', 'Settings', 'Clipboard', 'Calculate demo', 'Web search'],
    scopeAllItems: ['README.md · ~/Documents', 'Calendar · Events and meetings', 'Clipboard sample · Text, link and image', '12 × 8 + 5 · Offline result 101'],
    scopeKeyboard: '⌘0…⌘4 switch scopes · ⌥⌘1…9 choose file type',
    scopeApps: ['Calendar · Events and meetings', 'Calculator · Recent', 'Code editor · Projects'],
    scopeSettings: ['Keyboard Shortcuts · Keyboard', 'Privacy & Security · System Settings', 'Displays · Display'],
    scopeClips: ['Meeting plan: Thursday at 2 pm', 'https://example.com/research', 'Screenshot sample · PNG image'],
    scopeSampleTag: 'Synthetic sample',
    scopeClipboardNote: 'Clipboard history in the app is off by default. Upgrades preserve your enabled state and preferences, and existing AES-encrypted text history stays compatible. When enabled, it records eligible text, links, screenshots and raster images decodable by ImageIO (such as PNG, JPEG, TIFF, GIF, HEIC, WebP and BMP), plus local file/folder path references. Images keep their original encoded bytes and format/dimension metadata; each is limited to 16 MiB and 64 megapixels within a 32 MiB history cap. Images are not automatically OCR-processed or sent online; you can request local OCR through the capture tool; rows show thumbnails and support preview. ⌘C restores the actual image with a compatible PNG representation. Finder copies of image files remain path references and are not read. A file group shows names and a count; search by name or path. Select a file history entry and press ⌘C to restore file URLs, then ⌘V in Finder to copy the files. Return attempts to paste after the existing target-app, focus and Accessibility permission checks; a failed check only copies and tells you. Moved or deleted files cannot be recovered; if any path in the group is missing, the current clipboard is preserved and you are asked to copy the files again. Sensitive-item markers, source-app exclusions and pause controls still apply. This page uses synthetic examples only.',
    scopeCalcLabel: 'Enter an expression or conversion', scopeCalcResult: 'Offline result',
    scopeDemoCurrencyResult: 'Synthetic demo result', scopeDemoCurrencyRate: (date: string) => `Synthetic demo rate: 1 USD = 7.00 CNY · Date: ${date}. Fixed example data; no network request and not a current rate. RMB maps to CNY.`,
    scopeDemoCopyHint: 'Press Return or ⌘C to copy the demo result.', scopeDemoCopied: 'Synthetic result copied.', scopeDemoCopyUnavailable: 'The browser did not allow copying; select the result manually.',
    scopeDemoUnsupported: 'This demo only shows 100 USD to CNY; other currency expressions have no synthetic result. The app can enable currency conversion in settings.',
    scopeWebLabel: 'Search query', scopeEngineLabel: 'Search engine', scopeSubmit: 'Submit and open search',
    scopeUrlLabel: 'A URL opens directly', scopeUrlOpen: 'Open example URL',
    scopeEngines: ['DuckDuckGo', 'Google', 'Bing'],
    scopeOfflineNote: 'Ordinary calculations and unit conversions run offline; currency conversion is a separate app setting. This website demo makes no network requests. Web search does not send text while you type.',
    home: [
      { icon: 'download', name: 'Download Oil Find', path: 'Free and open source. macOS 14 or later, Apple silicon', meta: updateManifest.version, meta2: '1.5 MB', act: { href: '/downloads/Oil-Find.zip' } },
      { icon: 'timer', name: 'One panel, several search scopes', path: 'Files, apps, settings, clipboard, offline calculations and web search', meta: 'Scopes', act: { scroll: 'scopes' } },
      { icon: 'pinyin', name: 'Pinyin search', path: 'Type <code>wd</code> to find 文档, <code>xmwd</code> to find 项目文档', meta: 'Chinese', act: { fill: 'wd' } },
      { icon: 'live', name: 'Clipboard on your terms', path: 'Off by default; text, links, images and file path references are encrypted locally, with pause and clear controls', meta: 'Opt in', act: { scroll: 'scopes' } },
      { icon: 'lock', name: 'Offline calculations, optional currency rates', path: 'Ordinary calculations and unit conversions run offline; currency conversion can be turned off separately', meta: 'Local first', act: { scroll: 'scopes' } },
      { icon: 'syntax', name: 'Query syntax', path: '<code>*.pdf</code>　<code>ext:png</code>　<code>!node_modules</code>　<code>dm:today</code>　<code>~/Desktop/</code>', meta: 'Advanced', act: { scroll: 'syntax' } },
      { icon: 'file', name: 'Open source', path: 'MIT licensed. The code is on GitHub', meta: 'GitHub', act: { href: GITHUB_URL } },
    ],
    syntax: [
      ['wd', 'Pinyin initials, finds 文档', 'Pinyin'],
      ['readme !node_modules', 'Contains readme, not inside node_modules', 'Exclude'],
      ['*.png', 'Wildcard, matches the whole name', 'Wildcard'],
      ['~/Desktop/ png', 'Only under the Desktop', 'Path'],
      ['dm:today ext:md', 'Markdown files changed today', 'Date'],
    ],
  },
};

export type SitePage = 'home' | 'activated' | 'recover' | 'changelog' | 'pro' | 'syntax' | 'everything-for-mac';
export function pagePath(lang: Language, page: SitePage = 'home'): string {
  const prefix = lang === 'en' ? '/en' : '';
  return page === 'home' ? prefix || '/' : prefix + '/' + page;
}

export const activatedCopy = {
  zh: { title: '购买完成 · Oil Find Pro', 'ok.h': '感谢购买 Oil Find Pro', 'ok.p': '点下面的按钮，Oil Find 会直接激活 Pro。也可以把授权码粘贴到 Oil Find 设置里的 Pro 分区。', 'ok.cta': '在 Oil Find 中激活', 'ok.copy': '拷贝', copied: '已拷贝',
        'ok.install': '还没装 Oil Find？', 'ok.download': '下载 macOS 版', mailed: (email: string) => `授权码也发到了 ${email}。一个授权可以在 3 台 Mac 上使用。`, notMailed: '把授权码存好。一个授权可以在 3 台 Mac 上使用。',
        'fail.h': '没有找到这笔订单', 'fail.p': '如果已经购买 Oil Find Pro，可以用购买时的邮箱找回授权码。', 'fail.cta': '找回授权码', 'fail.home': '回到首页' },
  en: { title: 'Purchase complete · Oil Find Pro', 'ok.h': 'Thanks for buying Oil Find Pro', 'ok.p': 'Click the button below and Oil Find activates Pro right away. You can also paste the key into the Pro section of Oil Find’s settings.', 'ok.cta': 'Activate in Oil Find', 'ok.copy': 'Copy', copied: 'Copied',
        'ok.install': 'Don’t have Oil Find yet?', 'ok.download': 'Download for macOS', mailed: (email: string) => `The key was also sent to ${email}. One license works on up to 3 Macs.`, notMailed: 'Keep this key somewhere safe. One license works on up to 3 Macs.',
        'fail.h': 'We couldn’t find this order', 'fail.p': 'If you bought Oil Find Pro, recover your key with the email you used at checkout.', 'fail.cta': 'Recover license key', 'fail.home': 'Back to home' },
};

export const recoverCopy = {
  zh: { title: '找回授权码 · Oil Find Pro', h: '找回 Oil Find Pro 授权码', p: '填购买时用的邮箱，授权码会重新发过去。', cta: '发送授权码', sending: '正在发送…',
        invalid: '这个邮箱地址看起来不对。', offline: '没发出去，请检查网络后重试。',
        unconfigured: '现在没法自动找回。回复购买时收到的 Stripe 收据邮件，我们会把授权码发给你。',
        'sent.h': '去邮箱看看', sent: (email: string) => `如果 ${email} 买过 Oil Find Pro，授权码已经发出。没收到的话，看一下垃圾邮件。`, 'sent.again': '换一个邮箱' },
  en: { title: 'Recover license key · Oil Find Pro', h: 'Recover your Oil Find Pro license key', p: 'Enter the email you used at checkout and we’ll send the key again.', cta: 'Send license key', sending: 'Sending…',
        invalid: 'That email address doesn’t look right.', offline: 'Couldn’t send. Check your connection and try again.',
        unconfigured: 'Automatic recovery isn’t available right now. Reply to the Stripe receipt you got at checkout and we’ll send your key.',
        'sent.h': 'Check your inbox', sent: (email: string) => `If ${email} has bought Oil Find Pro, the key is on its way. If it doesn’t arrive, check your spam folder.`, 'sent.again': 'Use a different email' },
};

export const commonCopy = {
  brand: 'Oil Find',
  copyright: '© 2026 Oil Find',
  shortcutLabel: 'Command Space',
  searchLabel: 'Search',
  loadingLabel: 'Loading',
  emailLabel: 'Email',
  emailPlaceholder: 'you@example.com',
  ogDescription: '文件、应用、剪贴板，一处搜索。',
  stats: [['3.3', 's', 'stat.scan'], ['45', 'MB', 'stat.mem'], ['< 1', 's', 'stat.live']],
} as const;


export const proCopy = {
  zh: {
    title: 'Oil Find Pro',
    pageTitle: "Oil Find Pro：搜图片和文档里的文字，拔掉的硬盘也能搜",
    description: "截图、照片里的文字与画面，PDF、Word 等文档里的文字都能搜，全部在本机处理；外置硬盘拔掉后也能搜到。¥49 一次买断，可以免费试用 7 天。",
    headline: '搜图片和文档里的内容。',
    subtitle: '在免费版的快速搜索之上，搜图片和文档里的内容，保留离线硬盘的文件目录。',
    learn: '了解 Pro',
    trialNote: '使用同一个安装包，在设置里开启 7 天免费试用。',
    trialReassurance: '无需注册或绑卡，试用结束后仍可使用免费版。',
    terms: ['可用于 3 台 Mac', '包含以后所有更新', '14 天内可全额退款'],
    query: '发票',
    rows: [
      { name: '截屏2026-09-28 14.02.11.png', detail: '图中文字：…开具**发票**的日期… · ~/Desktop', date: '9月28日' },
      { name: '**发票**-9月.pdf', detail: '/Volumes/T7 Shield/报销 · 未连接', date: '9月30日' },
      { name: 'IMG_2043.HEIC', detail: '图中有：收据 · ~/Pictures', date: '9月21日' },
      { name: '采购合同.pdf', detail: '文档内容（第 3 页）：…含税**发票**于验收后开具… · ~/Documents', date: '9月18日' },
    ],
    demoDescription: '示例：搜索「发票」时，同时找到截图里的文字、拔掉的移动硬盘上的文件、拍到收据的照片和合同正文里的内容。',
    features: [
      { title: '搜图片里的文字与画面', description: '搜截图、照片和拍下的单据里的文字与画面。' },
      { title: '搜文档正文', description: '搜 PDF、Word、PowerPoint、Excel、Pages、Markdown 和纯文本里的文字，扫描版 PDF 也能识别。' },
      { title: "搜拔掉的硬盘", description: "外置磁盘拔掉后，上面的文件仍然能搜到，结果会标出在哪块盘上。" },
    ],
    privacy: '图片和文档都在这台 Mac 上处理，不会上传。',
    priceUnit: '一次买断', buy: '购买 Pro', download: '下载试用',
    nav: 'Pro', footer: 'Oil Find Pro', recover: '找回授权码', questions: '常见问题',
    compareLink: '对比免费版与 Pro',
    compare: {
      freeSummary: '搜文件名与 AI 对话', proSummary: '还能搜内容与离线硬盘',
      title: '选择适合你的搜索方式', feature: '功能', free: '免费版', pro: 'Pro',
      rows: [
        ['按文件名搜索：拼音、通配符、正则，按类型、大小、时间筛选', '✓', '✓'],
        ['实时更新、Quick Look 预览、拖放、全键盘操作', '✓', '✓'],
        ['排除文件夹和文件类型、应用内更新', '✓', '✓'],
        ['AI 对话搜索：Claude Code、Codex 和 WorkBuddy 本地对话标题与正文', '✓', '✓'],
        ['外置磁盘：插上就建立索引，实时更新', '✓', '✓'],
        ['外置磁盘拔掉后也能搜到', '—', '✓'],
        ['图片内容：截图、照片里的文字与画面', '—', '✓'],
        ['文档内容：PDF、Word、PowerPoint、Excel、Pages、Markdown 等', '—', '✓'],
        ['源码', '开源，MIT', '闭源'],
        ['价格', '免费', '¥49 一次买断（其他地区 $9.99）'],
      ],
      note: 'Pro 和免费版是同一个安装包。不激活也可以一直免费使用；试用结束只停用 Pro 功能。',
    },
    faq: [
      { q: '免费版会变少吗？', a: '不会。现在免费的功能会一直免费，也一直开源，Pro 只包含新增的功能。' },
      { q: '怎么试用？', a: '下载同一个 Oil Find 安装包，在设置里找到 Oil Find Pro，点「免费试用 7 天」。无需注册或绑定银行卡。' },
      { q: '试用结束之后呢？', a: '只停用 Pro 功能，其他照常可用。外置磁盘目录、图片和文档的索引都留着，激活后立刻恢复。' },
      { q: '图片和文档会上传吗？', a: '不会。识别和读取都在这台 Mac 上完成，结果也只存在本机。' },
      { q: '从源码构建有 Pro 吗？', a: '没有。Pro 不开源，只包含在官网和 GitHub Releases 的安装包里，从源码构建得到的是免费版。' },
      { q: '买断包含什么？', a: '一次购买可用于 3 台 Mac，包含以后所有更新。14 天内不满意，可以全额退款。支持银行卡和支付宝，中国大陆还支持微信支付。' },
      { q: '换了 Mac 怎么办？', a: '一个授权可以同时用在 3 台 Mac 上。在旧 Mac 的设置里停用，就能用到新的 Mac 上。' },
      { q: '授权码找不到了？', a: '用购买时的邮箱[找回授权码](/recover)。' },
    ],
  },
  en: {
    title: 'Oil Find Pro',
    pageTitle: "Oil Find Pro: search inside images and documents on Mac",
    description: "Search the text in screenshots, photos, PDFs and Office documents, all on your Mac, and keep unplugged drives searchable. $9.99 once, 7-day trial.",
    headline: 'Search beyond file names.',
    subtitle: 'Add image and document content search to Oil Find, and keep your unplugged drives searchable.',
    learn: 'Explore Pro',
    trialNote: 'One download. Start your 7-day free trial in Settings.',
    trialReassurance: 'No account or card. Keep using the free version after your trial.',
    terms: ['Use on 3 Macs', 'All future updates included', 'Full refund within 14 days'],
    query: 'invoice',
    rows: [
      { name: 'Screenshot 2026-09-28 at 14.02.11.png', detail: 'Text in image: …**invoice** date… · ~/Desktop', date: 'Sep 28' },
      { name: '**invoice**-september.pdf', detail: '/Volumes/T7 Shield/Expenses · Not connected', date: 'Sep 30' },
      { name: 'IMG_2043.HEIC', detail: 'Contains: receipt · ~/Pictures', date: 'Sep 21' },
      { name: 'purchase-agreement.pdf', detail: 'In document (page 3): …the **invoice** is issued after acceptance… · ~/Documents', date: 'Sep 18' },
    ],
    demoDescription: 'Example: searching for “invoice” finds text inside a screenshot, a file on an unplugged drive, a photo of a receipt and a passage inside a contract.',
    features: [
      { title: 'Image content', description: 'Search the text and objects in screenshots, photos and snapped receipts.' },
      { title: 'Document content', description: 'Search the text inside PDF, Word, PowerPoint, Excel, Pages, Markdown and plain-text files, including scanned PDFs.' },
      { title: "Unplugged drives", description: "Files on an external drive stay searchable after you unplug it, and results show which drive they’re on." },
    ],
    privacy: 'Images and documents are processed on your Mac and never uploaded.',
    priceUnit: 'one-time', buy: 'Buy Pro', download: 'Download to Try',
    nav: 'Pro', footer: 'Oil Find Pro', recover: 'Recover License Key', questions: 'Questions',
    compareLink: 'Compare Free and Pro',
    compare: {
      freeSummary: 'File names and AI conversations', proSummary: 'Content and offline drives, too',
      title: 'Choose how you search', feature: 'Feature', free: 'Free', pro: 'Pro',
      rows: [
        ['Search by file name: pinyin, wildcards, regex, filters by kind, size and date', '✓', '✓'],
        ['Live updates, Quick Look, drag and drop, full keyboard control', '✓', '✓'],
        ['Excluded folders and file types, in-app updates', '✓', '✓'],
        ['AI conversations: local titles and body text from Claude Code, Codex, and WorkBuddy', '✓', '✓'],
        ["External drives: indexed when plugged in, kept up to date", '✓', '✓'],
        ["External drives stay searchable when unplugged", '—', '✓'],
        ['Image content: text and objects in screenshots and photos', '—', '✓'],
        ['Document content: PDF, Word, PowerPoint, Excel, Pages, Markdown and more', '—', '✓'],
        ['Source code', 'Open source, MIT', 'Closed source'],
        ['Price', 'Free', '$9.99 once (¥49 in mainland China)'],
      ],
      note: 'Pro and the free version are the same download. You can keep using it for free without activating; when a trial ends, only Pro features turn off.',
    },
    faq: [
      { q: 'Will the free version lose features?', a: "No. Everything that's free today stays free and open source. Pro only adds new features." },
      { q: 'How do I try it?', a: 'Download Oil Find, then find Oil Find Pro in Settings and click “Start 7-Day Free Trial”. No account or card required.' },
      { q: 'What happens when the trial ends?', a: 'Only Pro features turn off; everything else keeps working. Your drive catalogs and your image and document indexes are kept and come back as soon as you activate.' },
      { q: 'Are my images and documents uploaded?', a: 'No. They are recognized and read on your Mac, and the results stay there.' },
      { q: 'Is Pro in the open-source code?', a: 'No. Pro is closed source and ships only in the builds from this site and GitHub Releases. Building from source gives you the free version.' },
      { q: 'What does a purchase include?', a: 'One payment covers 3 Macs and all future updates. A full refund is available within 14 days. Pay with card or Alipay, plus WeChat Pay in mainland China.' },
      { q: 'Getting a new Mac?', a: 'One license works on up to 3 Macs at once. Deactivate it in Settings on the old Mac to use it on the new one.' },
      { q: 'Lost your license key?', a: '[Recover it](/en/recover) with the email you used at checkout.' },
    ],
  },
} satisfies Record<Language, {
  title: string; pageTitle: string; description: string; headline: string; subtitle: string; query: string;
  learn: string; trialNote: string; trialReassurance: string; terms: string[];
  rows: { name: string; detail: string; date: string }[]; demoDescription: string;
  features: { title: string; description: string }[]; privacy: string;
  priceUnit: string; buy: string; download: string;
  nav: string; footer: string; recover: string; questions: string;
  compareLink: string;
  compare: { freeSummary: string; proSummary: string; title: string; feature: string; free: string; pro: string; rows: [string, string, string][]; note: string };
  faq: { q: string; a: string }[];
}>;

export function footerQuestions(lang: Language): { q: string; a: string }[] {
  const t = dict[lang];
  return [
    ...searchQuestions[lang],
    aiTopicQuestions[lang],
    ...(['open', 'opensource', 'fda', 'privacy'] as const).map(key => ({ q: t[`note.${key}.h`], a: t[`note.${key}`] })),
  ];
}

const searchQuestions: Record<Language, { q: string; a: string }[]> = {
  "zh": [
    {
      "q": "和 Spotlight 有什么不同",
      "a": "Spotlight 同时搜索文件内容、应用和网页。Oil Find 使用自己的文件名索引，支持拼音首字母、通配符、正则和实时更新。"
    },
    {
      "q": "苹果版的 Everything",
      "a": "和 Windows 上的 Everything 思路一样：给磁盘上的文件名建一份索引，输入即出结果。Everything 只有 Windows 版，Oil Find 是为 Mac 写的原生应用。"
    }
  ],
  "en": [
    {
      "q": "How it differs from Spotlight",
      "a": "Spotlight searches file contents, apps and the web. Oil Find uses its own file-name index, with pinyin initials, wildcards, regular expressions and live updates."
    },
    {
      "q": "Everything for Mac",
      "a": "It works like Everything on Windows: an index of every file name on your disk, with results as you type. Everything is Windows-only; Oil Find is a native Mac app."
    }
  ]
};

const aiTopicQuestions: Record<Language, { q: string; a: string }> = {
  "zh": {
    "q": "能搜哪些 AI 对话？",
    "a": "免费版支持搜索保存在本机的 Claude Code、Codex 和 WorkBuddy 对话标题与正文，也包括 Claude 桌面端的 Code 会话。Claude 普通网页聊天及 WorkBuddy 尚未保存到本机的云端内容、已归档或删除的 WorkBuddy 会话、WorkBuddy 临时 Quick Ask 和子代理会话都不会出现在结果中。各来源可在设置中单独开关。"
  },
  "en": {
    "q": "Which AI conversations can I search?",
    "a": "The free version searches titles and body text saved locally by Claude Code, Codex, and WorkBuddy, including Code sessions in the Claude desktop app. Regular Claude web chats, WorkBuddy cloud content not saved locally, archived or deleted WorkBuddy sessions, temporary WorkBuddy Quick Asks, and WorkBuddy subagent sessions are excluded. Each source has its own switch in Settings."
  }
};
