-- ============================================================
-- Rol "residente": un usuario del equipo con acceso restringido
-- (solo Pacientes/Agenda/Resumen, y solo los pacientes de su
-- supervisor) en vez de acceso completo como un "medico" normal.
-- ============================================================

alter table medicos add column if not exists rol text not null default 'medico' check (rol in ('medico','residente'));
alter table medicos add column if not exists supervisor_id uuid references medicos(id);

-- Devuelve el rol del usuario logueado. security definer para poder leer
-- medicos sin depender de (ni disparar recursión con) las policies de la
-- propia tabla medicos.
create or replace function current_medico_rol()
returns text
language sql
stable
security definer
set search_path = public
as $$
  select rol from medicos where id = auth.uid()
$$;

-- Las tablas compartidas de todo el equipo (interconsultas, contactos, zonas)
-- quedan reservadas a médicos reales — un residente no las ve ni las edita.
alter policy "authenticated_full_access_interconsultas" on interconsultas
  using (current_medico_rol() = 'medico')
  with check (current_medico_rol() = 'medico');

alter policy "authenticated_full_access_contactos" on contactos
  using (current_medico_rol() = 'medico')
  with check (current_medico_rol() = 'medico');

alter policy "authenticated_full_access_zonas" on zonas
  using (current_medico_rol() = 'medico')
  with check (current_medico_rol() = 'medico');

-- Un médico (no un residente) puede editar la fila de CUALQUIER integrante
-- del equipo — necesario para poder asignarle rol "residente" + supervisor
-- a un compañero desde el panel "Médicos del equipo". self_update_medicos
-- (ya existente) sigue permitiendo que cada uno edite su propia fila.
create policy "medico_asigna_roles_equipo"
  on medicos for update
  to authenticated
  using (current_medico_rol() = 'medico')
  with check (current_medico_rol() = 'medico');

-- Un residente ve/crea/edita (no borra) los pacientes de su supervisor,
-- además de (potencialmente, si algún día tuviera pacientes propios) los suyos.
create policy "residente_select_pacientes_supervisor"
  on pacientes for select
  to authenticated
  using (medico_id = (select supervisor_id from medicos where id = auth.uid()));

create policy "residente_insert_pacientes_supervisor"
  on pacientes for insert
  to authenticated
  with check (medico_id = (select supervisor_id from medicos where id = auth.uid()));

create policy "residente_update_pacientes_supervisor"
  on pacientes for update
  to authenticated
  using (medico_id = (select supervisor_id from medicos where id = auth.uid()))
  with check (medico_id = (select supervisor_id from medicos where id = auth.uid()));

-- Mismo criterio para las imágenes de estudios (TC/PET) de esos pacientes.
create policy "residente_select_imagenes_supervisor"
  on storage.objects for select
  to authenticated
  using (
    bucket_id = 'estudios-imagenes'
    and (storage.foldername(name))[1] = (select supervisor_id::text from medicos where id = auth.uid())
  );

create policy "residente_insert_imagenes_supervisor"
  on storage.objects for insert
  to authenticated
  with check (
    bucket_id = 'estudios-imagenes'
    and (storage.foldername(name))[1] = (select supervisor_id::text from medicos where id = auth.uid())
  );
