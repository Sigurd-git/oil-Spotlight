'use client';

import { useState } from 'react';
import type { Language } from '@/content/dict';
import { referenceCopy } from '@/content/search-reference';
import styles from './SearchReference.module.css';

export function CopyQuery({ query, lang }: { query: string; lang: Language }) {
  const [message, setMessage] = useState('');
  const t = referenceCopy[lang];
  async function copy() {
    try {
      await navigator.clipboard.writeText(query);
      setMessage(t.copied);
    } catch {
      setMessage(t.copyFailed);
    }
  }
  return <span className={styles.copyQuery}>
    <button type="button" onClick={copy} aria-label={`${t.copy}: ${query}`}><code>{query}</code></button>
    <span className={styles.copyStatus} role="status">{message}</span>
  </span>;
}
