// ============================================================================
// SECOTO — Lecture de l'historique de transports (CSV ou XLSX).
// ----------------------------------------------------------------------------
// SÉCURITÉ : aucune formule n'est évaluée et aucune macro n'est exécutée.
//  • CSV : texte brut ; une cellule « =… » reste du texte.
//  • XLSX : lecture directe du XML (valeurs mises en cache uniquement) ;
//    classeurs à macros (.xlsm, vbaProject.bin) refusés.
// Les lignes sont ensuite REVALIDÉES par le serveur.
// ============================================================================

export const MAX_FILE_BYTES = 5 * 1024 * 1024;
export const MAX_ROWS = 5000;

export const TEMPLATE_COLUMNS = [
  { key: "date", header: "date", example: "2026-06-12", help: "AAAA-MM-JJ ou JJ/MM/AAAA" },
  { key: "from", header: "depart", example: "Fontenay-aux-Roses 92260", help: "Ville et code postal" },
  { key: "to", header: "destination", example: "Lyon 69002", help: "Ville et code postal" },
  { key: "distance_km", header: "distance_km", example: "465", help: "Kilomètres" },
  { key: "vehicle", header: "vehicule", example: "Renault Clio", help: "Modèle ou catégorie" },
  { key: "mode", header: "mode", example: "convoyage", help: "convoyage ou plateau" },
  { key: "requested_delay_hours", header: "delai_demande_h", example: "48", help: "Délai demandé, en heures" },
  { key: "amount_eur", header: "montant_eur", example: "430", help: "Montant payé, en euros" },
  { key: "fees_eur", header: "frais_eur", example: "62.40", help: "Carburant, péages… en euros" },
  { key: "receipt_ref", header: "ref_justificatif", example: "FAC-2026-118", help: "Numéro de facture ou de justificatif" },
];

const HEADER_ALIASES = {
  date: ["date", "date_transport", "jour"],
  from: ["depart", "adresse_depart", "origine", "from", "lieu_depart"],
  to: ["destination", "arrivee", "adresse_arrivee", "to", "lieu_arrivee"],
  distance_km: ["distance_km", "distance", "km", "kilometres"],
  vehicle: ["vehicule", "modele", "vehicle", "categorie_vehicule"],
  mode: ["mode", "convoyage_ou_plateau", "type", "prestation"],
  requested_delay_hours: ["delai_demande_h", "delai", "delai_h", "delai_demande"],
  amount_eur: ["montant_eur", "montant", "prix", "montant_ttc", "montant_ht"],
  fees_eur: ["frais_eur", "frais", "peages_carburant"],
  receipt_ref: ["ref_justificatif", "justificatif", "reference", "facture"],
};

export function normalizeHeader(value) {
  return String(value || "")
    .normalize("NFD").replace(/[̀-ͯ]/g, "")
    .toLowerCase().trim().replace(/[^a-z0-9]+/g, "_").replace(/^_|_$/g, "");
}

export function templateCsv() {
  const header = TEMPLATE_COLUMNS.map((c) => c.header).join(";");
  const example = TEMPLATE_COLUMNS.map((c) => c.example).join(";");
  return `\uFEFF${header}\r\n${example}\r\n`;
}

export function parseCsv(text) {
  const source = String(text || "").replace(/^\uFEFF/, "");
  const firstLine = source.split(/\r?\n/, 1)[0] || "";
  const delimiter = (firstLine.match(/;/g) || []).length >= (firstLine.match(/,/g) || []).length ? ";" : ",";
  const rows = [];
  let row = [];
  let cell = "";
  let quoted = false;
  for (let i = 0; i < source.length; i += 1) {
    const ch = source[i];
    if (quoted) {
      if (ch === '"' && source[i + 1] === '"') { cell += '"'; i += 1; }
      else if (ch === '"') quoted = false;
      else cell += ch;
    } else if (ch === '"') {
      quoted = true;
    } else if (ch === delimiter) {
      row.push(cell); cell = "";
    } else if (ch === "\n" || ch === "\r") {
      if (ch === "\r" && source[i + 1] === "\n") i += 1;
      row.push(cell); rows.push(row); row = []; cell = "";
    } else {
      cell += ch;
    }
  }
  if (cell !== "" || row.length) { row.push(cell); rows.push(row); }
  return rows.filter((r) => r.some((c) => String(c).trim() !== ""));
}

