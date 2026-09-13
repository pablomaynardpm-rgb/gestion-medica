-- ============================================================
-- Cola de capturas de pantalla subidas directo en Gestión Médica
-- (en vez de por Telegram) para carga de interconsultas. El
-- mismo agente programado que ya revisa Telegram cada 2hs también
-- procesa estas filas (sin costo extra de API por imagen).
-- ============================================================

create table if not exists interconsultas_capturas_pendientes (
  id uuid primary key default gen_random_uuid(),
  medico_id uuid not null references medicos(id) on delete cascade,
  storage_path text not null,
  estado text not null default 'pendiente' check (estado in ('pendiente','procesada','error')),
  error_mensaje text,
  created_at timestamptz not null default now(),
  procesada_at timestamptz
);
alter table interconsultas_capturas_pendientes enable row level security;

-- Compartido entre todos los médicos del equipo, mismo modelo que interconsultas/contactos/zonas.
create policy "authenticated_full_access_capturas_pendientes"
  on interconsultas_capturas_pendientes for all
  to authenticated
  using (true)
  with check (true);

create index if not exists idx_capturas_pendientes_estado on interconsultas_capturas_pendientes(estado);

insert into storage.buckets (id, name, public)
values ('interconsultas-capturas', 'interconsultas-capturas', false)
on conflict (id) do nothing;

create policy "authenticated_insert_capturas"
  on storage.objects for insert
  to authenticated
  with check (bucket_id = 'interconsultas-capturas');

create policy "authenticated_select_capturas"
  on storage.objects for select
  to authenticated
  using (bucket_id = 'interconsultas-capturas');

create policy "authenticated_delete_capturas"
  on storage.objects for delete
  to authenticated
  using (bucket_id = 'interconsultas-capturas');
