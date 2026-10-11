import { describe, expect, it } from 'vitest';
import { demoFiles, match, parse, shouldClearQueryOnShortcut, syntheticCurrencyResult } from '@/content/demo';
import { dict, GITHUB_URL, type Language } from '@/content/dict';
import manifest from '@/public/updates/latest.json';

function names(lang: Language, query: string) {
  const parsed = parse(query);
  return demoFiles(lang).filter(file => match(file, parsed, null)).map(file => file.name);
}

describe.each(['zh', 'en'] as const)('search demonstration (%s)', lang => {
  it('keeps the example searches useful with localized file names', () => {
    expect(names(lang, 'readme !node_modules')).toEqual(['README.md', 'readme-assets']);
    expect(names(lang, 'ext:png')).toHaveLength(4);
    expect(names(lang, '~/Desktop/ png')).toHaveLength(3);
  });

  it('provides the open source action in the demo list', () => {
    expect(dict[lang].home[0].meta).toBe(manifest.version);
    const item = dict[lang].home.at(-1);
    expect(item?.act.href).toBe(GITHUB_URL);
    expect(item?.meta).toBe('GitHub');
  });

  it('describes the currency example as fixed synthetic data and never as a live rate', () => {
    const copy = dict[lang];
    expect(syntheticCurrencyResult('100 usd in to rmb')).toEqual({ value: '700.00 CNY', rateDate: '2026-01-01' });
    expect(syntheticCurrencyResult('100 USD to CNY')).toEqual({ value: '700.00 CNY', rateDate: '2026-01-01' });
    expect(syntheticCurrencyResult('100美元转人民币')).toEqual({ value: '700.00 CNY', rateDate: '2026-01-01' });
    expect(syntheticCurrencyResult('100 EUR to GBP')).toBeNull();
    expect(copy.scopeDemoCurrencyRate('2026-01-01')).toMatch(/2026-01-01/);
    expect(copy.scopeDemoCurrencyRate('2026-01-01').toLowerCase()).toMatch(/synthetic|合成|演示/);
    expect(copy.scopeOfflineNote.toLowerCase()).toMatch(/no network|不联网/);
    expect(copy.scopeDemoCopyHint).toMatch(/Return/);
  });

  it('clears the whole demo search only for Meta+Backspace outside IME composition', () => {
    expect(shouldClearQueryOnShortcut({ key: 'Backspace', metaKey: true, isComposing: false })).toBe(true);
    expect(shouldClearQueryOnShortcut({ key: 'Backspace', metaKey: false, isComposing: false })).toBe(false);
    expect(shouldClearQueryOnShortcut({ key: 'Backspace', metaKey: true, isComposing: true })).toBe(false);
    expect(shouldClearQueryOnShortcut({ key: 'Backspace', metaKey: true, isComposing: false, altKey: true })).toBe(false);
  });
});
