-- Historial de cirugías anteriores, para poder reoperar a un paciente sin
-- perder el registro de la cirugía previa. Los campos "activos" (operacion,
-- fecha_qx, hora_qx, materiales, operado) siguen representando SIEMPRE la
-- cirugía más reciente/vigente — todo lo que ya lee esos campos (Agenda,
-- Google Calendar, Resumen, condición) sigue funcionando sin cambios.
alter table pacientes add column if not exists cirugias jsonb not null default '[]'::jsonb;
