-- Campo "piso" para interconsultas, separado de "habitacion": la carga
-- manual pide piso y cama (no habitación), y los mensajes de WhatsApp a
-- veces mencionan el piso en vez de (o además de) el número de habitación.
alter table interconsultas add column if not exists piso text;
