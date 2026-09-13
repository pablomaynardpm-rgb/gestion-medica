-- ============================================================
-- Calculadora de guía: servicios facturables con precio que se van
-- agregando con el tiempo, y planes (combinaciones de esos servicios, con
-- nombre y opcionalmente un PDF propio) para poder proyectarle al paciente
-- el monto total sin decirlo en voz alta, y mandarle por WhatsApp la guía
-- específica de su plan.
-- ============================================================

create table if not exists servicios_guia (
  id uuid primary key default gen_random_uuid(),
  medico_id uuid not null references medicos(id) on delete cascade,
  nombre text not null,
  precio numeric not null default 0,
  created_at timestamptz not null default now()
);
alter table servicios_guia enable row level security;
create policy "medico_own_servicios_guia"
  on servicios_guia for all
  to authenticated
  using (medico_id = auth.uid())
  with check (medico_id = auth.uid());
create index if not exists idx_servicios_guia_medico on servicios_guia(medico_id);

create table if not exists planes_guia (
  id uuid primary key default gen_random_uuid(),
  medico_id uuid not null references medicos(id) on delete cascade,
  nombre text not null,
  archivo_pdf text,
  created_at timestamptz not null default now()
);
alter table planes_guia enable row level security;
create policy "medico_own_planes_guia"
  on planes_guia for all
  to authenticated
  using (medico_id = auth.uid())
  with check (medico_id = auth.uid());
create index if not exists idx_planes_guia_medico on planes_guia(medico_id);

-- Qué servicios componen cada plan (muchos a muchos).
create table if not exists planes_guia_servicios (
  plan_id uuid not null references planes_guia(id) on delete cascade,
  servicio_id uuid not null references servicios_guia(id) on delete cascade,
  primary key (plan_id, servicio_id)
);
alter table planes_guia_servicios enable row level security;
create policy "medico_own_planes_guia_servicios"
  on planes_guia_servicios for all
  to authenticated
  using (exists (select 1 from planes_guia pg where pg.id = plan_id and pg.medico_id = auth.uid()))
  with check (exists (select 1 from planes_guia pg where pg.id = plan_id and pg.medico_id = auth.uid()));
