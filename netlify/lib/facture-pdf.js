// ============================================================================
// SECOTO — FACTURE ACQUITTÉE EN PDF (commandes à la demande)
// ----------------------------------------------------------------------------
// Reprend la mise en page validée par Nawfal le 09/11/2026 (facture de
// M. Caujolle, FAC-202610-0001) :
//   · page 1 : la facture acquittée (encadré « PAYÉE », mention EI, ligne
//     « Pour SECOTO, Nawfal Benchiha ») ;
//   · page 2 : le justificatif de paiement tiré des vraies données Stripe et le
//     lien du reçu officiel Stripe. Uniquement pour un paiement en ligne
//     (carte, Klarna…) : espèces et virement n'ont pas de page 2.
// Dessin direct avec pdf-lib (pur JavaScript) : aucun navigateur à embarquer
// dans la fonction Netlify. Aucune donnée inventée : un champ absent n'est
// simplement pas imprimé.
// ============================================================================
import { PDFDocument, StandardFonts, degrees, rgb } from "pdf-lib";
import { LOGO_SECOTO_PNG_BASE64 } from "./logo-secoto-png.js";

export const SECOTO = {
  dirigeant: "Nawfal Benchiha",
  adresse1: "70 avenue du Maréchal Foch",
  adresse2: "92260 Fontenay-aux-Roses",
  email: "contact.secoto@gmail.com",
  telephone: "07 83 27 82 31",
  siret: "951 857 531 00028",
};

const MM = 72 / 25.4;
const PX = 0.75;
const W = 210 * MM;
const H = 297 * MM;
const LEFT = 16 * MM;
const RIGHT = W - 16 * MM;
const CW = RIGHT - LEFT;

const hex = (h) => rgb(parseInt(h.slice(1, 3), 16) / 255, parseInt(h.slice(3, 5), 16) / 255, parseInt(h.slice(5, 7), 16) / 255);
const ORANGE = hex("#F5620F");
const DARK = hex("#0D1117");
const GREY = hex("#6B737D");
const LGREY = hex("#F6F8FA");
const GREEN = hex("#2EA043");
const LINE = hex("#E3E6EA");
const WHITE = rgb(1, 1, 1);

// --------------------------------------------------------------------------
// Formats
// --------------------------------------------------------------------------
export function euros(cents) {
  const v = (Number(cents) || 0) / 100;
  const [ent, dec] = v.toFixed(2).split(".");
  return `${ent.replace(/\B(?=(\d{3})+(?!\d))/g, " ")},${dec} €`;
}

export function dateFr(value) {
  if (!value) return "";
  const d = value instanceof Date ? value : new Date(value);
  if (Number.isNaN(d.getTime())) return "";
  return new Intl.DateTimeFormat("fr-FR", { timeZone: "Europe/Paris", day: "2-digit", month: "2-digit", year: "numeric" }).format(d);
}

export function heureFr(value) {
  if (!value) return "";
  const d = value instanceof Date ? value : new Date(value);
  if (Number.isNaN(d.getTime())) return "";
  return new Intl.DateTimeFormat("fr-FR", { timeZone: "Europe/Paris", hour: "2-digit", minute: "2-digit" }).format(d);
}

export function telephoneFr(value) {
  const digits = String(value || "").replace(/[^\d+]/g, "").replace(/^\+33/, "0");
  return /^0\d{9}$/.test(digits) ? digits.replace(/(\d{2})(?=\d)/g, "$1 ") : String(value || "").trim();
}

/** Mode de règlement → texte de l'encadré « PAYÉE » et présence de la page 2. */
export function libelleReglement(reglement) {
  switch (reglement?.type) {
    case "carte": return "par carte bancaire";
    case "klarna": return "avec Klarna";
    case "en_ligne": return "par paiement en ligne";
    case "especes": return "en espèces auprès du transporteur";
    case "virement": return "par virement bancaire";
    default: return "";
  }
}

export function avecJustificatif(reglement) {
  return ["carte", "klarna", "en_ligne"].includes(reglement?.type);
}

