import { createClient } from "@supabase/supabase-js";

// La cle "anon" est publique par conception, mais elle reste injectee par
// l'environnement afin qu'aucun identifiant de projet ne soit fige dans Git.
// La cle service_role n'est jamais exposee dans le frontend.
export const supabaseUrl = import.meta.env.VITE_SUPABASE_URL || "";
export const supabaseAnonKey = import.meta.env.VITE_SUPABASE_ANON_KEY || "";

if (!supabaseUrl || !supabaseAnonKey) {
  throw new Error(
    "Configuration Supabase absente : VITE_SUPABASE_URL et VITE_SUPABASE_ANON_KEY sont obligatoires.",
  );
}

export const supabase = createClient(supabaseUrl, supabaseAnonKey, {
  auth: {
    flowType: "pkce",
    persistSession: true,
    autoRefreshToken: true,
    detectSessionInUrl: true,
  },
});
