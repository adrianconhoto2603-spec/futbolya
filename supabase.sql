-- FutbolYa · base de datos para Supabase
-- Pegá TODO este archivo en Supabase > SQL Editor > New query y tocá "Run".

-- ============ TABLAS ============
create table if not exists public.perfiles (
  id uuid primary key references auth.users (id) on delete cascade,
  email text not null,
  telefono text not null check (telefono ~ '^\+?[0-9 -]{8,18}$'),
  creado timestamptz not null default now()
);

create table if not exists public.partidos (
  id bigint generated always as identity primary key,
  creador_id uuid not null references public.perfiles (id) on delete cascade,
  titulo text not null check (char_length(titulo) between 1 and 60),
  lugar text not null check (char_length(lugar) between 1 and 80),
  fecha_hora timestamptz not null,
  max_jugadores int not null check (max_jugadores between 2 and 30),
  arqueros_buscados int not null default 0 check (arqueros_buscados between 0 and 2),
  cancelado boolean not null default false,
  creado timestamptz not null default now(),
  check (arqueros_buscados < max_jugadores)
);

create table if not exists public.inscripciones (
  partido_id bigint not null references public.partidos (id) on delete cascade,
  usuario_id uuid not null references public.perfiles (id) on delete cascade,
  como_arquero boolean not null default false,
  creado timestamptz not null default now(),
  primary key (partido_id, usuario_id)
);

-- Seguridad: nadie puede leer ni escribir las tablas directamente desde la web.
-- Todo pasa por las funciones de más abajo, que aplican las reglas.
alter table public.perfiles enable row level security;
alter table public.partidos enable row level security;
alter table public.inscripciones enable row level security;

-- ============ PERFIL AUTOMÁTICO AL REGISTRARSE ============
create or replace function public.crear_perfil() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  insert into public.perfiles (id, email, telefono)
  values (new.id, lower(new.email), coalesce(new.raw_user_meta_data ->> 'telefono', ''));
  return new;
end $$;

drop trigger if exists al_crear_usuario on auth.users;
create trigger al_crear_usuario after insert on auth.users
  for each row execute function public.crear_perfil();

-- ============ FUNCIONES ============
create or replace function public.listar_partidos()
returns table (id bigint, titulo text, lugar text, fecha_hora timestamptz, max_jugadores int,
               arqueros_buscados int, cancelado boolean, soy_organizador boolean,
               anotados bigint, arqueros_anotados bigint, yo_anotado boolean)
language sql stable security definer set search_path = public as $$
  select t.id, t.titulo, t.lugar, t.fecha_hora, t.max_jugadores, t.arqueros_buscados, t.cancelado,
         t.soy_organizador, t.anotados, t.arqueros_anotados, t.yo_anotado
  from (
    select p.id, p.titulo, p.lugar, p.fecha_hora, p.max_jugadores, p.arqueros_buscados, p.cancelado,
      (p.creador_id = auth.uid()) as soy_organizador,
      (select count(*) from public.inscripciones i where i.partido_id = p.id) as anotados,
      (select count(*) from public.inscripciones i where i.partido_id = p.id and i.como_arquero) as arqueros_anotados,
      exists (select 1 from public.inscripciones i where i.partido_id = p.id and i.usuario_id = auth.uid()) as yo_anotado
    from public.partidos p
    where auth.uid() is not null and p.fecha_hora >= now() - interval '3 hours'
  ) t
  where t.cancelado = false or t.yo_anotado
  order by t.fecha_hora;
$$;

create or replace function public.crear_partido(p_titulo text, p_lugar text, p_fecha timestamptz, p_max int, p_arq int)
returns bigint
language plpgsql security definer set search_path = public as $$
declare v_id bigint;
begin
  if auth.uid() is null then raise exception 'Iniciá sesión para continuar.'; end if;
  if p_titulo is null or char_length(trim(p_titulo)) not between 1 and 60 then
    raise exception 'Poné un título de hasta 60 caracteres.'; end if;
  if p_lugar is null or char_length(trim(p_lugar)) not between 1 and 80 then
    raise exception 'Indicá dónde se juega (hasta 80 caracteres).'; end if;
  if p_fecha is null or p_fecha < now() then
    raise exception 'Elegí una fecha y hora futuras.'; end if;
  if p_max is null or p_max not between 2 and 30 then
    raise exception 'La cantidad de jugadores debe estar entre 2 y 30.'; end if;
  if p_arq is null or p_arq not between 0 and 2 or p_arq >= p_max then
    raise exception 'Los arqueros que faltan deben ser 0, 1 o 2.'; end if;
  insert into public.partidos (creador_id, titulo, lugar, fecha_hora, max_jugadores, arqueros_buscados)
  values (auth.uid(), trim(p_titulo), trim(p_lugar), p_fecha, p_max, p_arq)
  returning partidos.id into v_id;
  insert into public.inscripciones (partido_id, usuario_id) values (v_id, auth.uid());
  return v_id;
