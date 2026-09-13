-- Marca de "ya se le pidió una reseña a este paciente" para que el botón ⭐
-- de la ficha sea de un solo uso por paciente (no se puede volver a mandar
-- la invitación una vez que se mandó).
alter table pacientes add column if not exists review_solicitado_at timestamptz;
