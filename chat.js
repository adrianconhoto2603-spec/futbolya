(function () {
  const $ = id => document.getElementById(id);
  const dlg = $('detalle');
  if (!dlg || typeof window.abrirDetalle !== 'function') return;

  const estilo = document.createElement('style');
  estilo.textContent = `
    #chat { margin: 1rem 0; border-top: 2px solid var(--linea); padding-top: .75rem; }
    #chat h4 { font: 700 1.4rem 'Barlow Condensed', sans-serif; margin: 0 0 .5rem; }
    .chat-msgs { min-height: 80px; max-height: 240px; overflow-y: auto; display: flex; flex-direction: column; gap: .4rem; padding: .5rem; background: var(--campo); border: 2px solid var(--linea); }
    .chat-msg { max-width: 88%; padding: .35rem .6rem; background: #fff; border: 1px solid var(--linea); align-self: flex-start; overflow-wrap: anywhere; }
    .chat-msg.mio { align-self: flex-end; background: #e6f4d9; border-color: var(--verde); }
    .chat-meta { font-size: .8rem; color: var(--suave); }
    .chat-meta button { padding: 0 .3rem; font-size: .8rem; font-weight: 600; background: transparent; color: var(--error); border: 0; }
    .chat-vacio { margin: auto; color: var(--suave); }
    .chat-form { display: flex; gap: .5rem; margin-top: .5rem; }
    .chat-form input { flex: 1; min-width: 0; }
    .chat-form button { flex: none; }
  `;
  document.head.append(estilo);

  const caja = document.createElement('section');
  caja.id = 'chat';
  caja.hidden = true;
  caja.innerHTML =
    '<h4>Chat del partido</h4>' +
    '<div class="chat-msgs" id="chatMsgs" aria-live="polite"></div>' +
    '<p class="error" id="chatErr" role="alert"></p>' +
    '<form class="chat-form" id="chatForm">' +
    '<input id="chatTexto" maxlength="500" placeholder="Escribí un mensaje" autocomplete="off" required>' +
    '<button type="submit">Enviar</button></form>';
  $('dAcciones').before(caja);

  const msgs = $('chatMsgs'), err = $('chatErr'), form = $('chatForm'), campo = $('chatTexto');
  let partidoId = null, esOrganizador = false, canal = null, timer = null, firma = null;

  const hora = iso => {
    const f = new Date(iso);
    const h = f.toLocaleTimeString('es-AR', { hour: '2-digit', minute: '2-digit' });
    return f.toDateString() === new Date().toDateString()
      ? h
      : f.toLocaleDateString('es-AR', { day: 'numeric', month: 'short' }) + ' ' + h;
  };

  function pintar(lista) {
    const abajo = msgs.scrollHeight - msgs.scrollTop - msgs.clientHeight < 40;
    msgs.replaceChildren();
    if (!lista.length) {
      const v = document.createElement('p');
      v.className = 'chat-vacio';
      v.textContent = 'Todavía no hay mensajes. Escribí el primero.';
      msgs.append(v);
      return;
    }
    for (const m of lista) {
      const burbuja = document.createElement('div');
      burbuja.className = 'chat-msg' + (m.es_mio ? ' mio' : '');
      const meta = document.createElement('div');
      meta.className = 'chat-meta';
      meta.append(m.nombre + (m.es_organizador ? ' (organizador)' : '') + ' · ' + hora(m.creado));
      if (m.es_mio || esOrganizador) {
        const b = document.createElement('button');
        b.type = 'button';
        b.textContent = 'Borrar';
        b.onclick = () => borrar(m.id);
        meta.append(' ', b);
      }
      const texto = document.createElement('div');
      texto.textContent = m.texto;
      burbuja.append(meta, texto);
      msgs.append(burbuja);
    }
    if (abajo) msgs.scrollTop = msgs.scrollHeight;
  }

  async function refrescar() {
    if (!partidoId || !dlg.open) return;
    const id = partidoId;
    try {
      const lista = await rpc('listar_mensajes', { p_id: id });
      if (id !== partidoId) return;
      const nueva = lista.map(m => m.id).join(',');
      if (nueva === firma) return;
      firma = nueva;
      pintar(lista);
    } catch (e) { /* se reintenta en el próximo ciclo */ }
  }

  function detener() {
    clearInterval(timer);
    timer = null;
    if (canal) { try { sb.removeChannel(canal); } catch (e) {} canal = null; }
  }

  function iniciar() {
    detener();
    firma = null;
    refrescar();
    timer = setInterval(refrescar, 5000);
    try {
      canal = sb.channel('chat-partido-' + partidoId)
        .on('postgres_changes',
            { event: 'INSERT', schema: 'public', table: 'mensajes', filter: 'partido_id=eq.' + partidoId },
            refrescar)
        .subscribe();
    } catch (e) { canal = null; }
  }

  function cerrar() {
    detener();
    partidoId = null;
    firma = null;
    msgs.replaceChildren();
    err.textContent = '';
    caja.hidden = true;
  }

  async function mostrar(id) {
    const otro = id !== partidoId;
    if (otro) { cerrar(); partidoId = id; }
    let det;
    try { det = await rpc('detalle_partido', { p_id: id }); }
    catch (e) { caja.hidden = true; detener(); return; }
    if (!dlg.open || partidoId !== id) return;
    esOrganizador = !!det.soy_organizador;
    const puede = !det.cancelado && (det.yo_anotado || det.soy_organizador);
    caja.hidden = !puede;
    if (!puede) { detener(); firma = null; return; }
    if (otro || !timer) iniciar(); else refrescar();
  }

  async function borrar(idMensaje) {
    err.textContent = '';
    try { await rpc('borrar_mensaje', { p_mensaje: idMensaje }); await refrescar(); }
    catch (ex) { err.textContent = ex.message; }
  }

  form.addEventListener('submit', async e => {
    e.preventDefault();
    const texto = campo.value.trim();
    if (!texto || !partidoId) return;
    err.textContent = '';
    const boton = form.querySelector('button');
    boton.disabled = true;
    try {
      await rpc('enviar_mensaje', { p_id: partidoId, p_texto: texto });
      campo.value = '';
      await refrescar();
      msgs.scrollTop = msgs.scrollHeight;
    } catch (ex) { err.textContent = ex.message; }
    boton.disabled = false;
    campo.focus();
  });

  dlg.addEventListener('close', cerrar);

  const original = window.abrirDetalle;
  window.abrirDetalle = async function (id) {
    await original(id);
    if (dlg.open) mostrar(id);
  };
})();
