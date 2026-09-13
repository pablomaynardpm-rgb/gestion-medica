alter table pacientes add column if not exists sexo text;
alter table pacientes add constraint pacientes_sexo_check
  check (sexo is null or sexo in ('masculino','femenino'));