// --- XLSX (zip + XML) ---------------------------------------------------------
function readUInt16(view, offset) { return view.getUint16(offset, true); }
function readUInt32(view, offset) { return view.getUint32(offset, true); }

export async function unzipEntries(buffer) {
  const bytes = buffer instanceof Uint8Array ? buffer : new Uint8Array(buffer);
  const view = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
  let eocd = -1;
  for (let i = bytes.length - 22; i >= Math.max(0, bytes.length - 65557); i -= 1) {
    if (readUInt32(view, i) === 0x06054b50) { eocd = i; break; }
  }
  if (eocd < 0) throw new Error("Fichier XLSX illisible.");
  const count = readUInt16(view, eocd + 10);
  let offset = readUInt32(view, eocd + 16);
  const entries = new Map();
  const decoder = new TextDecoder();
  for (let n = 0; n < count; n += 1) {
    if (readUInt32(view, offset) !== 0x02014b50) throw new Error("Fichier XLSX illisible.");
    const method = readUInt16(view, offset + 10);
    const compressedSize = readUInt32(view, offset + 20);
    const nameLength = readUInt16(view, offset + 28);
    const extraLength = readUInt16(view, offset + 30);
    const commentLength = readUInt16(view, offset + 32);
    const localOffset = readUInt32(view, offset + 42);
    const name = decoder.decode(bytes.subarray(offset + 46, offset + 46 + nameLength));
    entries.set(name, { method, compressedSize, localOffset });
    offset += 46 + nameLength + extraLength + commentLength;
  }
  return {
    names: [...entries.keys()],
    async read(name) {
      const entry = entries.get(name);
      if (!entry) return null;
      const lo = entry.localOffset;
      const start = lo + 30 + readUInt16(view, lo + 26) + readUInt16(view, lo + 28);
      const data = bytes.subarray(start, start + entry.compressedSize);
      if (entry.method === 0) return decoder.decode(data);
      if (entry.method !== 8) throw new Error("Compression XLSX non prise en charge.");
      const stream = new Blob([data]).stream().pipeThrough(new DecompressionStream("deflate-raw"));
      return new Response(stream).text();
    },
  };
}

