alter table pacientes drop constraint if exists pacientes_materiales_check;
alter table pacientes add constraint pacientes_materiales_check
  check (materiales is null or materiales in ('no_requiere','pendiente_autorizacion','autorizados','en_quirofano'));
