-- Agrega horario y repetición estilo Google Calendar a consultorio_dias.
-- La repetición se "materializa": al crear una serie repetida, se insertan
-- todas las filas individuales de una sola vez (una por fecha), todas
-- compartiendo el mismo grupo_id. Así cada ocurrencia sigue siendo una fila
-- normal, editable/borrable individualmente, sin necesidad de un motor de
-- recurrencia (RRULE) en tiempo de lectura.
alter table consultorio_dias add column if not exists hora_inicio time;
alter table consultorio_dias add column if not exists hora_fin time;
alter table consultorio_dias add column if not exists grupo_id uuid;

create index if not exists consultorio_dias_grupo_id_idx on consultorio_dias(grupo_id);
