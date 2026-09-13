-- ============================================================
-- Interconsultas facturadas aparte por sanatorio (ej: Berazategui):
-- valor por interconsulta + tabla oculta donde queda un registro
-- (fecha, sanatorio, paciente, tipo, valor) al contestar o programar
-- una interconsulta de un sanatorio con valor cargado, para poder
-- exportar y facturar después aunque la interconsulta original ya
-- se haya borrado de la lista principal.
-- ============================================================

create table if not exists precios_interconsulta (
  id uuid primary key default gen_random_uuid(),
  medico_id uuid not null references medicos(id) on delete cascade,
  sanatorio text not null,
  valor numeric not null,
  created_at timestamptz not null default now(),
  unique(medico_id, sanatorio)
);
alter table precios_interconsulta enable row level security;
create policy "medico_own_precios_interconsulta"
  on precios_interconsulta for all
  to authenticated
  using (medico_id = auth.uid())
  with check (medico_id = auth.uid());

create table if not exists interconsultas_facturables (
  id uuid primary key default gen_random_uuid(),
  medico_id uuid not null references medicos(id) on delete cascade,
  sanatorio text,
  paciente text,
  fecha date not null default current_date,
  tipo text not null check (tipo in ('contestada','programada')),
  valor numeric,
  created_at timestamptz not null default now()
);
alter table interconsultas_facturables enable row level security;
create policy "medico_own_interconsultas_facturables"
  on interconsultas_facturables for all
  to authenticated
  using (medico_id = auth.uid())
  with check (medico_id = auth.uid());
create index if not exists idx_ic_facturables_medico on interconsultas_facturables(medico_id);
