-- ============================================================
-- Consultorio: registro de consultas para facturación mensual
-- (Berazategui, UOM Avellaneda, AG Consultorios, etc. — sanatorios
-- donde el pago de las consultas es aparte), + precios por
-- sanatorio y obra social para autocompletar el valor.
-- ============================================================

create table if not exists consultas (
  id uuid primary key default gen_random_uuid(),
  medico_id uuid not null references medicos(id) on delete cascade,
  sanatorio text,
  fecha date not null default current_date,
  paciente text,
  os text,
  valor numeric,
  created_at timestamptz not null default now()
);
alter table consultas enable row level security;
create policy "medico_own_consultas"
  on consultas for all
  to authenticated
  using (medico_id = auth.uid())
  with check (medico_id = auth.uid());
create index if not exists idx_consultas_medico on consultas(medico_id);

create table if not exists precios_consulta (
  id uuid primary key default gen_random_uuid(),
  medico_id uuid not null references medicos(id) on delete cascade,
  sanatorio text not null,
  os text not null,
  valor numeric not null,
  created_at timestamptz not null default now(),
  unique(medico_id, sanatorio, os)
);
alter table precios_consulta enable row level security;
create policy "medico_own_precios_consulta"
  on precios_consulta for all
  to authenticated
  using (medico_id = auth.uid())
  with check (medico_id = auth.uid());
