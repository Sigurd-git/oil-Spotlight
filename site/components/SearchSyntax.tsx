import type { Language } from '@/content/dict';
import { keyboardRows, referenceCopy, syntaxCopy, syntaxRows } from '@/content/search-reference';
import { TopBar } from './TopBar';
import { SiteFooter } from './SiteFooter';
import { CopyQuery } from './CopyQuery';
import styles from './SearchReference.module.css';

export function SearchSyntax({ lang }: { lang: Language }) {
  const t = syntaxCopy[lang], labels = referenceCopy[lang];
  return <><TopBar lang={lang} page="syntax" /><main className={`col ${styles.article}`}>
    <h1>{t.h1}</h1><p>{t.intro}</p>
    <section aria-label={t.h1}>
      <table className={styles.table} aria-label={t.h1}>
        <thead><tr><th scope="col">{labels.query}</th><th scope="col">{labels.meaning}</th></tr></thead>
        <tbody>{syntaxRows(lang).map(({ queries, meaning }) => <tr key={queries[0]}>
          <th scope="row">{queries.map(query => <CopyQuery key={query} query={query} lang={lang} />)}</th><td>{meaning}</td>
        </tr>)}</tbody>
      </table>
    </section>
    <section><h2>{t.keyboardTitle}</h2>
      <table className={styles.table} aria-label={t.keyboardTitle}>
        <thead><tr><th scope="col">{labels.key}</th><th scope="col">{labels.action}</th></tr></thead>
        <tbody>{keyboardRows[lang].map(([key, action]) => <tr key={key}><th scope="row">{key}</th><td>{action}</td></tr>)}</tbody>
      </table>
    </section>
  </main><SiteFooter lang={lang} /></>;
}
