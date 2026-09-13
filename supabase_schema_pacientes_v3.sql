-- ============================================================
-- Materiales (operación), laboratorio estructurado, notas y copago.
-- ============================================================

alter table pacientes add column if not exists materiales text;
alter table pacientes add constraint pacientes_materiales_check
  check (materiales is null or materiales in ('no_requiere','pendiente_autorizacion','autorizados'));

alter table pacientes add column if not exists notas text;

alter table pacientes add column if not exists copago_monto text;
alter table pacientes add column if not exists copago_estado text;
alter table pacientes add constraint pacientes_copago_estado_check
  check (copago_estado is null or copago_estado in ('pago','pendiente','no_acepta'));

-- preqx.laboratorio pasa de texto libre a objeto estructurado
-- {hto, hb, leuco, coagulograma, urea, creatinina, na, k, cl, otros} — sin migración de datos
-- porque es jsonb (los registros existentes con laboratorio como string simplemente
-- se ignoran/pisan la próxima vez que se guarde ese paciente desde la app).
