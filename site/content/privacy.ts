import type { Language } from './dict';

export const PRIVACY_UPDATED_AT = '2026-10-30';
export const PRIVACY_CONTACT_URL = 'https://github.com/oil-oil/oil-find/issues';

type PrivacyCopy = {
  title: string;
  pageTitle: string;
  description: string;
  updated: string;
  introduction: string;
  sections: { title: string; paragraphs: string[]; items?: string[] }[];
  contact: { title: string; body: string; note: string; action: string };
};

export const privacyCopy = {
  zh: {
    title: '隐私政策',
    pageTitle: '隐私政策 · Oil Find',
    description: 'Oil Find 隐私政策：Spotlight fork 的本地索引、剪贴板、截图历史、汇率和网页搜索，以及上游购买、授权、更新和网站数据处理说明。',
    updated: '更新日期：2026-10-30',
    introduction: '本页先说明 Spotlight fork 的数据处理，再保留上游 Mac App Store 版、直售版和官网的说明。购买、授权和更新机制取决于你使用的版本；上游版本的条款不表示 fork 会连接上游更新服务。',
    sections: [
      {
        title: 'Spotlight fork：本地搜索与联网边界',
        paragraphs: [
          '文件引擎只读取名称、大小和修改时间，不读取文件正文。启用 AI 会话搜索后，会读取所选来源保存在本机的对话标题与正文，并在本机建立独立索引，不会上传。Pro 的图片与文档内容处理也在本机完成。',
          '普通计算与单位换算离线运行。汇率换算可单独关闭，仅在全部范围、非中文组字且输入为完整货币表达式时异步请求 ECB 每日公开参考汇率。固定请求不含金额、完整查询或私人数据；缓存只保存公开汇率和取得时间，结果显示来源日期与缓存状态。',
          '网页搜索只在你选择并提交后打开搜索引擎，不在键入时发送查询；网址只在执行打开动作后处理。OilFindUpdateChannel=spotlight-fork 构建不检查或安装上游官方应用更新。',
        ],
      },
      {
        title: 'Spotlight fork：剪贴板历史',
        paragraphs: [
          '剪贴板记录默认关闭；升级保留已有开启状态和偏好，并兼容原 AES 加密文本历史。启用后只保存获准的纯文本、链接、合格栅格图片，以及本地文件和文件夹的路径引用。历史在本机加密，由钥匙串保护，可暂停、清空或排除来源应用。敏感、临时、自动生成标记和尚未生成的文件承诺会被排除。',
          '图片保存原始编码内容及格式、像素尺寸元数据，不自动做 OCR 或联网；只有用户主动操作时才在本机识字。单图最多 16 MiB、6400 万像素，历史总量最多 32 MiB。Finder 复制的图片文件仍只保存路径，不读取正文；文件引用不备份原文件。采集时不逐个检查文件是否存在，恢复复制时验证整组路径，路径缺失则保留当前剪贴板并提示重新复制。',
          '默认保留 7 天、500 条，可设为 1…365 天和 1…10,000 条。单条文本或一组路径的 UTF-8 总量最多 256 KiB，一组最多 1,000 个路径。Return 尝试粘贴前检查目标应用、焦点和辅助功能权限；检查失败时仅复制并提示。',
        ],
      },
      {
        title: 'Spotlight fork：截图、识字与可编辑历史',
        paragraphs: [
          '屏幕录制权限只在主动捕获时请求；ScreenCaptureKit 流只在手动长截图会话中运行，并排除 Oil Find 界面。OCR 必须由用户主动执行，Vision 在后台本地运行，不联网，也不写入文件索引。钉图文只在本次运行显示，退出后不恢复。',
          '复制、导出或钉住后才保存独立可编辑历史。截图原图、标注、索引和素材使用现有主密钥按独立用途派生的密钥加密；可编辑历史保留打码前原图，导出只包含最终像素。默认保留 7 天、100 张、最多 256 MiB，可关闭，期限可设为 1…365 天、数量可设为 1…1,000 张。复制的成品仍遵守剪贴板的开启、暂停、来源排除及容量限制。',
          '诊断只记录会话阶段、取消原因、图片尺寸和错误码，不记录截图、窗口标题或剪贴板正文。',
        ],
      },
      {
        title: '上游 Mac App Store 版',
        paragraphs: [
          '开发者不收集你的用户文件内容、搜索词或本地 AI 对话。Mac App Store 版的数据处理方式如下：',
          '购买和支付由 Apple 处理，Oil Find 不接触完整支付卡信息。试用锚点保存在本机的 defaults 或 Keychain 中。Apple 对 App Store 和购买服务所需数据的处理，适用 Apple 的隐私政策。',
        ],
        items: [
          '索引范围：只索引你明确授权的目录和外置盘，并保存安全作用域书签（security-scoped bookmark）以维持访问权限。未授权的目录不会被扫描或监听。',
          '本地识别与索引：图片和文档的内容识别与索引均在你的 Mac 上完成。',
          'AI 会话：根据你选择的 AI 提供商（provider），只访问该来源所需的最小目录，或你明确导入的内容；不读取提供商凭据，也不上传用户内容。',
          '更新与分析：不包含应用内更新，也不向第三方分析或广告服务上传数据。',
        ],
      },
      {
        title: '上游直售版',
        paragraphs: ['直售版的图片和文档内容识别与索引也在本机完成。授权、订单和更新流程另有以下数据处理：'],
        items: [
          '许可授权：激活、刷新和停用会处理授权码、设备标识，以及用于区分设备的必要设备名称。',
          '官网订单与找回：下单和找回授权码会处理邮箱及订单信息，Stripe 也会在其支付服务中处理相关信息。完整银行卡信息由 Stripe 处理，不经过我们的服务器。',
          '每日更新：只下载版本清单或安装包，不上传文件内容或搜索词。',
        ],
      },
      {
        title: '官网',
        paragraphs: ['Oil Find 官网使用不带 Cookie 的匿名访问统计，用于了解页面访问情况。搜索和截图演示只使用合成数据，不读取本机文件或剪贴板，也不会截取屏幕；演示汇率不联网，不代表当前汇率。网页搜索演示只有在明确提交后才打开所选搜索引擎。官网订单和授权码找回的数据处理见“上游直售版”。'],
      },
    ],
    contact: {
      title: '联系方式',
      body: '如果你对本政策或 Oil Find 的隐私实践有疑问，请通过 GitHub Issues 联系开发者。',
      note: '请不要在公开 Issue 中发布授权码、支付信息或个人文件。',
      action: '在 GitHub Issues 中提问',
    },
  },
  en: {
    title: 'Privacy Policy',
    pageTitle: 'Privacy Policy · Oil Find',
    description: 'Spotlight fork privacy: local search, clipboard and screenshot history, currency and web search, plus upstream licensing, purchases, updates and website data.',
    updated: 'Last updated: 2026-10-30',
    introduction: 'This page explains the Spotlight fork first, followed by the upstream Mac App Store, direct-sale, and website policies. Purchases, licensing, and updates depend on the version you use; upstream terms do not mean the fork connects to the upstream update service.',
    sections: [
      {
        title: 'Spotlight fork: local search and network requests',
        paragraphs: [
          'The file engine reads names, sizes and modification dates without reading file contents. When AI conversation search is enabled, selected sources’ locally saved titles and body text are read into a separate local index and never uploaded. Pro image and document processing also stays on your Mac.',
          'Calculations and unit conversions work offline. Currency conversion is a separate setting: only a complete currency expression in the All scope, outside Chinese input composition, can asynchronously request public daily ECB reference rates. The fixed request contains no amount, full query or private data. The cache stores only public rates and retrieval time; results show the source date and cache status.',
          'Web search opens your chosen engine only after you select and submit, without sending queries as you type. URLs are handled only when you choose to open them. Builds with OilFindUpdateChannel=spotlight-fork do not check for or install upstream official app updates.',
        ],
      },
      {
        title: 'Spotlight fork: clipboard history',
        paragraphs: [
          'Clipboard recording is off by default. Upgrades preserve your enabled state and preferences and remain compatible with existing AES-encrypted text history. When enabled, history stores eligible plain text, links, raster images, and path references to local files and folders. It is encrypted locally and protected with Keychain; you can pause, clear it or exclude source apps. Concealed, transient and autogenerated items and ungenerated file promises are excluded.',
          'Images retain original encoded bytes and format and dimension metadata, without automatic OCR or network access. OCR runs locally only when explicitly requested. Each image is limited to 16 MiB and 64 megapixels within a 32 MiB history cap. Finder copies of image files remain path references without reading contents; file references do not back up files. Collection does not check each path for existence; restoring a file group checks every path first, preserving the current clipboard and asking you to copy again if any path is missing.',
          'Defaults are 7 days and 500 entries, configurable to 1–365 days and 1–10,000 entries. Text or all paths in one group are limited to 256 KiB of UTF-8 data, with at most 1,000 paths per group. Return checks the target app, focus and Accessibility permission before attempting to paste; failed checks only copy and display a message.',
        ],
      },
      {
        title: 'Spotlight fork: capture, OCR and editable history',
        paragraphs: [
          'Screen Recording permission is requested only on active capture. ScreenCaptureKit streams run only during manual scrolling capture and exclude Oil Find UI. OCR requires an explicit user action and runs locally through Vision in the background, without network access or adding text to the file index. Pins last only for the current app session and are not restored after exit.',
          'Independent editable history is saved only after copying, exporting or pinning. Screenshot originals, annotations, indexes and materials are encrypted with keys derived from the existing master key for separate purposes. Editable history retains originals before redaction; exports contain final pixels only. Defaults are 7 days, 100 images and 256 MiB; history can be disabled, with retention configurable to 1–365 days and 1–1,000 images. Copied results still follow clipboard enabled state, pause, source exclusions and size limits.',
          'Diagnostics record only session stage, cancellation reason, image dimensions and error codes, never screenshots, window titles or clipboard contents.',
        ],
      },
      {
        title: 'Upstream Mac App Store version',
        paragraphs: [
          'The developer does not collect your user file contents, search terms, or local AI conversations. The Mac App Store version handles data as follows:',
          'Purchases and payments are handled by Apple, and Oil Find does not have access to full payment card details. The trial anchor is stored locally in macOS defaults or the Keychain. Apple’s processing of data needed for App Store and purchase services is governed by Apple’s privacy policy.',
        ],
        items: [
          'Index scope: Oil Find indexes only folders and external drives you explicitly authorize, and saves security-scoped bookmarks to retain access. It does not scan or monitor unauthorized locations.',
          'On-device recognition and indexing: Image and document content recognition and indexing take place on your Mac.',
          'AI conversations: Oil Find accesses only the minimum directory needed for the AI provider you select, or content you explicitly import. It does not read provider credentials or upload your content.',
          'Updates and analytics: This version has no in-app updater and does not upload data to third-party analytics or advertising services.',
        ],
      },
      {
        title: 'Upstream direct-sale version',
        paragraphs: ['Image and document content recognition and indexing also take place on your Mac in the direct-sale version. Its licensing, ordering, and update flows involve the following additional data processing:'],
        items: [
          'Licensing: Activation, refresh, and deactivation process your license key, a device identifier, and the device name needed to distinguish the device.',
          'Website orders and recovery: Checkout and license-key recovery process your email address and order information. Stripe also processes related information to provide payment services. Full card details are handled by Stripe and do not pass through our servers.',
          'Daily updates: Oil Find only downloads a version manifest or installer, and does not upload file contents or search terms.',
        ],
      },
      {
        title: 'Website',
        paragraphs: ['This website uses anonymous, cookie-free analytics to understand page visits. Search and capture demos use synthetic data without reading local files or the clipboard or capturing your screen. Demo currency rates make no network requests and are not current rates. The web search demo opens the chosen engine only after explicit submission. See “Upstream direct-sale version” for website order and license-key recovery data.'],
      },
    ],
    contact: {
      title: 'Contact',
      body: 'If you have questions about this policy or Oil Find’s privacy practices, contact the developer through GitHub Issues.',
      note: 'Do not post license keys, payment details, or personal files in public issues.',
      action: 'Open GitHub Issues',
    },
  },
} satisfies Record<Language, PrivacyCopy>;
