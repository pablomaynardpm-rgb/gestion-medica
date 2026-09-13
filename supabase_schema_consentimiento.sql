alter table pacientes add column if not exists consentimiento_link text;
alter table pacientes add column if not exists consentimiento_estado text;
alter table pacientes add constraint pacientes_consentimiento_estado_check
  check (consentimiento_estado is null or consentimiento_estado in ('pendiente','entregado','firmado'));
