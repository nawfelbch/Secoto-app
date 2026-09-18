import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const kitDir = path.dirname(fileURLToPath(import.meta.url));

const documents = [
  {
    html: "sources/fiche-commerciale.html",
    pdf: "SECOTO_Fiche_Commerciale_Pro.pdf",
    expectedPages: 2,
  },
  {
    html: "sources/dossier-solution.html",
    pdf: "SECOTO_Dossier_Solution_Entreprises.pdf",
    expectedPages: 7,
  },
  {
    html: "sources/proposition-commerciale.html",
    pdf: "SECOTO_Modele_Proposition_Commerciale.pdf",
    expectedPages: 5,
  },
];

let hasError = false;

for (const document of documents) {
  const htmlPath = path.join(kitDir, document.html);
  const pdfPath = path.join(kitDir, document.pdf);
  const html = fs.readFileSync(htmlPath, "utf8");
  const sourcePages = (html.match(/<section class="page(?:\s|")/g) || []).length;

  if (!fs.existsSync(pdfPath)) {
    console.error(`ERREUR — PDF absent : ${document.pdf}`);
    hasError = true;
    continue;
  }

  const pdf = fs.readFileSync(pdfPath);
  const pdfText = pdf.toString("latin1");
  const pageObjects = (pdfText.match(/\/Type\s*\/Page\b/g) || []).length;
  const sizeKb = Math.round(pdf.length / 1024);
  const valid =
    sourcePages === document.expectedPages &&
    pageObjects === document.expectedPages &&
    pdf.length > 50_000;

  console.log(
    `${valid ? "OK" : "ERREUR"} — ${document.pdf} · ` +
    `${sourcePages} pages source · ${pageObjects} pages PDF · ${sizeKb} Ko`,
  );

  if (!valid) hasError = true;
}

if (hasError) process.exit(1);