// --------------------------------------------------------------------------
// Dessin
// --------------------------------------------------------------------------
class Canvas {
  constructor(page, fonts) {
    this.page = page;
    this.f = fonts;
    this.cache = new Map();
  }

  // Polices standard (WinAnsi) : tout caractère non imprimable est remplacé,
  // jamais d'échec de génération à cause d'un nom ou d'une adresse.
  safe(text, bold = false) {
    const font = bold ? this.f.bold : this.f.regular;
    let out = "";
    for (const ch of String(text ?? "").replace(/[→➔➡]/g, "-").replace(/\s+/g, " ")) {
      const key = `${bold}:${ch}`;
      if (!this.cache.has(key)) {
        let ok = ch;
        try { font.encodeText(ch); } catch {
          const plain = ch.normalize("NFD").replace(/[̀-ͯ]/g, "");
          try { font.encodeText(plain); ok = plain; } catch { ok = "?"; }
        }
        this.cache.set(key, ok);
      }
      out += this.cache.get(key);
    }
    return out;
  }

  width(text, size, bold = false) {
    return (bold ? this.f.bold : this.f.regular).widthOfTextAtSize(this.safe(text, bold), size);
  }

  // y = distance depuis le HAUT de la page jusqu'à la ligne de base.
  text(text, x, y, { size = 9.5, bold = false, color = DARK, align = "left" } = {}) {
    const t = this.safe(text, bold);
    const w = this.width(t, size, bold);
    const px = align === "right" ? x - w : align === "center" ? x - w / 2 : x;
    this.page.drawText(t, { x: px, y: H - y, size, font: bold ? this.f.bold : this.f.regular, color });
    return w;
  }

  // Suite de segments sur une même ligne (gras / normal / couleurs).
  runs(parts, x, y, size = 9.5) {
    let cx = x;
    for (const p of parts) {
      cx += this.text(p.t, cx, y, { size, bold: p.bold, color: p.color || DARK });
    }
    return cx - x;
  }

  wrap(text, size, maxWidth, bold = false, breakAnywhere = false) {
    const words = breakAnywhere ? [...this.safe(text, bold)] : this.safe(text, bold).split(" ");
    const sep = breakAnywhere ? "" : " ";
    const lines = [];
    let cur = "";
    for (const w of words) {
      const test = cur ? cur + sep + w : w;
      if (cur && this.width(test, size, bold) > maxWidth) { lines.push(cur); cur = w; } else cur = test;
    }
    if (cur) lines.push(cur);
    return lines;
  }

  rect(x, yTop, w, h, { fill, border, borderWidth = 1, radius = 0 } = {}) {
    if (radius > 0) {
      const r = Math.min(radius, w / 2, h / 2);
      const path = `M ${r} 0 H ${w - r} Q ${w} 0 ${w} ${r} V ${h - r} Q ${w} ${h} ${w - r} ${h} H ${r} Q 0 ${h} 0 ${h - r} V ${r} Q 0 0 ${r} 0 Z`;
      this.page.drawSvgPath(path, { x, y: H - yTop, color: fill, borderColor: border, borderWidth: border ? borderWidth : 0 });
      return;
    }
    this.page.drawRectangle({ x, y: H - yTop - h, width: w, height: h, color: fill, borderColor: border, borderWidth: border ? borderWidth : 0 });
  }

  line(x1, y, x2, color = LINE, thickness = 0.75) {
    this.page.drawLine({ start: { x: x1, y: H - y }, end: { x: x2, y: H - y }, color, thickness });
  }
}

