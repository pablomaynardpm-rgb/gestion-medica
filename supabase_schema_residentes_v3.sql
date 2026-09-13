-- Cierra el hueco simétrico al de self_insert_medicos: una vez creada su
-- fila, nada impedía que un residente hiciera un UPDATE directo sobre su
-- propia fila cambiando rol a "medico" (self_update_medicos solo valida
-- id = auth.uid(), no qué columnas cambian). Un trigger es el lugar correcto
-- para esto (a diferencia del insert, acá conviene comparar contra el valor
-- ANTERIOR de la fila, no contra el JWT — porque alguien puede haber sido
-- ascendido a "residente" más tarde vía el panel de equipo, sin que su JWT
-- original tuviera ese dato): si quien edita no es actualmente rol='medico',
-- el trigger revierte silenciosamente rol/supervisor_id a su valor previo y
-- deja pasar el resto del update (nombre/especialidad siguen editables).
create or replace function prevent_self_role_escalation()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if (new.rol is distinct from old.rol or new.supervisor_id is distinct from old.supervisor_id) then
    if coalesce((select rol from medicos where id = auth.uid()), '') <> 'medico' then
      new.rol := old.rol;
      new.supervisor_id := old.supervisor_id;
    end if;
  end if;
  return new;
end;
$$;

drop trigger if exists trg_prevent_self_role_escalation on medicos;
create trigger trg_prevent_self_role_escalation
  before update on medicos
  for each row
  execute function prevent_self_role_escalation();
