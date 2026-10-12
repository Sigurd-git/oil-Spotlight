// Run after deployment to submit every URL in the live sitemap.
import { readFile } from 'node:fs/promises';

const host = 'find.oiloil.org';
const key = (await readFile(new URL('../public/823b7fd82c8bfc6365292175454b4cd0.txt', import.meta.url), 'utf8')).trim();
const sitemap = await fetch(`https://${host}/sitemap.xml`);
if (!sitemap.ok) throw new Error(`Sitemap: HTTP ${sitemap.status}`);
const xml = await sitemap.text();
const decode = text => text.replace(/&(amp|lt|gt|quot|apos);/g, (_, entity) => ({ amp: '&', lt: '<', gt: '>', quot: '"', apos: "'" })[entity]);
const urlList = [...new Set([...xml.matchAll(/<loc>\s*([^<]+?)\s*<\/loc>/g)].map(match => decode(match[1])))];
if (!urlList.length || urlList.some(url => new URL(url).hostname !== host)) throw new Error('Unexpected sitemap URLs');
const response = await fetch('https://api.indexnow.org/indexnow', {
  method: 'POST', headers: { 'Content-Type': 'application/json; charset=utf-8' },
  body: JSON.stringify({ host, key, keyLocation: `https://${host}/${key}.txt`, urlList }),
});
console.log(`IndexNow: HTTP ${response.status} ${response.statusText} (${urlList.length} URLs)`);
if (!response.ok) process.exitCode = 1;
