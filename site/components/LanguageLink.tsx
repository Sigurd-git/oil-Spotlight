'use client';

import { useEffect, useState } from 'react';
import { dict, pagePath, type Language, type SitePage } from '@/content/dict';
import { LANGUAGE_COOKIE, LANGUAGE_COOKIE_MAX_AGE } from '@/lib/language';

export function LanguageLink({ lang, page }: { lang: Language; page: SitePage }) {
  const target = pagePath(lang === 'zh' ? 'en' : 'zh', page);
  const [href, setHref] = useState(target);
  useEffect(() => {
    const current = new URLSearchParams(location.search), retained = new URLSearchParams();
    for (const key of ['q']) {
      const value = current.get(key);
      if (value !== null) retained.set(key, value);
    }
    setHref(target + (retained.size ? `?${retained}` : '') + location.hash);
  }, [target]);
  function rememberChoice() {
    document.cookie = `${LANGUAGE_COOKIE}=${lang === 'zh' ? 'en' : 'zh'}; Path=/; Max-Age=${LANGUAGE_COOKIE_MAX_AGE}; SameSite=Lax${location.protocol === 'https:' ? '; Secure' : ''}`;
  }
  return <a className="nav" id="lang" href={href} onClick={rememberChoice} onAuxClick={event => { if (event.button === 1) rememberChoice(); }}>{dict[lang]['nav.lang']}</a>;
}
