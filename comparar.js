// El idioma de las páginas de comparación: el mismo que en index.html
// (?lang=en manda, luego lo que eligió el visitante y luego el navegador).
function setLang(lang) {
  document.body.className = lang === 'en' ? 'en' : '';
  document.documentElement.lang = lang;
  document.querySelectorAll('.lang-btn').forEach(function (b) {
    b.classList.toggle('active', b.getAttribute('data-set') === lang);
  });
  try { localStorage.setItem('lang', lang); } catch (e) {}
}
(function () {
  var url = new URLSearchParams(location.search).get('lang');
  if (url === 'en' || url === 'es') return setLang(url);
  var guardado = null;
  try { guardado = localStorage.getItem('lang'); } catch (e) {}
  if (guardado) return setLang(guardado);
  if ((navigator.language || 'es').slice(0, 2) === 'en') setLang('en');
})();
