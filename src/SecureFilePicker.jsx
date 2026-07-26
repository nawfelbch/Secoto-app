import { useRef, useState } from "react";
import { compressEvidenceImage, validateFiles } from "./lib/fileSafety";
import { isNativePlatform, takeNativePhoto } from "./platform/runtime";

const previewCache = new WeakMap();

function previewUrl(file) {
  if (!file?.type?.startsWith("image/")) return null;
  if (!previewCache.has(file)) previewCache.set(file, URL.createObjectURL(file));
  return previewCache.get(file);
}

function removePreview(file) {
  const url = previewCache.get(file);
  if (url) URL.revokeObjectURL(url);
  previewCache.delete(file);
}

export default function SecureFilePicker({
  files = [],
  onChange,
  label = "Photos et documents",
  allowPdf = true,
  maxFiles = 10,
  maxSizeBytes = 12 * 1024 * 1024,
  disabled = false,
  progress = null,
}) {
  const inputRef = useRef(null);
  const [error, setError] = useState("");
  const [preparing, setPreparing] = useState(false);

  async function addFiles(incoming) {
    setPreparing(true);
    setError("");
    try {
      const prepared = [];
      for (const file of Array.from(incoming || [])) {
        prepared.push(await compressEvidenceImage(file));
      }
      const merged = [...files, ...prepared];
      const validation = validateFiles(merged, { allowPdf, maxFiles, maxSizeBytes });
      if (!validation.ok) {
        prepared.forEach(removePreview);
        setError(validation.errors.join(" "));
        return;
      }
      onChange(merged);
    } finally {
      setPreparing(false);
      if (inputRef.current) inputRef.current.value = "";
    }
  }

  async function takePhoto() {
    setError("");
    const result = await takeNativePhoto();
    if (result.ok) await addFiles([result.file]);
    else if (!["cancelled", "web"].includes(result.reason)) {
      setError("La caméra n’est pas disponible. Utilisez le sélecteur de fichiers.");
    }
  }

  function removeFile(index) {
    const removed = files[index];
    removePreview(removed);
    onChange(files.filter((_, current) => current !== index));
  }

  return (
    <div className="field field-full secure-picker">
      <span>{label}</span>
      <div className="actions-row">
        {isNativePlatform() && (
          <button className="btn ghost small" type="button" onClick={takePhoto} disabled={disabled || preparing}>
            Prendre une photo
          </button>
        )}
        <button className="btn ghost small" type="button" onClick={() => inputRef.current?.click()} disabled={disabled || preparing}>
          Choisir sur l’appareil
        </button>
      </div>
      <input
        ref={inputRef}
        className="visually-hidden-file"
        type="file"
        accept={allowPdf ? "image/jpeg,image/png,image/webp,application/pdf,.jpg,.jpeg,.png,.webp,.pdf" : "image/jpeg,image/png,image/webp,.jpg,.jpeg,.png,.webp"}
        multiple
        onChange={(event) => addFiles(event.target.files)}
        disabled={disabled}
      />
      {preparing && <small>Préparation et compression des preuves…</small>}
      {error && <div className="alert error compact">{error}</div>}
      {files.length > 0 && (
        <div className="file-preview-grid">
          {files.map((file, index) => {
            const imageUrl = previewUrl(file);
            return (
              <div className="file-preview" key={`${file.name}-${file.lastModified}-${index}`}>
                {imageUrl ? <img src={imageUrl} alt={`Aperçu ${file.name}`} /> : <span className="file-icon">PDF</span>}
                <div>
                  <strong title={file.name}>{file.name}</strong>
                  <small>{(file.size / 1024 / 1024).toFixed(1)} Mo</small>
                </div>
                <button type="button" className="btn danger small" onClick={() => removeFile(index)} disabled={disabled}>
                  Retirer
                </button>
              </div>
            );
          })}
        </div>
      )}
      {Number.isFinite(progress) && (
        <div className="upload-progress" role="progressbar" aria-valuemin="0" aria-valuemax="100" aria-valuenow={progress}>
          <span style={{ width: `${Math.max(0, Math.min(100, progress))}%` }} />
          <small>{progress}%</small>
        </div>
      )}
    </div>
  );
}
