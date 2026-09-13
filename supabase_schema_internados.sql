-- ============================================================
-- Internados: episodios de internación por paciente, con log de
-- evolución compacto (jsonb) independiente de la ficha principal.
-- ============================================================

create table if not exists internaciones (
  id uuid primary key default gen_random_uuid(),
  medico_id uuid not null references medicos(id) on delete cascade,
  paciente_id uuid not null references pacientes(id) on delete cascade,
  sanatorio text,
  sector text,
  habitacion text,
  cama text,
  fecha_ingreso date not null default current_date,
  fecha_alta date,
  evoluciones jsonb not null default '[]'::jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
alter table internaciones enable row level security;

create policy "medico_own_internaciones"
  on internaciones for all
  to authenticated
  using (medico_id = auth.uid())
  with check (medico_id = auth.uid());

create index if not exists idx_internaciones_medico on internaciones(medico_id);
create index if not exists idx_internaciones_paciente on internaciones(paciente_id);
