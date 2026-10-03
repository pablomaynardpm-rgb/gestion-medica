-- Tipo de paciente (quirúrgico / no quirúrgico) y autorización de cirugía separada
-- de materiales. Las fechas *_enviada_at alimentan el aviso de "sin respuesta".
alter table pacientes add column if not exists tipo_paciente text;
alter table pacientes add column if not exists autorizacion_cx text;
alter table pacientes add column if not exists autorizacion_cx_enviada_at timestamptz;
alter table pacientes add column if not exists materiales_enviado_at timestamptz;

alter table pacientes add constraint pacientes_tipo_paciente_check
  check (tipo_paciente is null or tipo_paciente in ('quirurgico', 'no_quirurgico'));
alter table pacientes add constraint pacientes_autorizacion_cx_check
  check (autorizacion_cx is null or autorizacion_cx in ('enviada', 'aceptada', 'rechazada', 'no_requiere'));

alter table pacientes drop constraint pacientes_materiales_check;
alter table pacientes add constraint pacientes_materiales_check
  check (materiales is null or materiales in ('no_requiere', 'pendiente_autorizacion', 'autorizados', 'en_quirofano', 'rechazados'));

-- La lista de la ficha ya ofrecía "simpatectomia-hiperhidrosis" pero la restricción no la aceptaba.
alter table pacientes drop constraint pacientes_tipo_consentimiento_check;
alter table pacientes add constraint pacientes_tipo_consentimiento_check
  check (tipo_consentimiento is null or tipo_consentimiento in ('reseccion-pulmonar', 'mediastinoscopia', 'vats-pleural', 'decorticacion-trauma', 'simpatectomia-hiperhidrosis'));

update pacientes set tipo_paciente = 'quirurgico'
  where tipo_paciente is null and (coalesce(operado, false) or fecha_qx is not null or materiales is not null);
update pacientes set autorizacion_cx = 'aceptada'
  where autorizacion_cx is null and (coalesce(operado, false) or fecha_qx is not null);