function enTete(c, logo) {
  const top = 14 * MM;
  const logoSize = 44 * PX;
  c.page.drawImage(logo, { x: LEFT, y: H - top - logoSize, width: logoSize, height: logoSize });
  const tx = LEFT + logoSize + 10 * PX;
  const w = c.text("SEC", tx, top + 20, { size: 22, bold: true, color: ORANGE });
  c.text("OTO", tx + w, top + 20, { size: 22, bold: true, color: DARK });
  c.text("Transport de véhicules sur plateau et convoyage", tx, top + 31, { size: 7.5, color: GREY });
  const lignes = [
    [`${SECOTO.dirigeant} — EI`, true],
    ["SECOTO (entrepreneur individuel)", false],
    [SECOTO.adresse1, false],
    [SECOTO.adresse2, false],
    [`${SECOTO.email} · ${SECOTO.telephone}`, false],
    [`SIRET ${SECOTO.siret} · RCS Nanterre`, false],
  ];
  lignes.forEach(([t, bold], i) => c.text(t, RIGHT, top + 8 + i * 12.8, { size: 8, bold, color: bold ? DARK : GREY, align: "right" }));
  return top + 6 * 12.8;
}

function bandeau(c, y, titre, droite) {
  const h = 26;
  c.rect(LEFT, y, CW, h, { fill: ORANGE, radius: 2.5 });
  c.text(titre, LEFT + 9, y + 17.5, { size: 13, bold: true, color: WHITE });
  c.text(droite, RIGHT - 9, y + 16.5, { size: 8.5, color: WHITE, align: "right" });
  return y + h;
}

function signature(c, y) {
  const w = 70 * MM;
  const x = RIGHT - w;
  c.line(x, y, RIGHT, DARK, 0.75);
  c.text("Pour SECOTO,", x, y + 13, { size: 9 });
  c.runs([{ t: SECOTO.dirigeant, bold: true }, { t: ", entrepreneur individuel (EI)" }], x, y + 25, 9);
}

function piedDePage(c) {
  const y = H - 10 * MM - 22;
  c.line(LEFT, y, RIGHT);
  const l1 = `SECOTO — ${SECOTO.dirigeant}, entrepreneur individuel (EI) · SIRET ${SECOTO.siret} · RCS Nanterre · APE 8299Z · ${SECOTO.adresse1}, ${SECOTO.adresse2}`;
  const lignes = [...c.wrap(l1, 7.5, CW), `TVA non applicable, article 293 B du CGI · ${SECOTO.email} · ${SECOTO.telephone}`];
  lignes.forEach((t, i) => c.text(t, W / 2, y + 11 + i * 11, { size: 7.5, color: GREY, align: "center" }));
}

function boite(c, x, y, w, titre, lignes) {
  // lignes : [{ label?, value }] ; hauteur calculée d'après le contenu.
  const pad = 9;
  const lh = 13.3;
  const rendu = [];
  for (const l of lignes) {
    if (!l || !l.value) continue;
    const prefix = l.label ? `${l.label} : ` : "";
    const wrapped = c.wrap(prefix + l.value, 9.5, w - 2 * pad, false);
    wrapped.forEach((t, i) => rendu.push({ t, label: i === 0 ? l.label : null, bold: l.bold }));
  }
  const h = pad + 12 + rendu.length * lh + pad - 2;
  return { h, dessiner: (hauteur) => {
    c.rect(x, y, w, hauteur, { fill: LGREY, radius: 2.5 });
    c.text(titre.toUpperCase(), x + pad, y + pad + 7, { size: 8, bold: true, color: ORANGE });
    rendu.forEach((r, i) => {
      const by = y + pad + 12 + 10 + i * lh;
      if (r.label) {
        const lab = `${r.label} : `;
        const lw = c.text(lab, x + pad, by, { size: 9.5, bold: true });
        c.text(r.t.slice(c.safe(lab).length), x + pad + lw, by, { size: 9.5 });
      } else {
        c.text(r.t, x + pad, by, { size: 9.5, bold: r.bold });
      }
    });
  } };
}

