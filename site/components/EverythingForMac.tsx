import { dict, footerQuestions, GITHUB_URL, type Language } from '@/content/dict';
import { everythingCopy } from '@/content/search-reference';
import { TopBar } from './TopBar';
import { SiteFooter } from './SiteFooter';
import { StructuredData } from './StructuredData';
import styles from './SearchReference.module.css';

export function EverythingForMac({ lang }: { lang: Language }) {
  const t = everythingCopy[lang];
  return <><StructuredData lang={lang} page="everything-for-mac" /><TopBar lang={lang} page="everything-for-mac" />
    <main className={`col ${styles.article}`}><h1>{t.h1}</h1><p>{t.intro}</p>
      {t.sections.map(section => <section key={section.title}><h2>{section.title}</h2><ul>{section.items.map(item => <li key={item}>{item}</li>)}</ul></section>)}
      <section><h2>{t.spotlightTitle}</h2><p>{footerQuestions(lang)[0].a}</p></section>
      <section><h2>{t.questions}</h2><dl>{t.faq.map(({ q, a }) => <div key={q}><dt>{q}</dt><dd>{a}</dd></div>)}</dl></section>
      <div className={styles.actions}><a className="btn dark" href="/downloads/Oil-Find.zip">{dict[lang]['source.download']}</a><a className="btn soft" href={GITHUB_URL}>{lang === 'zh' ? '在 GitHub 上查看' : dict[lang]['source.github']}</a></div>
    </main><SiteFooter lang={lang} /></>;
}
