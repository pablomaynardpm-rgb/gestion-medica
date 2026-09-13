-- Marca de "ya se le mandó la guía premium a este paciente" (fecha del
-- último envío) — deja registro de que se mandó, a diferencia del pedido de
-- reseña esto NO es de un solo uso: la guía se puede reenviar (ej: el
-- paciente la perdió, o cambió algo), solo queda historial de cuándo.
alter table pacientes add column if not exists guia_enviada_at timestamptz;
