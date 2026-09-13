-- ============================================================
-- Sincronización con Google Calendar (broadcast a todos los médicos conectados)
-- ============================================================

-- Tokens de Google por médico. Tabla separada de `medicos` (que es de lectura
-- compartida entre todo el equipo) para que el refresh_token de cada médico
-- solo lo pueda leer/escribir ese mismo médico.
create table if not exists medico_calendar_tokens (
  medico_id uuid primary key references medicos(id) on delete cascade,
  refresh_token text not null,
  connected_at timestamptz not null default now()
);
alter table medico_calendar_tokens enable row level security;

create policy "self_all_medico_calendar_tokens"
  on medico_calendar_tokens for all
  to authenticated
  using (medico_id = auth.uid())
  with check (medico_id = auth.uid());

-- Reemplaza la columna singular preparada antes por un mapa {medico_id: event_id},
-- porque el mismo paciente puede tener un evento distinto en el calendario de cada médico.
alter table pacientes drop column if exists google_calendar_event_id;
alter table pacientes add column if not exists google_calendar_event_ids jsonb not null default '{}'::jsonb;
