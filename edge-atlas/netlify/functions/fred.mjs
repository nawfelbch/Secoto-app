// Relais en lecture seule vers FRED, limité aux trois séries du radar
// (même liste blanche que server.cjs).
const series = new Set(['VIXCLS', 'BAMLH0A0HYM2', 'T10Y2Y'])

const reponse = (status, corps, type = 'application/json; charset=utf-8') =>
  new Response(typeof corps === 'string' ? corps : JSON.stringify(corps), {
    status,
    headers: { 'Content-Type': type, 'Cache-Control': 'public, max-age=900', 'X-Content-Type-Options': 'nosniff' },
  })

export default async (req) => {
  if (req.method !== 'GET') return reponse(405, { error: 'Lecture uniquement' })
  const id = new URL(req.url).searchParams.get('id')
  if (!series.has(id)) return reponse(400, { error: 'Série non autorisée' })
  const cible = new URL('https://fred.stlouisfed.org/graph/fredgraph.csv')
  cible.searchParams.set('id', id)
  try {
    const amont = await fetch(cible, { signal: AbortSignal.timeout(20000), redirect: 'error', headers: { Accept: 'text/csv' } })
    if (!amont.ok) return reponse(amont.status, { error: 'Source indisponible : HTTP ' + amont.status })
    const texte = await amont.text()
    if (texte.length > 8 * 1024 * 1024) return reponse(502, { error: 'Réponse trop volumineuse' })
    return reponse(200, texte, 'text/csv; charset=utf-8')
  } catch (err) {
    return reponse(502, { error: err.name === 'TimeoutError' ? 'Délai source dépassé' : 'Connexion à la source impossible' })
  }
}
