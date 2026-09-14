-- Igual que review_solicitado_at: marca de que ya se le mandó la ficha de
-- contacto a este paciente, para no duplicar el envío (de un solo uso,
-- igual que el pedido de reseña).
alter table pacientes add column if not exists contacto_enviado_at timestamptz;
