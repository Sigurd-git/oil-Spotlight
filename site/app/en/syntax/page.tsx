import { SearchSyntax } from '@/components/SearchSyntax';
import { siteMetadata } from '@/lib/metadata';

export const metadata = siteMetadata('en', 'syntax');
export default function Page() { return <SearchSyntax lang="en" />; }
