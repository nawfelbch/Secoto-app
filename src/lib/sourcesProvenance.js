// Libellés lisibles des sources de provenance (tableau Acquisition).
const LIBELLES_SOURCE = { "google-naturel": "Google naturel", site: "Site (autres visites)" };

export function libelleSource(source) {
  return LIBELLES_SOURCE[source] || source;
}
