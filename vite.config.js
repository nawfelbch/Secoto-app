import { defineConfig, loadEnv } from 'vite'
import react from '@vitejs/plugin-react'
import legacy from '@vitejs/plugin-legacy'

// ---------------------------------------------------------------------------
// Vieux téléphones (24/11/2026). Par défaut, Vite 8 compile pour les navigateurs
// récents (Safari 16.4+, Chrome 111+) : le bundle contient `??=` / `||=`, qu'un
// iPhone resté en iOS 12-13 ou un vieil Android ne sait pas lire -> PAGE BLANCHE
// sans message, et le client croit que « le lien ne s'ouvre pas ».
// plugin-legacy ajoute une 2e version de l'app (syntaxe ancienne + polyfills),
// chargée SEULEMENT par ces vieux navigateurs (balise nomodule) ; les téléphones
// récents gardent exactement le bundle moderne d'aujourd'hui.
// ---------------------------------------------------------------------------
const NAVIGATEURS_ANCIENS = ['defaults', 'iOS >= 12', 'Safari >= 12', 'Chrome >= 64', 'Samsung >= 9', 'Firefox >= 68', 'not IE 11']

// ---------------------------------------------------------------------------
// Garde-fou de construction (18/09/2026).
// src/supabaseClient.js lève une erreur au chargement si VITE_SUPABASE_URL ou
// VITE_SUPABASE_ANON_KEY manquent. À la construction, ces variables sont
// remplacées par du texte vide : l'erreur devient inconditionnelle, l'optimiseur
// supprime tout le code qui suit, et on obtient un bundle qui se construit
// SANS ERREUR mais ne contient plus l'application (page blanche en ligne).
// On préfère échouer bruyamment ici plutôt que déployer une coquille vide.
// ---------------------------------------------------------------------------
const REQUISES = ['VITE_SUPABASE_URL', 'VITE_SUPABASE_ANON_KEY']

export default defineConfig(({ command, mode }) => {
  if (command === 'build') {
    const env = { ...loadEnv(mode, process.cwd(), 'VITE_'), ...process.env }
    const absentes = REQUISES.filter((cle) => !String(env[cle] || '').trim())
    if (absentes.length > 0) {
      throw new Error(
        `Construction impossible : ${absentes.join(' et ')} ${absentes.length > 1 ? 'sont absentes' : 'est absente'}.\n`
        + 'Sans elles, le bundle se construit mais ne contient plus l\'application (page blanche).\n'
        + 'Renseignez-les dans Netlify (Site configuration → Environment variables), '
        + 'dans Codemagic (Environment variables), ou dans un fichier .env local.',
      )
    }
  }
  return {
    plugins: [
      react(),
      legacy({ targets: NAVIGATEURS_ANCIENS, modernPolyfills: true }),
    ],
  }
})
