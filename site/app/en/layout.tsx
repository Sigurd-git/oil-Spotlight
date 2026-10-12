import { Analytics } from '@vercel/analytics/next';
import type { ReactNode } from 'react';
import { siteMetadata } from '@/lib/metadata';
import '../globals.css';
export const metadata = siteMetadata('en');
export default function Layout({ children }: { children: ReactNode }) {
  return <html lang="en"><body>{children}<Analytics /></body></html>;
}
