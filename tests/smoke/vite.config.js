// Rendu de contrôle des écrans 030-032 : chaque composant est rendu une fois
// hors navigateur (react-dom/server), avec un client Supabase factice.
// Usage : npx vite build -c tests/smoke/vite.config.js && node tests/smoke/out/entry.js
import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";
import path from "node:path";
import { fileURLToPath } from "node:url";

const here = path.dirname(fileURLToPath(import.meta.url));
const root = path.resolve(here, "..", "..");

export default defineConfig({
  root,
  plugins: [react()],
  resolve: {
    alias: [{ find: /^(.*)\/supabaseClient$/, replacement: path.join(here, "stub-supabase.js") }],
  },
  build: {
    ssr: path.join(here, "entry.jsx"),
    outDir: path.join(here, "out"),
    emptyOutDir: true,
    minify: false,
  },
});
