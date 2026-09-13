-- ============================================================
-- Rol de "administrador" (distinto de rol médico/residente): un
-- flag aparte para reservar la gestión del maestro de sanatorios
-- (direcciones, zonas de facturación, contactos vinculados) a un
-- único médico — hoy Pablo — en vez de a cualquier médico del equipo.
-- Pensado para reusarse en futuras pantallas admin-only.
-- ============================================================

alter table medicos add column if not exists es_admin boolean not null default false;

update medicos set es_admin = true where id = 'a2c95576-9fbe-4f64-b053-127251780ab3';

create or replace function current_medico_es_admin()
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select coalesce((select es_admin from medicos where id = auth.uid()), false)
$$;

-- sanatorios/zonas/contactos: la lectura sigue abierta a cualquier
-- autenticado (se usan en dropdowns, colores, autocompletado de IC, etc.
-- en toda la app), pero agregar/editar/borrar queda reservado al admin.
drop policy if exists "authenticated_full_access_sanatorios" on sanatorios;
create policy "authenticated_select_sanatorios"
  on sanatorios for select
  to authenticated
  using (true);
create policy "admin_modifica_sanatorios"
  on sanatorios for all
  to authenticated
  using (current_medico_es_admin())
  with check (current_medico_es_admin());

alter policy "authenticated_full_access_zonas" on zonas
  using (current_medico_es_admin())
  with check (current_medico_es_admin());
create policy "authenticated_select_zonas"
  on zonas for select
  to authenticated
  using (true);

alter policy "authenticated_full_access_contactos" on contactos
  using (current_medico_es_admin())
  with check (current_medico_es_admin());
create policy "authenticated_select_contactos"
  on contactos for select
  to authenticated
  using (true);
