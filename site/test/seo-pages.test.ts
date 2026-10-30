import { createElement } from 'react';
import { renderToStaticMarkup } from 'react-dom/server';
import { readFileSync } from 'node:fs';
import { expect, it } from 'vitest';
import { SearchSyntax } from '@/components/SearchSyntax';
import { EverythingForMac } from '@/components/EverythingForMac';
import { Privacy } from '@/components/Privacy';
import { SiteFooter } from '@/components/SiteFooter';
import { SearchProvider } from '@/components/SearchContext';
import { SyntaxSheet } from '@/components/SyntaxSheet';
import { dict, footerQuestions, pagePath } from '@/content/dict';
import { keyboardRows, referenceCopy, syntaxRows } from '@/content/search-reference';
import { PRIVACY_CONTACT_URL, PRIVACY_UPDATED_AT, privacyCopy } from '@/content/privacy';
import specification from './fixtures/m30-copy.json';

it.each(['zh', 'en'] as const)('renders complete M30 content and matching FAQ data (%s)', lang => {
  const t = specification.everything[lang];
  const html = renderToStaticMarkup(createElement(EverythingForMac, { lang }));
  const texts = [t.h1, t.intro, t.spotlightTitle, t.questions, ...t.sections.flatMap(section => [section.title, ...section.items]), ...t.faq.flatMap(item => [item.q, item.a]), footerQuestions(lang)[0].a];
  for (const text of texts) expect(html).toContain(renderToStaticMarkup(createElement('span', null, text)).slice(6, -7));
  const schema = JSON.parse(html.match(/<script type="application\/ld\+json">([\s\S]*?)<\/script>/)![1]);
  expect(schema['@type']).toBe('FAQPage');
  expect(schema.mainEntity).toEqual(t.faq.map(({ q, a }) => ({ '@type': 'Question', name: q, acceptedAnswer: { '@type': 'Answer', text: a } })));
});

it.each(['zh', 'en'] as const)('uses semantic syntax and keyboard tables and the README keyboard reference (%s)', lang => {
  const html = renderToStaticMarkup(createElement(SearchSyntax, { lang }));
  expect(html.match(/<table /g)).toHaveLength(2);
  expect(html).toContain(specification.syntax[lang].intro);
  for (const [query, meaning] of dict[lang].syntax) {
    expect(syntaxRows(lang).some(row => row.queries.includes(query) && row.meaning === meaning)).toBe(true);
  }
  const readme = readFileSync(new URL(lang === 'zh' ? '../../README.zh-CN.md' : '../../README.md', import.meta.url), 'utf8');
  const section = readme.split(lang === 'zh' ? '## 键盘操作' : '## Keyboard')[1].split('\n## ')[0];
  const rows = section.split('\n').filter(line => line.startsWith('| <kbd>')).map(line => line.split('|').slice(1, 3).map(value => value.replace(/<\/?kbd>/g, '').trim()));
  expect(keyboardRows[lang]).toEqual(rows);
  const clearQuery = keyboardRows[lang].find(([key]) => key === '⌘⌫');
  const expectedClearQuery = lang === 'zh'
    ? '清空整个搜索框；文件和剪贴板记录的删除使用右键菜单'
    : 'Clear the entire search field; use the context menu to delete files or clipboard entries';
  expect(clearQuery).toEqual(['⌘⌫', expectedClearQuery]);
  expect(clearQuery).toEqual(['⌘⌫', specification.keyboard[lang].clearQuery]);
  for (const { queries } of syntaxRows(lang)) for (const query of queries) expect(html).toContain(`aria-label="${referenceCopy[lang].copy}: ${query.replace(/>/g, '&gt;')}"`);
});

it.each(['zh', 'en'] as const)('renders the complete channel-specific privacy policy and language link (%s)', lang => {
  const t = privacyCopy[lang];
  const html = renderToStaticMarkup(createElement(Privacy, { lang }));
  const texts = [t.title, t.updated, t.introduction,
    ...t.sections.flatMap(section => [section.title, ...section.paragraphs, ...(section.items ?? [])]),
    t.contact.title, t.contact.body, t.contact.note, t.contact.action];
  for (const text of texts) expect(html).toContain(renderToStaticMarkup(createElement('span', null, text)).slice(6, -7));
  expect(html).toContain(`<time dateTime="${PRIVACY_UPDATED_AT}">`);
  expect(html).toContain(`href="${PRIVACY_CONTACT_URL}"`);
  expect(html).toContain(`href="${pagePath(lang === 'zh' ? 'en' : 'zh', 'privacy')}"`);
  expect(html.match(/<section>/g)).toHaveLength(t.sections.length + 1);
});

it.each(['zh', 'en'] as const)('keeps fork data boundaries alongside the upstream privacy channels (%s)', lang => {
  const sections = privacyCopy[lang].sections;
  const fork = sections.filter(section => section.title.startsWith('Spotlight fork'));
  const text = fork.flatMap(section => section.paragraphs).join(' ');
  expect(fork).toHaveLength(3);
  const required = lang === 'zh'
    ? ['不读取文件正文', '剪贴板记录默认关闭', '文件引用不备份原文件', '不自动做 OCR 或联网',
      '不含金额、完整查询或私人数据', '不在键入时发送查询', '不检查或安装上游官方应用更新',
      '保留打码前原图', '7 天、100 张', '不记录截图、窗口标题或剪贴板正文']
    : ['without reading file contents', 'Clipboard recording is off by default', 'file references do not back up files',
      'without automatic OCR or network access', 'no amount, full query or private data', 'without sending queries as you type',
      'do not check for or install upstream official app updates', 'retains originals before redaction',
      '7 days, 100 images', 'never screenshots, window titles or clipboard contents'];
  for (const boundary of required) expect(text).toContain(boundary);
  expect(text).toContain('16 MiB');
  expect(text).toContain('32 MiB');
  expect(text).toContain('256 MiB');
  expect(sections.some(section => section.title === (lang === 'zh' ? '上游 Mac App Store 版' : 'Upstream Mac App Store version'))).toBe(true);
  const direct = sections.find(section => section.title === (lang === 'zh' ? '上游直售版' : 'Upstream direct-sale version'))!;
  expect(direct.items?.join(' ')).toContain('Stripe');
});

it.each(['zh', 'en'] as const)('adds internal discovery links and the analytics notice (%s)', lang => {
  const footer = renderToStaticMarkup(createElement(SiteFooter, { lang }));
  for (const page of ['syntax', 'everything-for-mac', 'privacy'] as const) expect(footer).toContain(`href="${pagePath(lang, page)}"`);
  expect(footer).toContain(referenceCopy[lang].analytics);
  const sheet = renderToStaticMarkup(createElement(SearchProvider, null, createElement(SyntaxSheet, { lang })));
  expect(sheet).toContain(`href="${pagePath(lang, 'syntax')}"`);
  expect(sheet).toContain(referenceCopy[lang].allSyntax);
});
