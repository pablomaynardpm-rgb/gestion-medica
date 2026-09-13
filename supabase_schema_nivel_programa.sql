-- Componentes del programa que dependen de terceros — determinan si el
-- paciente queda identificado como "Dorado" (todos incluidos) o "Platinum"
-- (falta alguno) en las tarjetas. Sin usar las palabras "premium"/"VIP" en
-- ningún lado de la UI, tal como pidió Pablo.
alter table pacientes add column if not exists incluye_anatomia_patologica boolean not null default false;
alter table pacientes add column if not exists incluye_kinesiologia boolean not null default false;
alter table pacientes add column if not exists incluye_neumonologia_preqx boolean not null default false;
alter table pacientes add column if not exists incluye_cardiologia_preqx boolean not null default false;
