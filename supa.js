if (/PEGAR/.test(SUPABASE_URL + SUPABASE_ANON_KEY)) {
  alert('Falta pegar los datos de Supabase en el archivo config.js');
}
const sb = supabase.createClient(SUPABASE_URL, SUPABASE_ANON_KEY);

function traducir(msg) {
  const m = String(msg || '');
  if (/Invalid login credentials/i.test(m)) return 'Email o contraseña incorrectos.';
  if (/already registered|already been registered/i.test(m)) return 'Ya existe una cuenta con ese email.';
  if (/Email not confirmed/i.test(m)) return 'Tenés que confirmar tu email antes de entrar. Revisá tu casilla.';
  if (/rate limit|too many/i.test(m)) return 'Demasiados intentos. Esperá unos minutos y probá de nuevo.';
  if (/Failed to fetch|NetworkError|Load failed/i.test(m)) return 'No se pudo conectar con el servidor. Revisá tu internet y probá de nuevo.';
  if (/Database error saving new user/i.test(m)) return 'No se pudo crear la cuenta. Revisá que el teléfono sea válido.';
  return m || 'Algo salió mal. Probá de nuevo.';
}

// Llama a una función de la base de datos y devuelve el resultado
async function rpc(nombre, args) {
  const { data, error } = await sb.rpc(nombre, args);
  if (error) {
    if (/JWT|Iniciá sesión/i.test(error.message)) location.href = 'index.html';
    throw new Error(traducir(error.message));
  }
  return data;
}
