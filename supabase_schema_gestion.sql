-- ============================================================
-- Extensión: Gestión médica (médicos, pacientes, agenda, sanatorios)
-- Se agrega sobre el esquema existente de Interconsultas.
-- ============================================================

-- Lista canónica de sanatorios (referencia compartida entre todos los médicos)
create table if not exists sanatorios (
  id uuid primary key default gen_random_uuid(),
  nombre text not null unique,
  created_at timestamptz not null default now()
);
alter table sanatorios enable row level security;
create policy "authenticated_full_access_sanatorios"
  on sanatorios for all
  to authenticated
  using (true)
  with check (true);

-- Perfil de cada médico (uno por usuario de Supabase Auth)
create table if not exists medicos (
  id uuid primary key references auth.users(id) on delete cascade,
  nombre text not null,
  especialidad text,
  color text,
  created_at timestamptz not null default now()
);
alter table medicos enable row level security;

-- Todos los médicos logueados pueden ver la lista de médicos (para asignaciones)
create policy "authenticated_read_medicos"
  on medicos for select
  to authenticated
  using (true);

-- Un médico solo puede crear/editar su propia fila
create policy "self_insert_medicos"
  on medicos for insert
  to authenticated
  with check (id = auth.uid());

create policy "self_update_medicos"
  on medicos for update
  to authenticated
  using (id = auth.uid())
  with check (id = auth.uid());

-- Pacientes: cada médico ve y edita solo los suyos
create table if not exists pacientes (
  id uuid primary key default gen_random_uuid(),
  medico_id uuid not null references medicos(id) on delete cascade,
  nombre text not null,
  dni text,
  fecha_nacimiento date,
  telefono text,
  email text,
  obra_social text,
  notas text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
alter table pacientes enable row level security;
create policy "medico_own_pacientes"
  on pacientes for all
  to authenticated
  using (medico_id = auth.uid())
  with check (medico_id = auth.uid());
create index if not exists idx_pacientes_medico on pacientes(medico_id);

-- Agenda: consultorio y quirófano, por sanatorio, cada médico ve solo la suya
create table if not exists agenda (
  id uuid primary key default gen_random_uuid(),
  medico_id uuid not null references medicos(id) on delete cascade,
  paciente_id uuid references pacientes(id) on delete set null,
  paciente_nombre text,
  sanatorio text,
  tipo text not null default 'consultorio' check (tipo in ('consultorio','quirurgica')),
  fecha date not null,
  hora_inicio time,
  hora_fin time,
  motivo text,
  estado text not null default 'programada' check (estado in ('programada','confirmada','realizada','cancelada')),
  notas text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
alter table agenda enable row level security;
create policy "medico_own_agenda"
  on agenda for all
  to authenticated
  using (medico_id = auth.uid())
  with check (medico_id = auth.uid());
create index if not exists idx_agenda_medico_fecha on agenda(medico_id, fecha);
create index if not exists idx_agenda_paciente on agenda(paciente_id);
