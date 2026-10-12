export const LANGUAGE_COOKIE = 'oil-find-language';
export const LANGUAGE_COOKIE_MAX_AGE = 60 * 60 * 24 * 365;

export function preferredLanguage(header: string | null): string | undefined {
  return header?.split(',').map((part, index) => {
    const [language, ...parameters] = part.trim().split(';');
    const quality = parameters.find(parameter => parameter.trim().startsWith('q='));
    return { language: language.toLowerCase(), quality: quality ? Number(quality.trim().slice(2)) : 1, index };
  }).filter(item => item.language && item.language !== '*' && item.quality > 0 && item.quality <= 1)
    .sort((a, b) => b.quality - a.quality || a.index - b.index)[0]?.language;
}

export const crawlerAgent = /google-inspectiontool|googleother|googleweblight|meta-externalagent|meta-externalfetcher|bot|crawler|spider|slurp|facebookexternalhit|facebot|twitter|linkedin|pinterest|whatsapp|telegram|discord|slack|embedly|quora link preview|vkshare|skypeuripreview|apple-pubsub|ia_archiver/i;
export const chineseRegions = new Set(['CN', 'HK', 'MO', 'TW', 'SG']);