function pageFacture(c, logo, d) {
  let y = enTete(c, logo) + 7 * MM;
  y = bandeau(c, y, `FACTURE N° ${d.numero}`, `Date d'émission : ${dateFr(d.dateEmission)} · Commande ${d.ref}`);
  y += 6 * MM;

  const colW = (CW - 8 * MM) / 2;
  const client = boite(c, LEFT, y, colW, "Facturé à", [
    { value: d.client.nom, bold: true },
    { value: d.client.type },
    { value: d.client.adresse },
    { value: d.client.email },
    { value: telephoneFr(d.client.telephone) },
  ]);
  const transport = boite(c, LEFT + colW + 8 * MM, y, colW, "Transport", [
    { label: "Véhicule", value: d.transport.vehicule },
    { label: "Mode", value: d.transport.mode === "convoyage" ? "convoyage par la route" : "camion plateau" },
    { label: "Prise en charge", value: dateFr(d.transport.priseEnCharge) },
    { label: "Livraison enregistrée", value: dateFr(d.transport.livraison) },
    { label: "Réalisé par", value: d.transport.transporteur ? `${d.transport.transporteur}, ${d.transport.mode === "convoyage" ? "convoyeur" : "transporteur"} partenaire validé par SECOTO` : "" },
  ]);
  const hCols = Math.max(client.h, transport.h);
  client.dessiner(hCols);
  transport.dessiner(hCols);
  y += hCols + 7 * MM;

  // Tableau
  c.rect(LEFT, y, CW, 21, { fill: DARK });
  c.text("DÉSIGNATION", LEFT + 7, y + 14, { size: 8, bold: true, color: WHITE });
  c.text("QTÉ", RIGHT - 85, y + 14, { size: 8, bold: true, color: WHITE, align: "right" });
  c.text("MONTANT", RIGHT - 7, y + 14, { size: 8, bold: true, color: WHITE, align: "right" });
  y += 21;
  const designation = d.transport.mode === "convoyage"
    ? "Convoyage de véhicule par la route — forfait tout compris"
    : "Transport de véhicule sur camion plateau — forfait tout compris";
  const desW = CW - 120;
  const desL = c.wrap(designation, 9.5, desW, true);
  const sub = [
    d.adresseDepart && `Enlèvement : ${d.adresseDepart}`,
    d.adresseArrivee && `Livraison : ${d.adresseArrivee}`,
    [d.distanceKm ? `Distance : ${Math.round(d.distanceKm)} km` : null,
      d.transport.mode === "convoyage" ? "Carburant et péages inclus" : "Chargement, sanglage, déchargement, carburant et péages inclus"].filter(Boolean).join(" · "),
  ].filter(Boolean).flatMap((t) => c.wrap(t, 8.5, desW));
  let ry = y + 16;
  desL.forEach((t, i) => c.text(t, LEFT + 7, ry + i * 12, { size: 9.5, bold: true }));
  c.text("1", RIGHT - 85, ry, { size: 9.5, align: "right" });
  c.text(euros(d.montantCents), RIGHT - 7, ry, { size: 9.5, align: "right" });
  ry += desL.length * 12 + 1;
  sub.forEach((t, i) => c.text(t, LEFT + 7, ry + i * 11, { size: 8.5, color: GREY }));
  y = ry + sub.length * 11 + 2;
  c.line(LEFT, y, RIGHT);
  y += 4 * MM;

  // Totaux
  const tw = 78 * MM;
  const tx = RIGHT - tw;
  [["Total HT", euros(d.montantCents)], ["TVA", euros(0)]].forEach(([l, v], i) => {
    c.text(l, tx + 7, y + 13 + i * 19, { size: 9.5 });
    c.text(v, RIGHT - 7, y + 13 + i * 19, { size: 9.5, align: "right" });
  });
  y += 38;
  c.rect(tx, y, tw, 23, { fill: DARK, radius: 2.5 });
  c.text("Total TTC", tx + 7, y + 15.5, { size: 11, bold: true, color: WHITE });
  c.text(euros(d.montantCents), RIGHT - 7, y + 15.5, { size: 11, bold: true, color: WHITE, align: "right" });
  y += 23 + 7 * MM;

  // Encadré PAYÉE
  const textX = LEFT + 112;
  const textW = RIGHT - 12 - textX;
  const phrase = `Montant de ${euros(d.montantCents)} réglé intégralement ${libelleReglement(d.reglement)} le ${dateFr(d.reglement.date)}.`;
  const l1 = c.wrap(`Facture acquittée. ${phrase}`, 9.5, textW);
  const lignes = [...l1];
  if (avecJustificatif(d.reglement) && d.reglement.intentId) {
    lignes.push(...c.wrap(`Paiement sécurisé via Stripe · référence : ${d.reglement.intentId}`, 9.5, textW));
  }
  const boxH = Math.max(52, 16 + (lignes.length + 1) * 13.5);
  c.rect(LEFT, y, CW, boxH, { border: GREEN, borderWidth: 1.5, radius: 3 });
  // Tampon PAYÉE légèrement incliné.
  const sw = c.width("PAYÉE", 15, true) + 16;
  const sx = LEFT + 14;
  const sy = y + boxH / 2 + 12;
  c.page.drawRectangle({ x: sx, y: H - sy, width: sw, height: 24, borderColor: GREEN, borderWidth: 1.5, rotate: degrees(4) });
  c.page.drawText(c.safe("PAYÉE", true), { x: sx + 8, y: H - sy + 7, size: 15, font: c.f.bold, color: GREEN, rotate: degrees(4) });
  let ty = y + 17;
  lignes.forEach((t, i) => {
    if (i === 0 && t.startsWith("Facture acquittée.")) {
      const w2 = c.text("Facture acquittée.", textX, ty, { size: 9.5, bold: true });
      c.text(t.slice("Facture acquittée.".length), textX + w2, ty, { size: 9.5 });
    } else {
      c.text(t, textX, ty, { size: 9.5 });
    }
    ty += 13.5;
  });
  const w3 = c.text("Reste à payer : ", textX, ty, { size: 9.5 });
  c.text("0,00 €", textX + w3, ty, { size: 9.5, bold: true });
  y += boxH + 7 * MM;

  // Mentions
  const mentions = [
    "TVA non applicable, article 293 B du CGI.",
    `Facture établie conformément à la commande ${d.ref} passée sur app.secoto-transport.fr.`,
    avecJustificatif(d.reglement) ? "Justificatif de paiement joint en page 2." : null,
  ].filter(Boolean);
  mentions.forEach((t, i) => c.text(t, LEFT, y + 8 + i * 12, { size: 8, color: GREY }));
  y += mentions.length * 12 + 8 * MM;
  signature(c, y);
  piedDePage(c);
}

