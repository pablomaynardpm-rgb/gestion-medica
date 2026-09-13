-- Cierra un hueco: el alta inicial de "medicos" (self-insert al completar
-- "Completá tu perfil") antes solo validaba que el id fuera el propio, sin
-- validar el rol/supervisor_id que el cliente mandaba — un residente podría
-- haber mandado rol:"medico" a mano y auto-otorgarse acceso completo. Ahora
-- se valida contra lo que quedó grabado en su propio JWT (user_metadata),
-- que solo la Edge Function invite-medico pudo haber puesto ahí (con la
-- secret key, al invitar), no algo que el navegador del invitado controle.
alter policy "self_insert_medicos" on medicos
  with check (
    id = auth.uid()
    and rol = coalesce(nullif(auth.jwt()->'user_metadata'->>'rol', ''), 'medico')
    and supervisor_id is not distinct from nullif(auth.jwt()->'user_metadata'->>'supervisor_id', '')::uuid
  );
