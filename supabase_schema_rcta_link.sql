-- Link de invitación de RCTA (el que el médico le comparte al paciente para que
-- complete sus datos). Se usa desde el botón "Enviar alta de RCTA" en la ficha.
alter table medicos add column if not exists rcta_link text;
