import './landing.css';
import { GITHUB_URL, TESTFLIGHT_URL } from './config';

// The landing page is static; this only fills in the build-time links.
for (const link of document.querySelectorAll<HTMLAnchorElement>('.github-link')) link.href = GITHUB_URL;
if (TESTFLIGHT_URL) {
  for (const link of document.querySelectorAll<HTMLAnchorElement>('.testflight-link')) {
    link.href = TESTFLIGHT_URL;
    link.hidden = false;
  }
}
