(function () {
  const params = new URLSearchParams(window.location.search);
  const requested = Number(params.get("preview"));
  if (!Number.isFinite(requested) || requested < 1) return;

  const pages = Array.from(document.querySelectorAll(".page"));
  const selected = pages[requested - 1];
  if (!selected) return;

  document.body.classList.add("preview-mode");
  selected.classList.add("preview-selected");
})();
