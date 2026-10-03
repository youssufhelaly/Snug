import { defineConfig } from 'vite';

// `base` is relative so the built site works at a domain root (Cloudflare
// Pages, Vercel) and under a sub-path (GitHub Pages) without changes.
export default defineConfig({
  base: './',
  build: {
    target: 'es2022',
    chunkSizeWarningLimit: 900,
    // Two pages: the project overview (index) and the interactive 3D demo.
    rollupOptions: { input: { index: 'index.html', demo: 'demo.html' } },
  },
});
