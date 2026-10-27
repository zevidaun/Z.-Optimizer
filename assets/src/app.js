// Construye el carril y la consola comunes a todas las capturas
(function () {
  const win = document.querySelector('.win');
  const active = win.dataset.page;
  const items = ['Inicio', 'Z. Plan', 'Registro', 'Optimizador', 'Juegos', 'Restaurar'];
  const rail = document.createElement('aside');
  rail.className = 'rail';
  rail.innerHTML = `
    <div class="logo"><div class="z">Z.</div><div class="o">Optimizer</div></div>
    <div class="nav">${items.map(i => `<div class="${i === active ? 'on' : ''}">${i}</div>`).join('')}</div>
    <div class="railfoot">
      <div class="k">Plan de energía</div>
      <div class="plan"><span class="dot"></span>Z. Plan</div>
      <div class="v">Versión 1.1<br>Windows 11 24H2 a 26H2</div>
    </div>`;
  win.prepend(rail);
  const log = win.dataset.log ? document.getElementById(win.dataset.log).innerHTML : '';
  const con = document.createElement('div');
  con.className = 'console';
  con.innerHTML = `<div class="hd"><span>Actividad</span>${win.dataset.busy ? '<span class="busy">Trabajando…</span>' : ''}<span class="clr">Limpiar</span></div><div class="log">${log}</div>`;
  win.querySelector('.main').append(con);
})();
