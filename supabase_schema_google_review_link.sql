-- Link de reseñas de Google Business de cada médico (uno por médico, no por
-- paciente). Se usa para armar el mensaje de WhatsApp que invita a un
-- paciente a dejar una reseña, desde el botón "⭐" en la ficha de paciente.
alter table medicos add column if not exists google_review_link text;
