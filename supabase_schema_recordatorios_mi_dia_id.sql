-- La página "Mi día" (Apps Script) necesita el id de cada recordatorio para armar el enlace
-- https://app.pablomaynard.com.ar/?recordatorio={id}. La Edge Function mi-dia-recordatorios
-- devuelve tal cual lo que responde esta función, así que el campo se agrega acá.
-- Sin cambios en la validación del token ni en el resto de los campos.
create or replace function public.recordatorios_mi_dia(p_token text)
returns json
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  hoy date := (now() at time zone 'America/Argentina/Buenos_Aires')::date;
begin
  if not exists (select 1 from vault.decrypted_secrets where name = 'mi_dia_token' and decrypted_secret = p_token) then
    raise exception 'forbidden';
  end if;
  return coalesce((
    select json_agg(json_build_object('id', id, 'texto', texto, 'paciente', paciente, 'fecha', fecha, 'hora', hora)
                    order by fecha, hora nulls last)
    from recordatorios
    where user_id = 'a2c95576-9fbe-4f64-b053-127251780ab3'
      and not completado
      and fecha <= hoy
  ), '[]'::json);
end;
$function$;
