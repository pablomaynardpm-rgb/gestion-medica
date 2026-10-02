-- Link de invitación de RCTA (el que el médico le comparte al paciente para que
-- complete sus datos). Se usa desde el botón "Enviar alta de RCTA" en la ficha.
alter table medicos add column if not exists rcta_link text;

-- Marca de que ya se le mandó el alta de RCTA a este paciente (de un solo uso,
-- igual que el pedido de reseña y la ficha de contacto).
alter table pacientes add column if not exists rcta_enviado_at timestamptz;
