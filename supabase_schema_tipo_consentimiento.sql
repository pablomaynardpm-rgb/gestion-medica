-- ============================================================
-- Tipo de consentimiento informado, para la guía premium por WhatsApp:
-- determina qué PDF de consentimiento (de los 4 armados por Pablo) se
-- adjunta automáticamente. Se sugiere solo a partir de "operacion" (texto
-- libre) pero queda siempre editable a mano desde la ficha.
-- ============================================================
alter table pacientes add column if not exists tipo_consentimiento text;
alter table pacientes add constraint pacientes_tipo_consentimiento_check
  check (tipo_consentimiento is null or tipo_consentimiento in (
    'reseccion-pulmonar', 'mediastinoscopia', 'vats-pleural', 'decorticacion-trauma'
  ));
