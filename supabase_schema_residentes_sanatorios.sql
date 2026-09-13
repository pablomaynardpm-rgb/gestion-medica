-- ============================================================
-- Acceso por sanatorio para residentes: además de rol/supervisor,
-- un residente puede quedar restringido a ver/editar solo pacientes
-- (y sus internaciones) de ciertos sanatorios, en vez de todos los
-- del supervisor. NULL = sin restricción (todos los sanatorios,
-- comportamiento actual). Un array no vacío = solo esos sanatorios.
--
-- Nota Postgres: "x = ANY(subquery)" es ambiguo cuando el subquery
-- devuelve una sola fila de tipo array — Postgres lo interpreta como
-- "comparar contra cada fila" en vez de "desanidar el array", lo que
-- tira "operator does not exist: text = text[]". Por eso todo acá usa
-- "= ANY(coalesce(subquery, array[]::text[]))" para forzar que primero
-- se evalúe como un único valor array y recién ahí se le aplique ANY.
-- ============================================================

alter table medicos add column if not exists sanatorios_permitidos text[];

-- ---- pacientes: agrega el filtro de sanatorio a las 3 policies de residente ----
alter policy "residente_select_pacientes_supervisor" on pacientes
  using (
    medico_id = (select supervisor_id from medicos where id = auth.uid())
    and (
      (select sanatorios_permitidos from medicos where id = auth.uid()) is null
      or pacientes.sanatorio = any(coalesce((select sanatorios_permitidos from medicos where id = auth.uid()), array[]::text[]))
    )
  );

alter policy "residente_insert_pacientes_supervisor" on pacientes
  with check (
    medico_id = (select supervisor_id from medicos where id = auth.uid())
    and (
      (select sanatorios_permitidos from medicos where id = auth.uid()) is null
      or pacientes.sanatorio = any(coalesce((select sanatorios_permitidos from medicos where id = auth.uid()), array[]::text[]))
    )
  );

alter policy "residente_update_pacientes_supervisor" on pacientes
  using (
    medico_id = (select supervisor_id from medicos where id = auth.uid())
    and (
      (select sanatorios_permitidos from medicos where id = auth.uid()) is null
      or pacientes.sanatorio = any(coalesce((select sanatorios_permitidos from medicos where id = auth.uid()), array[]::text[]))
    )
  )
  with check (
    medico_id = (select supervisor_id from medicos where id = auth.uid())
    and (
      (select sanatorios_permitidos from medicos where id = auth.uid()) is null
      or pacientes.sanatorio = any(coalesce((select sanatorios_permitidos from medicos where id = auth.uid()), array[]::text[]))
    )
  );

-- ---- internaciones: un residente no tenía NINGÚN acceso hasta ahora; se
-- agrega, con el mismo criterio de supervisor + sanatorio permitido, y sin
-- DELETE (mismo criterio ya usado para pacientes: nada destructivo para un
-- residente).
create policy "residente_select_internaciones_supervisor"
  on internaciones for select
  to authenticated
  using (
    medico_id = (select supervisor_id from medicos where id = auth.uid())
    and (
      (select sanatorios_permitidos from medicos where id = auth.uid()) is null
      or internaciones.sanatorio = any(coalesce((select sanatorios_permitidos from medicos where id = auth.uid()), array[]::text[]))
    )
  );

create policy "residente_insert_internaciones_supervisor"
  on internaciones for insert
  to authenticated
  with check (
    medico_id = (select supervisor_id from medicos where id = auth.uid())
    and (
      (select sanatorios_permitidos from medicos where id = auth.uid()) is null
      or internaciones.sanatorio = any(coalesce((select sanatorios_permitidos from medicos where id = auth.uid()), array[]::text[]))
    )
  );

create policy "residente_update_internaciones_supervisor"
  on internaciones for update
  to authenticated
  using (
    medico_id = (select supervisor_id from medicos where id = auth.uid())
    and (
      (select sanatorios_permitidos from medicos where id = auth.uid()) is null
      or internaciones.sanatorio = any(coalesce((select sanatorios_permitidos from medicos where id = auth.uid()), array[]::text[]))
    )
  )
  with check (
    medico_id = (select supervisor_id from medicos where id = auth.uid())
    and (
      (select sanatorios_permitidos from medicos where id = auth.uid()) is null
      or internaciones.sanatorio = any(coalesce((select sanatorios_permitidos from medicos where id = auth.uid()), array[]::text[]))
    )
  );

-- ---- self_insert_medicos: valida sanatorios_permitidos contra el JWT igual
-- que ya se hace con rol/supervisor_id (mismo motivo: evitar que alguien se
-- auto-otorgue "sin restricción" al completar su perfil por primera vez).
alter policy "self_insert_medicos" on medicos
  with check (
    id = auth.uid()
    and rol = coalesce(nullif(auth.jwt()->'user_metadata'->>'rol', ''), 'medico')
    and supervisor_id is not distinct from nullif(auth.jwt()->'user_metadata'->>'supervisor_id', '')::uuid
    and sanatorios_permitidos is not distinct from (
      case when auth.jwt()->'user_metadata'->'sanatorios_permitidos' is null then null
      else array(select jsonb_array_elements_text(auth.jwt()->'user_metadata'->'sanatorios_permitidos')) end
    )
  );

-- ---- trigger anti-auto-ascenso: ahora también protege sanatorios_permitidos
-- (un residente no puede sacarse su propia restricción con un UPDATE directo).
create or replace function prevent_self_role_escalation()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if (new.rol is distinct from old.rol
      or new.supervisor_id is distinct from old.supervisor_id
      or new.sanatorios_permitidos is distinct from old.sanatorios_permitidos) then
    if coalesce((select rol from medicos where id = auth.uid()), '') <> 'medico' then
      new.rol := old.rol;
      new.supervisor_id := old.supervisor_id;
      new.sanatorios_permitidos := old.sanatorios_permitidos;
    end if;
  end if;
  return new;
end;
$$;
