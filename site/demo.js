"use strict";

const byId = (id) => document.getElementById(id);
const apps = [
  { name: "Atlas Studio", architecture: 3_840_000_000, language: 450_000_000 },
  { name: "Beacon Browser", architecture: 1_180_000_000, language: 710_000_000 },
  { name: "Field Notes", architecture: 800_000_000, language: 300_000_000 },
];
const appBytes = (app) => app.architecture + app.language;
const identified = apps.reduce((sum, app) => ({
  architecture: sum.architecture + app.architecture,
  language: sum.language + app.language,
}), { architecture: 0, language: 0 });

const architecture = byId("show-architecture");
const language = byId("show-language");

function format(bytes) {
  if (bytes === 0) return "0 bytes";
  if (bytes < 1_000_000_000) return `${(bytes / 1_000_000).toLocaleString()} MB`;
  return `${(bytes / 1_000_000_000).toLocaleString(undefined, { maximumFractionDigits: 2 })} GB`;
}

function selected(size) {
  return (architecture.checked ? size.architecture : 0) + (language.checked ? size.language : 0);
}

function renderTrack(track, size, scale, anchorsLanguages = true) {
  const width = (bytes) => `${bytes / scale * 100}%`;
  track.style.setProperty("--architecture-width", width(anchorsLanguages || architecture.checked ? size.architecture : 0));
  track.children[0].style.width = width(architecture.checked ? size.architecture : 0);
  track.children[1].style.width = width(language.checked ? size.language : 0);
}

const rows = apps.map((app) => {
  const row = document.createElement("div");
  row.className = "sample-row";
  const title = document.createElement("span");
  title.textContent = app.name;
  const size = document.createElement("small");
  const track = document.createElement("div");
  track.className = "size-track";
  track.setAttribute("aria-hidden", "true");
  track.append(document.createElement("i"), document.createElement("i"));
  row.append(title, size, track);
  return { app, row, size, track };
});

function render() {
  byId("sample-label").textContent = architecture.checked && language.checked
    ? "AUTOMATICALLY SELECTED"
    : "SELECTED RESOURCES";
  byId("sample-total").textContent = format(selected(identified));
  renderTrack(byId("sample-track"), identified, appBytes(identified));
  const ranked = rows.filter(({ app }) => selected(app) > 0)
    .sort((first, second) => selected(second.app) - selected(first.app));
  const list = byId("sample-list");
  for (const { app, row, size, track } of rows) {
    row.hidden = selected(app) === 0;
    size.textContent = format(selected(app));
    renderTrack(track, app, appBytes(apps[0]), false);
  }
  for (const { row } of ranked) list.append(row);
}

architecture.addEventListener("change", render);
language.addEventListener("change", render);
byId("architecture-size").textContent = format(identified.architecture);
byId("language-size").textContent = format(identified.language);
byId("sample-identified").textContent = `${format(appBytes(identified))} identified`;
render();
