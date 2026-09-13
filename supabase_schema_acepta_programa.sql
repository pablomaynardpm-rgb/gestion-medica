-- Si el paciente acepta el programa (y en qué medida), independiente del
-- tipo_consentimiento (que hace falta para CUALQUIER cirugía, tome o no el
-- programa). Reemplaza el disparador implícito que tenía el nivel antes.
alter table pacientes add column if not exists acepta_programa text;
alter table pacientes add constraint pacientes_acepta_programa_check
  check (acepta_programa is null or acepta_programa in ('no', 'solo_cirugia', 'si'));
