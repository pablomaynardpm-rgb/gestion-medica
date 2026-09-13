-- Tabla de interconsultas
create table if not exists interconsultas (
  id uuid primary key default gen_random_uuid(),
  fecha text,
  sanatorio text,
  paciente text,
  habitacion text,
  cama text,
  diagnostico text,
  estado text not null default 'pendiente',
  fecha_resuelta date,
  original text,
  created_at timestamptz not null default now()
);

-- Tabla de contactos vinculados a sanatorios
create table if not exists contactos (
  id uuid primary key default gen_random_uuid(),
  contacto text not null,
  sanatorio text not null,
  created_at timestamptz not null default now()
);

-- Seguridad: solo usuarios logueados en este proyecto pueden leer/escribir
alter table interconsultas enable row level security;
alter table contactos enable row level security;

create policy "authenticated_full_access_interconsultas"
  on interconsultas for all
  to authenticated
  using (true)
  with check (true);

create policy "authenticated_full_access_contactos"
  on contactos for all
  to authenticated
  using (true)
  with check (true);

-- Zona de facturación por sanatorio (ej: Berazategui, Ranelagh, Bernal)
alter table interconsultas add column if not exists zona text;

create table if not exists zonas (
  id uuid primary key default gen_random_uuid(),
  sanatorio text not null unique,
  zona text not null,
  created_at timestamptz not null default now()
);

alter table zonas enable row level security;

create policy "authenticated_full_access_zonas"
  on zonas for all
  to authenticated
  using (true)
  with check (true);

-- Borrado automático de resueltas 4 meses después de exportarlas
alter table interconsultas add column if not exists exportado_at timestamptz;

create extension if not exists pg_cron with schema extensions;

select cron.schedule(
  'borrar_interconsultas_exportadas',
  '0 6 * * *',
  $$ delete from interconsultas where exportado_at is not null and exportado_at < now() - interval '4 months' $$
);

-- Notificaciones push
create table if not exists push_subscriptions (
  id uuid primary key default gen_random_uuid(),
  endpoint text not null unique,
  p256dh text not null,
  auth text not null,
  created_at timestamptz not null default now()
);

alter table push_subscriptions enable row level security;

create policy "authenticated_full_access_push_subscriptions"
  on push_subscriptions for all
  to authenticated
  using (true)
  with check (true);

-- Disparar la notificación push cada vez que se carga una interconsulta nueva
create extension if not exists pg_net with schema extensions;

create or replace function notify_nueva_interconsulta()
returns trigger
language plpgsql
security definer
as $$
begin
  perform net.http_post(
    url := 'https://cwcsounmbitxmlxedqdu.supabase.co/functions/v1/notify-new-ic',
    headers := jsonb_build_object(
      'Content-Type', 'application/json',
      'x-internal-secret', 'a8039e5aa23e99366ad2bf267db241067397da81e0a71045'
    ),
    body := jsonb_build_object('id', new.id, 'paciente', new.paciente, 'sanatorio', new.sanatorio)
  );
  return new;
end;
$$;

drop trigger if exists trg_notify_nueva_interconsulta on interconsultas;
create trigger trg_notify_nueva_interconsulta
after insert on interconsultas
for each row execute function notify_nueva_interconsulta();
