import { createClient } from "@supabase/supabase-js";

// La cle "anon" est PUBLIQUE par conception (protegee par les policies RLS) :
// elle est faite pour tourner dans le navigateur / l'app. On garde une valeur
// de repli en dur pour que le build natif (Capacitor) fonctionne meme sans
// fichier .env local. Sur Netlify, les variables VITE_ prennent le dessus.
// (La cle SECRETE service_role n'est JAMAIS ici — uniquement cote serveur.)
const supabaseUrl =
  import.meta.env.VITE_SUPABASE_URL || "https://znnigxmzacukpfueqfrh.supabase.co";
const supabaseAnonKey =
  import.meta.env.VITE_SUPABASE_ANON_KEY ||
  "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InpubmlneG16YWN1a3BmdWVxZnJoIiwicm9sZSI6ImFub24iLCJpYXQiOjE3NzYyODQ2NzgsImV4cCI6MjA5MTg2MDY3OH0.YNnKgsxm5AoorOsk-FVRWBgP2AVFI6rZKSmlbUSsfXo";

export const supabase = createClient(supabaseUrl, supabaseAnonKey);