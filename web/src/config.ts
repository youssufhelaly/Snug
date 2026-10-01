/**
 * Build-time settings. Set these as environment variables when building, for
 * example in your hosting provider's dashboard. Anything unset is hidden.
 */
export const AMAZON_TAG: string | null = import.meta.env.VITE_AMAZON_TAG || null;
export const TESTFLIGHT_URL: string | null = import.meta.env.VITE_TESTFLIGHT_URL || null;
export const GITHUB_URL = 'https://github.com/youssufhelaly/Snug';
