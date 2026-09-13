-- ============================================================
-- Agenda pasa a ser un calendario quirúrgico derivado de pacientes.fecha_qx
-- (no más "turnos" de consultorio/quirúrgica como entidad separada).
-- ============================================================

drop table if exists agenda;

alter table pacientes add column if not exists google_calendar_event_id text;
