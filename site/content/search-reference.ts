import { dict, type Language } from './dict';
import copy from './seo-pages.json';

export const syntaxCopy = copy.syntax;
export const everythingCopy = copy.everything;
export const referenceCopy = {
  zh: { syntax: '搜索语法', everything: 'Mac 上的 Everything', allSyntax: '查看全部语法', analytics: '本站使用不带 Cookie 的匿名访问统计。', query: '输入', meaning: '意思', key: '按键', action: '作用', copy: '拷贝', copied: '已拷贝', copyFailed: '未能拷贝，请选中文字拷贝。' },
  en: { syntax: 'Search Syntax', everything: 'Everything for Mac', allSyntax: 'See all syntax', analytics: 'This site uses anonymous, cookie-free analytics.', query: 'Type', meaning: 'Meaning', key: 'Key', action: 'Action', copy: 'Copy', copied: 'Copied', copyFailed: 'Could not copy. Select the text to copy it.' },
};

// Keep the landing examples authoritative and extend them with the README reference.
export function syntaxRows(lang: Language): { queries: string[]; meaning: string }[] {
  const examples = dict[lang].syntax;
  return [
    { queries: [examples[0][0]], meaning: examples[0][1] },
    { queries: ['wendang'], meaning: lang === 'zh' ? '拼音首字母或全拼，能找到「文档」' : 'Pinyin initials or full pinyin, finds 文档' },
    { queries: ['foo bar'], meaning: lang === 'zh' ? '同时包含 foo 和 bar' : 'Contains both foo and bar' },
    { queries: ['foo | bar'], meaning: lang === 'zh' ? '包含 foo 或 bar' : 'Contains foo or bar' },
    ...examples.slice(1, 4).map(([query, meaning]) => ({ queries: [query], meaning })),
    { queries: ['ext:pdf;docx'], meaning: lang === 'zh' ? '按扩展名' : 'By extension' },
    { queries: ['kind:image'], meaning: lang === 'zh' ? '按类型：folder、app、doc、image、video、audio、code、archive' : 'By kind: folder, app, doc, image, video, audio, code, archive' },
    { queries: ['file:', 'folder:'], meaning: lang === 'zh' ? '只要文件，或只要文件夹' : 'Files only, or folders only' },
    { queries: ['size:>10mb', 'size:1mb..5mb'], meaning: lang === 'zh' ? '按大小' : 'By size' },
    { queries: ['dm:today', 'dm:week', 'dm:2026-10-01'], meaning: lang === 'zh' ? '按修改时间' : 'By modification date' },
    { queries: ['regex:^IMG_\\d+'], meaning: lang === 'zh' ? '正则表达式' : 'Regular expressions' },
    { queries: [examples[4][0]], meaning: examples[4][1] },
  ];
}

export const keyboardRows: Record<Language, [string, string][]> = {
  zh: [
    ['⌘Space', '打开搜索（默认）'], ['⇧⌘F', '⌘Space 注册失败时的临时回退'],
    ['⌘0…4', '切换全部、应用、文件、设置、剪贴板范围'], ['⌥⌘1…9', '选择文件类型'],
    ['Return', '执行结果：打开、复制计算结果，或粘贴剪贴板条目'], ['⌘Return', '文件：在访达中显示'],
    ['⌘Y', '文件：Quick Look；剪贴板：预览文本或图片'], ['⌘C', '优先复制选中文字，否则复制当前结果的路径、文本或网址；剪贴板图片和文件组可恢复为可用的剪贴板内容'],
    ['⌥⌘C', '文件：拷贝名称'], ['⌘⌫', '清空整个搜索框；文件和剪贴板记录的删除使用右键菜单'],
    ['Tab', '在文件范围内切换文件类型'], ['⌘/', '语法速查'],
  ],
  en: [
    ['⌘Space', 'Open search (default)'], ['⇧⌘F', 'Temporary fallback if ⌘Space cannot register'],
    ['⌘0…4', 'Switch All, Apps, Files, Settings and Clipboard scopes'], ['⌥⌘1…9', 'Choose file type'],
    ['Return', 'Execute the result: open, copy a calculation, or paste a clipboard entry'], ['⌘Return', 'Files: show in Finder'],
    ['⌘Y', 'Files: Quick Look; clipboard: preview text or image'], ['⌘C', "Copy selected query text first, otherwise the result's path, text or URL; clipboard images and file groups restore usable clipboard representations"],
    ['⌥⌘C', 'Files: copy name'], ['⌘⌫', 'Clear the entire search field; use the context menu to delete files or clipboard entries'],
    ['Tab', 'Cycle file types in the Files scope'], ['⌘/', 'Syntax reference'],
  ],
};
