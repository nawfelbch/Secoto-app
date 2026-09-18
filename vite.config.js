import { defineConfig, loadEnv } from 'vite'
import react from '@vitejs/plugin-react'

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
  return { plugins: [react()] }
})