function pageJustificatif(c, logo, d) {
  const r = d.reglement;
  let y = enTete(c, logo) + 7 * MM;
  y = bandeau(c, y, "JUSTIFICATIF DE PAIEMENT", `Annexe à la facture ${d.numero}`);
  y += 6 * MM;
  const intro = c.wrap("Le paiement ci-dessous a été encaissé par SECOTO via son prestataire de paiement Stripe. Données extraites du compte Stripe de SECOTO.", 9.5, CW);
  intro.forEach((t, i) => c.text(t, LEFT, y + 10 + i * 13.3, { size: 9.5 }));
  y += intro.length * 13.3 + 7 * MM;

  const email = r.payeur?.nom ? r.payeur.email : d.client.email;
  const payeur = [r.payeur?.nom || d.client.nom, email ? `(${email})` : ""].filter(Boolean).join(" ");
  const lignes = [
    ["Payeur", payeur],
    ["Montant payé", euros(r.montantCents ?? d.montantCents), true],
    ["Date et heure du paiement", r.date ? `${dateFr(r.date)} à ${heureFr(r.date)} (heure de Paris)` : ""],
    ["Moyen de paiement", r.moyen],
    ["Authentification", r.troisDS ? "3-D Secure validée par la banque du titulaire" : ""],
    ["Code d'autorisation bancaire", r.codeAutorisation],
    ["Statut", r.statut, false, GREEN],
    ["Libellé sur le relevé bancaire", r.libelleReleve],
    ["Références Stripe", [r.intentId && `Paiement ${r.intentId}`, r.chargeId && `Transaction ${r.chargeId}`].filter(Boolean).join("\n")],
    ["Objet", `Commande ${d.ref} · transport ${d.trajetCourt}`],
  ].filter((l) => l[1]);
  const valX = LEFT + CW * 0.45;
  const valW = RIGHT - 7 - valX;
  for (const [label, value, bold, color] of lignes) {
    const vals = String(value).split("\n").flatMap((v) => c.wrap(v, 9.5, valW, bold));
    c.text(label, LEFT + 7, y + 16, { size: 9.5, color: GREY });
    vals.forEach((t, i) => {
      const nomPayeur = r.payeur?.nom || d.client.nom;
      if (label === "Payeur" && i === 0 && nomPayeur && t.startsWith(c.safe(nomPayeur, true))) {
        const w = c.text(nomPayeur, valX, y + 16, { size: 9.5, bold: true });
        c.text(t.slice(c.safe(nomPayeur, true).length), valX + w, y + 16, { size: 9.5 });
      } else if (label === "Statut" && i === 0 && t.startsWith("Paiement réussi")) {
        const w = c.text("Paiement réussi", valX, y + 16, { size: 9.5, bold: true, color: GREEN });
        c.text(t.slice("Paiement réussi".length), valX + w, y + 16, { size: 9.5 });
      } else {
        c.text(t, valX, y + 16 + i * 13, { size: 9.5, bold, color: color && label !== "Statut" ? color : DARK });
      }
    });
    y += 16 + (vals.length - 1) * 13 + 9;
    c.line(LEFT, y, RIGHT);
  }
  y += 8 * MM;

  if (r.recuUrl) {
    const url = c.wrap(r.recuUrl, 8, CW - 24, false, true);
    const h = 26 + url.length * 11 + 8;
    c.rect(LEFT, y, CW, h, { border: GREEN, borderWidth: 1.5, radius: 3 });
    const w = c.text("Vérification :", LEFT + 12, y + 17, { size: 9.5, bold: true });
    c.text(" le reçu officiel émis par Stripe est consultable à l'adresse suivante :", LEFT + 12 + w, y + 17, { size: 9.5 });
    url.forEach((t, i) => c.text(t, LEFT + 12, y + 31 + i * 11, { size: 8 }));
    y += h + 10 * MM;
  } else {
    y += 4 * MM;
  }
  signature(c, y);
  piedDePage(c);
}

