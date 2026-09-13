-- Días de consultorio agendados por sanatorio, independientes de la
-- facturación de "consultas" (que solo registra visitas ya atendidas).
-- Sirve para que Pablo pueda marcar en la Agenda "tengo consultorio en
-- tal sanatorio tal día" y así detectar si se pisa con una cirugía
-- programada (pacientes.fecha_qx) el mismo día.
create table if not exists consultorio_dias (
  id uuid primary key default gen_random_uuid(),
  medico_id uuid not null references medicos(id),
  fecha date not null,
  sanatorio text,
  created_at timestamptz not null default now(),
  unique (medico_id, fecha, sanatorio)
);

alter table consultorio_dias enable row level security;

create policy "medico_own_consultorio_dias"
  on consultorio_dias for all
  to authenticated
  using (medico_id = auth.uid())
  with check (medico_id = auth.uid());
