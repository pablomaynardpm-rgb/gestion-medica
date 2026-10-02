-- Recordatorios personales (solo admin en la UI). Los lee también el resumen
-- matinal de Apps Script por REST con la secret key: no renombrar columnas.
create table if not exists public.recordatorios (
  id          bigint generated always as identity primary key,
  user_id     uuid not null default auth.uid() references auth.users(id) on delete cascade,
  texto       text not null,
  paciente    text,
  fecha       date not null default current_date,
  hora        time,
  completado  boolean not null default false,
  created_at  timestamptz not null default now()
);

create index if not exists recordatorios_pendientes
  on public.recordatorios (user_id, fecha) where completado = false;

alter table public.recordatorios enable row level security;

create policy "recordatorios_propios" on public.recordatorios
  for all to authenticated
  using (user_id = (select auth.uid()))
  with check (user_id = (select auth.uid()));