/**
 * Construit le PDF (Uint8Array).
 * d = { numero, dateEmission, ref, montantCents, client{nom,type,adresse,email,telephone},
 *       transport{vehicule,mode,priseEnCharge,livraison,transporteur}, adresseDepart, adresseArrivee,
 *       distanceKm, trajetCourt, reglement{type,date,intentId,chargeId,moyen,troisDS,codeAutorisation,
 *       statut,libelleReleve,recuUrl,payeur{nom,email},montantCents} }
 */
export async function buildFacturePdf(d) {
  if (!d?.numero || !d?.ref || !Number.isFinite(Number(d?.montantCents)) || !d?.reglement?.type) {
    throw new Error("facture_donnees_incompletes");
  }
  const pdf = await PDFDocument.create();
  pdf.setTitle(`Facture ${d.numero} — SECOTO`);
  pdf.setAuthor(`SECOTO — ${SECOTO.dirigeant} (EI)`);
  pdf.setCreator("SECOTO");
  pdf.setCreationDate(d.dateEmission ? new Date(d.dateEmission) : new Date());
  const fonts = {
    regular: await pdf.embedFont(StandardFonts.Helvetica),
    bold: await pdf.embedFont(StandardFonts.HelveticaBold),
  };
  const logo = await pdf.embedPng(Buffer.from(LOGO_SECOTO_PNG_BASE64, "base64"));
  pageFacture(new Canvas(pdf.addPage([W, H]), fonts), logo, d);
  if (avecJustificatif(d.reglement)) {
    pageJustificatif(new Canvas(pdf.addPage([W, H]), fonts), logo, d);
  }
  return pdf.save();
}

export function nomFichierFacture(numero) {
  return `Facture-${String(numero).replace(/[^A-Za-z0-9-]/g, "")}-SECOTO.pdf`;
}
