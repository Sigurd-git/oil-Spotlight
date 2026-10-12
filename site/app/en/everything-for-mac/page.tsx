import { EverythingForMac } from '@/components/EverythingForMac';
import { siteMetadata } from '@/lib/metadata';

export const metadata = siteMetadata('en', 'everything-for-mac');
export default function Page() { return <EverythingForMac lang="en" />; }
