-- ============================================================
-- Ficha de paciente extendida: datos clínicos, antecedentes,
-- preQx (laboratorio, RCV, funcional respiratorio, imágenes) y links.
-- ============================================================

alter table pacientes rename column obra_social to os;
alter table pacientes rename column notas to datos_clinicos;

alter table pacientes add column if not exists sanatorio text;
alter table pacientes add column if not exists edad integer;
alter table pacientes add column if not exists nro_afiliado text;
alter table pacientes add column if not exists diagnostico text;
alter table pacientes add column if not exists antecedentes jsonb not null default '{}'::jsonb;
alter table pacientes add column if not exists operacion text;
alter table pacientes add column if not exists fecha_qx date;
alter table pacientes add column if not exists preqx jsonb not null default '{}'::jsonb;
alter table pacientes add column if not exists protocolo_qx_link text;
alter table pacientes add column if not exists anatomia_patologica_link text;

-- Bucket privado para imágenes de estudios (TC/PET). Cada médico solo accede
-- a objetos guardados bajo su propio auth.uid() como primer segmento de ruta:
-- {medico_id}/{paciente_id}/{tc|pet}/archivo.jpg
insert into storage.buckets (id, name, public)
values ('estudios-imagenes', 'estudios-imagenes', false)
on conflict (id) do nothing;

create policy "medico_own_images_select"
  on storage.objects for select
  to authenticated
  using (bucket_id = 'estudios-imagenes' and (storage.foldername(name))[1] = auth.uid()::text);

create policy "medico_own_images_insert"
  on storage.objects for insert
  to authenticated
  with check (bucket_id = 'estudios-imagenes' and (storage.foldername(name))[1] = auth.uid()::text);

create policy "medico_own_images_delete"
  on storage.objects for delete
  to authenticated
  using (bucket_id = 'estudios-imagenes' and (storage.foldername(name))[1] = auth.uid()::text);
