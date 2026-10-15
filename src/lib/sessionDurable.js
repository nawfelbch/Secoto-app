// SECOTO — garder l'utilisateur connecté.
// ----------------------------------------------------------------------------
// Au réveil du téléphone, le réseau met parfois quelques secondes à revenir :
// une erreur réseau ne doit jamais renvoyer vers l'écran de connexion tant
// qu'une session est enregistrée sur l'appareil. Seul un refus explicite du
// serveur (session révoquée, jeton inconnu) déconnecte.

// Supabase enregistre la session sous « sb-<projet>-auth-token ».
export function sessionEnregistree(storage = typeof localStorage === "undefined" ? null : localStorage) {
  try {
    if (!storage) return false;
    for (let i = 0; i < storage.length; i += 1) {
      const cle = storage.key(i);
      if (!/^sb-.+-auth-token$/.test(cle || "")) continue;
      const valeur = JSON.parse(storage.getItem(cle) || "null");
      if (valeur?.refresh_token || valeur?.currentSession?.refresh_token) return true;
    }
  } catch {
    // Stockage illisible : on se comporte comme sans session.
  }
  return false;
}

export function estErreurReseau(err) {
  if (!err) return false;
  if (err.name === "AuthRetryableFetchError") return true;
  if (err.status === 0) return true;
  return /failed to fetch|network|load failed|timeout|internet|connexion/i.test(String(err.message || ""));
}