function decodeXml(text) {
  return String(text)
    .replace(/&lt;/g, "<").replace(/&gt;/g, ">").replace(/&quot;/g, '"').replace(/&apos;/g, "'")
    .replace(/&#(\d+);/g, (_, d) => String.fromCodePoint(Number(d)))
    .replace(/&amp;/g, "&");
}

function columnIndex(ref) {
  const letters = String(ref).match(/^[A-Z]+/)?.[0] || "A";
  let index = 0;
  for (const ch of letters) index = index * 26 + (ch.charCodeAt(0) - 64);
  return index - 1;
}

function excelSerialToIso(serial) {
  const ms = Math.round((Number(serial) - 25569) * 86400000);
  const date = new Date(ms);
  return Number.isNaN(date.getTime()) ? String(serial) : date.toISOString().slice(0, 10);
}

export async function parseXlsx(buffer) {
  const zip = await unzipEntries(buffer);
  if (zip.names.some((n) => /vbaProject\.bin$/i.test(n))) {
    throw new Error("Classeur contenant des macros refusé. Enregistrez-le en .xlsx ou .csv.");
  }
  const sharedXml = (await zip.read("xl/sharedStrings.xml")) || "";
  const shared = [...sharedXml.matchAll(/<si>([\s\S]*?)<\/si>/g)].map((m) =>
    decodeXml([...m[1].matchAll(/<t[^>]*>([\s\S]*?)<\/t>/g)].map((t) => t[1]).join("")));
  const stylesXml = (await zip.read("xl/styles.xml")) || "";
  const dateStyles = new Set();
  const cellXfs = stylesXml.match(/<cellXfs[^>]*>([\s\S]*?)<\/cellXfs>/)?.[1] || "";
  [...cellXfs.matchAll(/<xf [^>]*numFmtId="(\d+)"/g)].forEach((m, i) => {
    const id = Number(m[1]);
    if ((id >= 14 && id <= 22) || (id >= 164 && /yy|dd|mm/i.test(stylesXml.match(new RegExp(`numFmtId="${id}" formatCode="([^"]+)"`))?.[1] || ""))) dateStyles.add(i);
  });
  const sheetName = zip.names.find((n) => /^xl\/worksheets\/sheet1\.xml$/.test(n)) || zip.names.find((n) => /^xl\/worksheets\/sheet\d+\.xml$/.test(n));
  if (!sheetName) throw new Error("Aucune feuille trouvée dans le classeur.");
  const sheet = await zip.read(sheetName);
  const rows = [];
  let formulaCells = 0;
  for (const rowMatch of sheet.matchAll(/<row[^>]*>([\s\S]*?)<\/row>/g)) {
    const cells = [];
    for (const c of rowMatch[1].matchAll(/<c ([^>]*?)(?:\/>|>([\s\S]*?)<\/c>)/g)) {
      const attrs = c[1];
      const inner = c[2] || "";
      const ref = attrs.match(/r="([A-Z]+\d+)"/)?.[1];
      const type = attrs.match(/t="(\w+)"/)?.[1];
      const style = Number(attrs.match(/s="(\d+)"/)?.[1] || -1);
      if (/<f[ >]/.test(inner)) formulaCells += 1; // valeur en cache lue, formule jamais évaluée
      let value = inner.match(/<v>([\s\S]*?)<\/v>/)?.[1];
      if (type === "s") value = shared[Number(value)];
      else if (type === "inlineStr") value = [...inner.matchAll(/<t[^>]*>([\s\S]*?)<\/t>/g)].map((t) => t[1]).join("");
      else if (value !== undefined && dateStyles.has(style)) value = excelSerialToIso(value);
      cells[ref ? columnIndex(ref) : cells.length] = value === undefined ? "" : decodeXml(value);
    }
    rows.push(Array.from(cells, (v) => (v === undefined ? "" : v)));
  }
  return { rows: rows.filter((r) => r.some((c) => String(c).trim() !== "")), formulaCells };
}

function normalizeDate(value) {
  const text = String(value || "").trim();
  let m = text.match(/^(\d{4})-(\d{2})-(\d{2})/);
  if (m) return `${m[1]}-${m[2]}-${m[3]}`;
  m = text.match(/^(\d{1,2})[/.-](\d{1,2})[/.-](\d{4})$/);
  if (m) return `${m[3]}-${m[2].padStart(2, "0")}-${m[1].padStart(2, "0")}`;
  if (/^\d{5}(\.\d+)?$/.test(text)) return excelSerialToIso(text);
  return text;
}

// Convertit le tableau brut en lignes normalisées + contrôles de premier niveau
// (affichés pour correction ; le serveur refait tous les contrôles).
export function mapRows(table) {
  if (!table?.length) return { rows: [], missingColumns: TEMPLATE_COLUMNS.map((c) => c.header), unknownColumns: [] };
  const headers = table[0].map(normalizeHeader);
  const index = {};
  for (const [key, aliases] of Object.entries(HEADER_ALIASES)) {
    const i = headers.findIndex((h) => aliases.includes(h));
    if (i >= 0) index[key] = i;
  }
  const required = ["date", "from", "to", "distance_km", "vehicle", "mode", "amount_eur"];
  const missingColumns = required.filter((k) => index[k] === undefined).map((k) => TEMPLATE_COLUMNS.find((c) => c.key === k).header);
  const known = new Set(Object.values(index));
  const unknownColumns = table[0].filter((_, i) => !known.has(i) && String(table[0][i]).trim());
  const body = table.slice(1, MAX_ROWS + 1);
  const rows = body.map((cells, i) => {
    const get = (key) => (index[key] === undefined ? "" : String(cells[index[key]] ?? "").trim());
    const row = {
      line: i + 2,
      date: normalizeDate(get("date")),
      from: get("from"),
      to: get("to"),
      distance_km: get("distance_km").replace(",", "."),
      vehicle: get("vehicle"),
      mode: get("mode").toLowerCase(),
      requested_delay_hours: get("requested_delay_hours"),
      amount_eur: get("amount_eur").replace(/[€\s]/g, "").replace(",", "."),
      fees_eur: get("fees_eur").replace(/[€\s]/g, "").replace(",", "."),
      receipt_ref: get("receipt_ref"),
    };
    row.issues = checkRow(row);
    return row;
  });
  return { rows, missingColumns, unknownColumns, truncated: table.length - 1 > MAX_ROWS };
}

export function checkRow(row) {
  const issues = [];
  if (!/^\d{4}-\d{2}-\d{2}$/.test(row.date || "")) issues.push("Date invalide");
  else if (new Date(row.date) > new Date()) issues.push("Date future");
  if ((row.from || "").length < 2) issues.push("Départ manquant");
  if ((row.to || "").length < 2) issues.push("Destination manquante");
  const km = Number(row.distance_km);
  if (!row.distance_km || !Number.isFinite(km) || km <= 0 || km > 3000) issues.push("Distance invalide");
  if ((row.vehicle || "").length < 2) issues.push("Véhicule manquant");
  if (!["convoyage", "plateau"].includes(row.mode)) issues.push("Mode : convoyage ou plateau");
  const amount = Number(row.amount_eur);
  if (!row.amount_eur || !Number.isFinite(amount) || amount <= 0) issues.push("Montant invalide");
  if (/^[=+@]/.test(`${row.amount_eur}${row.distance_km}`)) issues.push("Formule non acceptée");
  return issues;
}

export function markDuplicates(rows) {
  const seen = new Map();
  return rows.map((row) => {
    const key = [row.date, row.from.toLowerCase(), row.to.toLowerCase(), row.vehicle.toLowerCase(), row.amount_eur].join("|");
    const duplicate = seen.has(key);
    seen.set(key, true);
    return duplicate && !row.issues.includes("Doublon probable") ? { ...row, issues: [...row.issues, "Doublon probable"] } : row;
  });
}

export async function readHistoryFile(file) {
  if (!file) throw new Error("Aucun fichier sélectionné.");
  if (file.size > MAX_FILE_BYTES) throw new Error("Fichier trop volumineux (5 Mo maximum).");
  const name = String(file.name || "").toLowerCase();
  if (/\.(xlsm|xlsb|xls)$/.test(name)) throw new Error("Format refusé : utilisez le modèle .xlsx ou .csv (sans macros).");
  let table;
  let formulaCells = 0;
  if (name.endsWith(".csv") || file.type === "text/csv") {
    table = parseCsv(await file.text());
  } else if (name.endsWith(".xlsx")) {
    const parsed = await parseXlsx(await file.arrayBuffer());
    table = parsed.rows;
    formulaCells = parsed.formulaCells;
  } else {
    throw new Error("Format non pris en charge : .csv ou .xlsx.");
  }
  const mapped = mapRows(table);
  return { ...mapped, rows: markDuplicates(mapped.rows), formulaCells };
}

export function rowsForServer(rows) {
  // Le serveur revalide tout : on ne transmet ni le numéro de ligne ni les
  // contrôles affichés à l'écran.
  return rows.map((row) => {
    const copy = { ...row };
    delete copy.line;
    delete copy.issues;
    return copy;
  });
}