end $$;

create or replace function public.detalle_partido(p_id bigint)
returns json
language plpgsql stable security definer set search_path = public as $$
declare
  v_p public.partidos%rowtype;
  v_yo boolean;
  v_ve boolean;
begin
  if auth.uid() is null then raise exception 'Iniciá sesión para continuar.'; end if;
  select * into v_p from public.partidos where id = p_id;
  if not found then raise exception 'El partido no existe.'; end if;
  v_yo := exists (select 1 from public.inscripciones where partido_id = p_id and usuario_id = auth.uid());
  v_ve := v_yo or v_p.creador_id = auth.uid();   -- los teléfonos solo los ven anotados y organizador
  return json_build_object(
    'id', v_p.id, 'titulo', v_p.titulo, 'lugar', v_p.lugar, 'fecha_hora', v_p.fecha_hora,
    'max_jugadores', v_p.max_jugadores, 'arqueros_buscados', v_p.arqueros_buscados,
    'cancelado', v_p.cancelado, 'soy_organizador', v_p.creador_id = auth.uid(), 'yo_anotado', v_yo,
    'anotados', (select count(*) from public.inscripciones where partido_id = p_id),
    'arqueros_anotados', (select count(*) from public.inscripciones where partido_id = p_id and como_arquero),
    'jugadores', coalesce((
      select json_agg(json_build_object(
          'nombre', split_part(u.email, '@', 1),
          'es_organizador', i.usuario_id = v_p.creador_id,
          'es_arquero', i.como_arquero,
          'telefono', case when v_ve then u.telefono else null end
        ) order by i.creado)
      from public.inscripciones i join public.perfiles u on u.id = i.usuario_id
      where i.partido_id = p_id), '[]'::json)
  );
end $$;

create or replace function public.unirse_partido(p_id bigint, p_arquero boolean)
returns void
language plpgsql security definer set search_path = public as $$
declare
  v_p public.partidos%rowtype;
  v_total int;
  v_arq int;
begin
  if auth.uid() is null then raise exception 'Iniciá sesión para continuar.'; end if;
  select * into v_p from public.partidos where id = p_id for update;
  if not found then raise exception 'El partido no existe.'; end if;
  if v_p.cancelado then raise exception 'Este partido fue cancelado.'; end if;
  if exists (select 1 from public.inscripciones where partido_id = p_id and usuario_id = auth.uid()) then
    return;
  end if;
  select count(*), count(*) filter (where como_arquero) into v_total, v_arq
    from public.inscripciones where partido_id = p_id;
  if v_total >= v_p.max_jugadores then raise exception 'El partido ya está completo.'; end if;
  if coalesce(p_arquero, false) then
    if v_arq >= v_p.arqueros_buscados then
      raise exception 'Ya no hacen falta arqueros en este partido.'; end if;
  else
    if v_total + greatest(0, v_p.arqueros_buscados - v_arq) >= v_p.max_jugadores then
      raise exception 'Solo quedan lugares reservados para arqueros.'; end if;
  end if;
  insert into public.inscripciones (partido_id, usuario_id, como_arquero)
  values (p_id, auth.uid(), coalesce(p_arquero, false));
end $$;

create or replace function public.salir_partido(p_id bigint)
returns void
language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'Iniciá sesión para continuar.'; end if;
  delete from public.inscripciones where partido_id = p_id and usuario_id = auth.uid();
end $$;

create or replace function public.cancelar_partido(p_id bigint)
returns void
language plpgsql security definer set search_path = public as $$
declare v_creador uuid;
begin
  if auth.uid() is null then raise exception 'Iniciá sesión para continuar.'; end if;
  select creador_id into v_creador from public.partidos where id = p_id;
  if not found then raise exception 'El partido no existe.'; end if;
  if v_creador <> auth.uid() then raise exception 'Solo el organizador puede cancelar el partido.'; end if;
  update public.partidos set cancelado = true where id = p_id;
end $$;

-- Función simple para mantener el proyecto activo (la usa la tarea programada de GitHub)
create or replace function public.ping() returns text
language sql stable as $$ select (select count(*) from public.perfiles)::text $$;

-- ============ PERMISOS ============
-- Solo usuarios con sesión iniciada pueden usar las funciones (excepto ping).
revoke execute on all functions in schema public from public, anon;
grant execute on all functions in schema public to authenticated;
grant execute on function public.ping() to anon, authenticated;
