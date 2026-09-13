# Dossier técnico — "Gestión Médica"

> Generado automáticamente a partir del código fuente real y de una introspección en vivo de la base de datos de Supabase en producción (no es un resumen de memoria ni una reconstrucción aproximada). Fecha de generación: 2026-08-29.

**Qué es esta app:** una aplicación de gestión de práctica médica multi-doctor (interconsultas, fichas de pacientes, agenda quirúrgica, internados, consultorio/facturación) usada en producción por un cirujano torácico y su equipo (médicos + residentes). Nació como una herramienta chica para organizar interconsultas de WhatsApp y creció, sin cambiar de arquitectura, hasta cubrir todo el flujo clínico-administrativo del consultorio.

**Cómo usar este documento:** está pensado para copiarse tal cual a otro entorno de desarrollo. La Sección 2 es el SQL para recrear la base desde cero. La Sección 4 contiene el código fuente completo y real de la app (no fragmentos ni pseudocódigo). La Sección 5 dice honestamente qué funciona y qué no.

**Nota de seguridad — LEER ANTES DE COPIAR A OTRO LADO:** este documento fue redactado para no contener secretos reales (claves de service-role, tokens de Vercel/Supabase Management API, client secret de Google, tokens de Telegram/VAPID). Donde el código original tiene un secreto hardcodeado en una función de base de datos, se reemplazó por un placeholder y se aclara en el lugar. La única clave que SÍ aparece tal cual en el código fuente es la "publishable key" de Supabase (antes llamada "anon key") — es pública por diseño, ya visible para cualquiera que abra la app en el navegador, y no otorga ningún acceso por sí sola (todo el acceso real está mediado por Row Level Security, ver Sección 2). Si este documento se comparte fuera de este entorno, igual conviene rotar cualquier credencial real antes de subirlo a un repositorio público.

---

## Índice

1. [Stack y dependencias](#1-stack-y-dependencias)
2. [Esquema SQL de Supabase](#2-esquema-sql-de-supabase)
3. [Estructura del proyecto](#3-estructura-del-proyecto)
4. [Código fuente principal](#4-código-fuente-principal)
5. [Estado actual y pendientes](#5-estado-actual-y-pendientes)

---

## 1. Stack y dependencias

**Esto no es una SPA con framework.** Es deliberadamente una sola página HTML estática, sin build step, sin `package.json`, sin bundler, sin transpilación. Esta decisión no es un accidente ni una limitación temporal — se mantuvo así a través de meses de crecimiento (interconsultas → pacientes → agenda → internados → consultorio → roles/residentes → panel admin) precisamente porque simplifica el deploy (subir un archivo) y elimina una capa entera de tooling que no aporta valor para una app de un solo equipo médico.

| Capa | Tecnología | Notas |
|---|---|---|
| Frontend | **HTML + CSS + JavaScript vanilla** (ES2017+, sin transpilar) | Un único archivo `index.html` (~3700 líneas). Sin React/Vue/Angular/Svelte ni ningún framework de componentes. |
| Gestión de UI | Manipulación directa del DOM (`innerHTML`, `addEventListener` delegado) | Patrón consistente en toda la app: cada "vista" tiene una función `render*()` que reconstruye su HTML desde el estado en memoria; los formularios autoguardan campo por campo con eventos `blur`/`change` (no hay un botón "Guardar" global). |
| Estilos | **CSS plano**, variables CSS (`:root { --bg; --panel; --border; --text; --muted; ... }`) | Sin Tailwind/Bootstrap/ningún framework de CSS. Soporta tema claro/oscuro vía `[data-theme]` + `prefers-color-scheme`. |
| Cliente de base de datos | **`@supabase/supabase-js@2`**, cargado por CDN (`https://cdn.jsdelivr.net/npm/@supabase/supabase-js@2`) | Sin instalación npm — es un `<script src>` directo en el `<head>`. Un solo cliente global `const sb = supabase.createClient(URL, PUBLISHABLE_KEY)`. |
| Backend / base de datos | **Supabase** (Postgres administrado + Auth + Storage + Edge Functions + `pg_cron` + `pg_net`) | Un único proyecto Supabase sirve de backend completo — no hay servidor propio. |
| Funciones serverless | **Supabase Edge Functions** (Deno), 5 funciones — ver Sección 3 | Reemplazan lo que en otro stack sería una API REST propia: invitar/borrar médicos, sincronizar Google Calendar, mandar push notifications, y el callback de OAuth de Google. |
| Autenticación | **Supabase Auth** (email + password, con flujo de invitación por link) | Sin proveedor social. RLS (Row Level Security) de Postgres es el mecanismo real de autorización — el frontend nunca es la última línea de defensa. |
| Hosting | **Vercel** (proyecto/equipo "interconsultas"), deploy estático | Deploy manual vía la API REST de Vercel (`POST /v13/deployments`, contenido en base64) — no usa Vercel CLI, no está conectado a un repo Git (no hay repo Git en este proyecto en absoluto). |
| PWA | `manifest.json` + `sw.js` (service worker) | Soporta "Agregar a pantalla de inicio" en Android + notificaciones push web (VAPID) + badge de ícono con el conteo de interconsultas pendientes. |
| Integraciones externas | **Google Calendar API** (OAuth 2.0 + REST), **Telegram Bot API** (ingesta de capturas de WhatsApp vía un bot + rutina programada en la nube que usa visión) | Ver detalle de cada una en la Sección 5. |
| Control de versiones | **Ninguno.** No es un repositorio Git. | El directorio de trabajo es una carpeta local (`C:\Users\pablo\cloude`) con archivos sueltos, sin `.git`. |

**Por qué no hay framework ni build step (contexto, no es un límite técnico):** el proyecto arrancó como una herramienta de una sola pantalla y cada expansión posterior se hizo agregando otra vista dentro del mismo archivo en lugar de reestructurar. Sigue siendo mantenible así porque cada módulo (Interconsultas, Pacientes, Agenda, Internados, Consultorio) tiene sus propias funciones `render*()`/handlers claramente nombrados y no comparte estado mutable más allá de los arrays cargados una vez al iniciar sesión (`pacientes`, `internaciones`, `items` de interconsultas, etc.). Si este proyecto siguiera creciendo bastante más, migrar a un framework con componentes (o al menos separar en múltiples archivos JS con un bundler liviano tipo Vite) sería la recomendación estándar — pero no es necesario para el tamaño actual, y romper la arquitectura de "un solo archivo, deploy sin build" tendría un costo real (ya no se podría deployar con un simple POST a la API de Vercel).


---

## 2. Esquema SQL de Supabase

El SQL de abajo fue generado por **introspección directa de la base de producción** (`information_schema`, `pg_catalog`, `pg_policies`) — no por concatenar los ~19 archivos de migración incrementales del proyecto (que documentan el historial de cómo se llegó acá, pero no son ejecutables de forma idempotente en orden por sí solos). Este es el estado real, ejecutable de punta a punta en un proyecto Supabase nuevo.

**Resumen de las 14 tablas** (todas en el esquema `public`, todas con RLS habilitada excepto `debug_log`):

| Tabla | Alcance | Propósito |
|---|---|---|
| `medicos` | equipo (lectura abierta) | Un médico/residente = un usuario de Auth. Rol, supervisor, restricción por sanatorio, flag de admin. |
| `sanatorios` | equipo (lectura abierta, escritura solo admin) | Maestro de nombres de sanatorio + dirección. |
| `zonas` | equipo (lectura abierta, escritura solo admin) | Zona de facturación por sanatorio. |
| `contactos` | equipo (lectura abierta, escritura solo admin) | Remitente de WhatsApp → sanatorio. |
| `interconsultas` | equipo (solo rol='medico') | Cola compartida de interconsultas, alimentada por WhatsApp/capturas/carga manual. |
| `interconsultas_capturas_pendientes` | equipo | Cola de imágenes subidas, a la espera de la rutina programada. |
| `interconsultas_facturables` | privado por médico | Archivo de interconsultas cobrables (solo sanatorios con precio configurado). |
| `precios_interconsulta` | privado por médico | Valor de interconsulta por sanatorio. |
| `precios_consulta` | privado por médico | Valor de consulta de consultorio por sanatorio × obra social. |
| `consultas` | privado por médico | Ledger de consultas de consultorio (facturación). |
| `pacientes` | privado por médico (+ acceso de residente al de su supervisor) | La ficha clínica completa. |
| `internaciones` | privado por médico (+ acceso de residente) | Episodios de internación, independientes de la ficha. |
| `medico_calendar_tokens` | estrictamente privado | Refresh token de Google Calendar por médico. |
| `push_subscriptions` | equipo | Suscripciones Web Push. |
| `debug_log` | sin RLS | Tabla de diagnóstico ad-hoc, no forma parte del modelo de datos oficial. |

**Patrón de RLS reutilizado en todo el proyecto** — vale la pena entenderlo antes de leer las policies: para evitar que una policy que lee la propia fila del usuario en `medicos` (para chequear `rol`/`es_admin`) dispare una recursión infinita de RLS sobre `medicos` misma, existen dos funciones `SECURITY DEFINER` (`current_medico_rol()`, `current_medico_es_admin()`) que leen esa fila con privilegios elevados, evitando el problema. Cualquier policy nueva que necesite "¿esto lo puede hacer el caller según su fila en medicos?" debería usar (o imitar) este patrón, no reinventar una subconsulta directa contra `medicos` dentro de la misma policy de `medicos`.

**Gotcha de Postgres documentado y ya resuelto en este esquema** — si en algún momento se agrega una nueva policy de "residente restringido a ciertos sanatorios", la forma correcta de comparar contra el array `sanatorios_permitidos` es:
```sql
sanatorio = ANY(COALESCE((select sanatorios_permitidos from medicos where id = auth.uid()), ARRAY[]::text[]))
```
y NO la forma más obvia `sanatorio = ANY((select sanatorios_permitidos from medicos where id = auth.uid()))`, que Postgres interpreta ambiguamente cuando el subquery devuelve una sola fila de tipo array (tira `operator does not exist: text = text[]`). El `COALESCE(...)` fuerza a Postgres a evaluar el subquery como un único valor escalar (array) antes de aplicarle `ANY`.

```sql

-- ============================================================================
-- GESTIÓN MÉDICA — esquema consolidado de Supabase (Postgres)
-- Generado por introspección DIRECTA de la base en producción
-- (information_schema + pg_catalog + pg_policies), no por concatenación de
-- los ~19 archivos de migración incrementales del proyecto. Este archivo
-- representa el estado ACTUAL real, no el historial de cómo se llegó ahí.
-- Proyecto Supabase: cwcsounmbitxmlxedqdu (región South America / Canada Central)
-- ============================================================================

-- ---- Extensiones activas ----
create extension if not exists "uuid-ossp";
create extension if not exists pgcrypto;
create extension if not exists pg_cron;
create extension if not exists pg_net;

-- ============================================================================
-- TABLAS
-- ============================================================================

-- ---- medicos ----
-- id = auth.users.id (un médico/residente = un usuario de Supabase Auth).
create table public.medicos (
  id uuid primary key references auth.users(id),
  nombre text not null,
  especialidad text,
  color text,
  created_at timestamptz not null default now(),
  rol text not null default 'medico' check (rol in ('medico','residente')),
  supervisor_id uuid references public.medicos(id),
  sanatorios_permitidos text[],           -- null = sin restricción; array = solo esos sanatorios
  es_admin boolean not null default false -- tier separado de "rol", solo Pablo hoy
);

-- ---- sanatorios ----
-- Maestro compartido de sanatorios (nombre único). Lectura abierta a todo
-- autenticado; alta/edición/borrado restringido a es_admin.
create table public.sanatorios (
  id uuid primary key default gen_random_uuid(),
  nombre text not null unique,
  created_at timestamptz not null default now(),
  direccion text
);

-- ---- zonas ----
-- Zona de facturación por sanatorio (1 fila por sanatorio, unique).
create table public.zonas (
  id uuid primary key default gen_random_uuid(),
  sanatorio text not null unique,
  zona text not null,
  created_at timestamptz not null default now()
);

-- ---- contactos ----
-- Mapeo remitente de WhatsApp (nombre/teléfono) → sanatorio, para el parser.
create table public.contactos (
  id uuid primary key default gen_random_uuid(),
  contacto text not null,
  sanatorio text not null,
  created_at timestamptz not null default now()
);

-- ---- interconsultas ----
-- Tabla compartida entre todo el equipo (NO tiene medico_id). Alimentada por
-- el parser de WhatsApp (app + rutina programada por Telegram), por subida de
-- capturas, o por carga manual (modal).
create table public.interconsultas (
  id uuid primary key default gen_random_uuid(),
  fecha text,                              -- 'YYYY-MM-DD' (a veces + hora), texto libre
  sanatorio text,
  paciente text,
  habitacion text,
  cama text,
  diagnostico text,
  estado text not null default 'pendiente' check (estado in ('pendiente','resuelta')),
  fecha_resuelta date,
  original text,                           -- texto crudo del mensaje de origen
  created_at timestamptz not null default now(),
  zona text,
  exportado_at timestamptz,                -- dispara borrado automático a los 4 meses (pg_cron)
  piso text
);

-- ---- interconsultas_capturas_pendientes ----
-- Cola de capturas de pantalla subidas desde la app, a la espera de que la
-- rutina programada (Telegram/vision) las procese (hasta ~2hs de latencia).
create table public.interconsultas_capturas_pendientes (
  id uuid primary key default gen_random_uuid(),
  medico_id uuid not null references public.medicos(id),
  storage_path text not null,              -- bucket interconsultas-capturas
  estado text not null default 'pendiente' check (estado in ('pendiente','procesada','error')),
  error_mensaje text,
  created_at timestamptz not null default now(),
  procesada_at timestamptz
);

-- ---- interconsultas_facturables ----
-- Archivo/ledger privado por médico: se genera al marcar una interconsulta
-- "Contestada" o al usar "Programar Cx", SOLO si el sanatorio tiene un valor
-- configurado en precios_interconsulta. Se borra manualmente al facturar.
create table public.interconsultas_facturables (
  id uuid primary key default gen_random_uuid(),
  medico_id uuid not null references public.medicos(id),
  sanatorio text,
  paciente text,
  fecha date not null default current_date,
  tipo text not null check (tipo in ('contestada','programada')),
  valor numeric,
  created_at timestamptz not null default now()
);

-- ---- precios_interconsulta ----
-- Valor plano ($ por interconsulta) configurado por cada médico, por sanatorio.
create table public.precios_interconsulta (
  id uuid primary key default gen_random_uuid(),
  medico_id uuid not null references public.medicos(id),
  sanatorio text not null,
  valor numeric not null,
  created_at timestamptz not null default now(),
  unique (medico_id, sanatorio)
);

-- ---- precios_consulta ----
-- Precio por sanatorio × obra social (o 'unico' = precio plano sin importar OS).
create table public.precios_consulta (
  id uuid primary key default gen_random_uuid(),
  medico_id uuid not null references public.medicos(id),
  sanatorio text not null,
  os text not null,                        -- PAMI/OSDE/Swiss Medical/Medife/Samisalud/IOMA/Particular/'unico'
  valor numeric not null,
  created_at timestamptz not null default now(),
  unique (medico_id, sanatorio, os)
);

-- ---- consultas ----
-- Ledger de consultas de consultorio (facturación mensual), privado por médico.
-- Deliberadamente SIN paciente_id (no es un registro clínico, solo billing).
create table public.consultas (
  id uuid primary key default gen_random_uuid(),
  medico_id uuid not null references public.medicos(id),
  sanatorio text,
  fecha date not null default current_date,
  paciente text,
  os text,
  valor numeric,
  created_at timestamptz not null default now()
);

-- ---- pacientes ----
-- La "ficha" completa del paciente. Privada por médico (medico_id = dueño,
-- que para un residente es el id de su supervisor, nunca el suyo propio).
create table public.pacientes (
  id uuid primary key default gen_random_uuid(),
  medico_id uuid not null references public.medicos(id),
  nombre text not null,
  dni text,
  fecha_nacimiento date,
  telefono text,
  email text,
  os text,
  datos_clinicos text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  sanatorio text,
  edad integer,
  nro_afiliado text,
  diagnostico text,
  antecedentes jsonb not null default '{}'::jsonb,     -- checklist fijo, ver ANTECEDENTES_LIST en el frontend
  operacion text,
  fecha_qx date,
  preqx jsonb not null default '{}'::jsonb,            -- laboratorio/RCV/funcional respiratorio/imágenes/nódulo (ver frontend)
  protocolo_qx_link text,
  anatomia_patologica_link text,                       -- nombre de columna heredado; hoy es texto libre, no link
  materiales text check (materiales is null or materiales in
    ('no_requiere','pendiente_autorizacion','autorizados','en_quirofano')),
  notas text,
  copago_monto text,
  copago_estado text check (copago_estado is null or copago_estado in ('pago','pendiente','no_acepta')),
  google_calendar_event_ids jsonb not null default '{}'::jsonb,  -- {medico_id: google_event_id}
  hora_qx time,
  operado boolean not null default false,
  sexo text check (sexo is null or sexo in ('masculino','femenino')),
  consentimiento_link text,
  consentimiento_estado text check (consentimiento_estado is null or consentimiento_estado in
    ('pendiente','entregado','firmado')),
  cirugias jsonb not null default '[]'::jsonb          -- historial de cirugías previas (reoperaciones)
);

-- ---- internaciones ----
-- Una fila = un episodio de internación (no es 1:1 con paciente — puede haber
-- varios episodios a lo largo del tiempo). fecha_alta null = activa/actual.
create table public.internaciones (
  id uuid primary key default gen_random_uuid(),
  medico_id uuid not null references public.medicos(id),
  paciente_id uuid not null references public.pacientes(id),
  sanatorio text,
  sector text,                              -- "piso" / sector físico (UTI, Piso 3, etc.)
  habitacion text,
  cama text,
  fecha_ingreso date not null default current_date,
  fecha_alta date,
  evoluciones jsonb not null default '[]'::jsonb,   -- [{fecha, texto}, ...] append-only
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

-- ---- medico_calendar_tokens ----
-- Refresh token de Google Calendar por médico. Tabla separada de "medicos"
-- (que tiene SELECT abierto a todo el equipo) para que el token nunca sea
-- legible por nadie más que su dueño.
create table public.medico_calendar_tokens (
  medico_id uuid primary key references public.medicos(id),
  refresh_token text not null,
  connected_at timestamptz not null default now()
);

-- ---- push_subscriptions ----
-- Suscripciones Web Push (VAPID) para notificar nuevas interconsultas.
create table public.push_subscriptions (
  id uuid primary key default gen_random_uuid(),
  endpoint text not null unique,
  p256dh text not null,
  auth text not null,
  created_at timestamptz not null default now()
);

-- ---- debug_log ----
-- Tabla de diagnóstico ad-hoc (RLS deshabilitada). No forma parte del
-- modelo de datos "oficial" de la app — usar/ignorar según haga falta.
create table public.debug_log (
  id uuid primary key default gen_random_uuid(),
  step text,
  ok boolean,
  detail text,
  created_at timestamptz not null default now()
);
-- (RLS NO está habilitada en esta tabla — es la única excepción del esquema)

-- ============================================================================
-- FUNCIONES (SECURITY DEFINER — evitan recursión de RLS al leer la propia fila
-- del caller en "medicos")
-- ============================================================================

create or replace function public.current_medico_rol()
returns text
language sql stable security definer set search_path to 'public'
as $$
  select rol from medicos where id = auth.uid()
$$;

create or replace function public.current_medico_es_admin()
returns boolean
language sql stable security definer set search_path to 'public'
as $$
  select coalesce((select es_admin from medicos where id = auth.uid()), false)
$$;

-- Bloquea que un no-médico (residente) se auto-asigne rol/supervisor/sanatorios
-- vía un UPDATE directo a su propia fila (el self_insert_medicos de abajo ya
-- cubre el intento en el signup; este trigger cubre un intento posterior).
create or replace function public.prevent_self_role_escalation()
returns trigger
language plpgsql security definer set search_path to 'public'
as $$
begin
  if (new.rol is distinct from old.rol
      or new.supervisor_id is distinct from old.supervisor_id
      or new.sanatorios_permitidos is distinct from old.sanatorios_permitidos) then
    if coalesce((select rol from medicos where id = auth.uid()), '') <> 'medico' then
      new.rol := old.rol;
      new.supervisor_id := old.supervisor_id;
      new.sanatorios_permitidos := old.sanatorios_permitidos;
    end if;
  end if;
  return new;
end;
$$;

create trigger trg_prevent_self_role_escalation
  before update on public.medicos
  for each row execute function public.prevent_self_role_escalation();

-- Dispara un push notification (Edge Function notify-new-ic) en cada
-- interconsulta nueva, vía pg_net (HTTP saliente desde Postgres).
-- NOTA: el valor de x-internal-secret abajo fue REDACTADO para este dossier —
-- en la base real está hardcodeado en la función (ver INTERNAL_FUNCTION_SECRET
-- en .env). Si recreás esta función en otro entorno, poné tu propio secreto
-- acá y en la env var homónima de la Edge Function.
create or replace function public.notify_nueva_interconsulta()
returns trigger
language plpgsql security definer
as $$
begin
  perform net.http_post(
    url := 'https://<TU_PROYECTO>.supabase.co/functions/v1/notify-new-ic',
    headers := jsonb_build_object(
      'Content-Type', 'application/json',
      'x-internal-secret', '<INTERNAL_FUNCTION_SECRET>'
    ),
    body := jsonb_build_object('id', new.id, 'paciente', new.paciente, 'sanatorio', new.sanatorio)
  );
  return new;
end;
$$;

create trigger trg_notify_nueva_interconsulta
  after insert on public.interconsultas
  for each row execute function public.notify_nueva_interconsulta();

-- ============================================================================
-- pg_cron: borrado automático de interconsultas resueltas y exportadas
-- ============================================================================
select cron.schedule(
  'borrar_interconsultas_exportadas',
  '0 6 * * *',  -- diario 06:00 UTC
  $$ delete from interconsultas where exportado_at is not null and exportado_at < now() - interval '4 months' $$
);

-- ============================================================================
-- ROW LEVEL SECURITY — habilitada en TODAS las tablas excepto debug_log
-- ============================================================================
alter table public.medicos enable row level security;
alter table public.sanatorios enable row level security;
alter table public.zonas enable row level security;
alter table public.contactos enable row level security;
alter table public.interconsultas enable row level security;
alter table public.interconsultas_capturas_pendientes enable row level security;
alter table public.interconsultas_facturables enable row level security;
alter table public.precios_interconsulta enable row level security;
alter table public.precios_consulta enable row level security;
alter table public.consultas enable row level security;
alter table public.pacientes enable row level security;
alter table public.internaciones enable row level security;
alter table public.medico_calendar_tokens enable row level security;
alter table public.push_subscriptions enable row level security;

-- ---- medicos ----
-- Cualquier autenticado puede LEER a todos los médicos (roster de equipo,
-- selects de "quién invitó a quién", etc.) — pero solo puede insertar/editar
-- su propia fila, con guardas anti-escalación de privilegios.
create policy "authenticated_read_medicos"
  on public.medicos for select to authenticated
  using (true);

create policy "self_insert_medicos"
  on public.medicos for insert to authenticated
  with check (
    id = auth.uid()
    and rol = coalesce(nullif(auth.jwt()->'user_metadata'->>'rol', ''), 'medico')
    and supervisor_id is not distinct from nullif(auth.jwt()->'user_metadata'->>'supervisor_id', '')::uuid
    and sanatorios_permitidos is not distinct from (
      case when auth.jwt()->'user_metadata'->'sanatorios_permitidos' is null then null
      else array(select jsonb_array_elements_text(auth.jwt()->'user_metadata'->'sanatorios_permitidos')) end
    )
  );

create policy "self_update_medicos"
  on public.medicos for update to authenticated
  using (id = auth.uid())
  with check (id = auth.uid());

-- Un médico (rol='medico') puede editar la fila de CUALQUIER integrante del
-- equipo (para asignar rol/supervisor/sanatorios/es_admin desde el panel).
create policy "medico_asigna_roles_equipo"
  on public.medicos for update to authenticated
  using (current_medico_rol() = 'medico')
  with check (current_medico_rol() = 'medico');

-- ---- sanatorios / zonas / contactos ----
-- Lectura abierta a todo autenticado (alimentan dropdowns/colores/matching
-- en toda la app). Escritura restringida a es_admin únicamente.
create policy "authenticated_select_sanatorios" on public.sanatorios for select to authenticated using (true);
create policy "admin_modifica_sanatorios" on public.sanatorios for all to authenticated
  using (current_medico_es_admin()) with check (current_medico_es_admin());

create policy "authenticated_select_zonas" on public.zonas for select to authenticated using (true);
create policy "authenticated_full_access_zonas" on public.zonas for all to authenticated
  using (current_medico_es_admin()) with check (current_medico_es_admin());

create policy "authenticated_select_contactos" on public.contactos for select to authenticated using (true);
create policy "authenticated_full_access_contactos" on public.contactos for all to authenticated
  using (current_medico_es_admin()) with check (current_medico_es_admin());

-- ---- interconsultas ----
-- Compartida entre el equipo, pero SOLO médicos (rol='medico') tienen acceso
-- — un residente no ve ni toca Interconsultas en absoluto.
create policy "authenticated_full_access_interconsultas"
  on public.interconsultas for all to authenticated
  using (current_medico_rol() = 'medico')
  with check (current_medico_rol() = 'medico');

-- ---- interconsultas_capturas_pendientes ----
-- Compartida y abierta a cualquier autenticado (cola de trabajo del equipo).
create policy "authenticated_full_access_capturas_pendientes"
  on public.interconsultas_capturas_pendientes for all to authenticated
  using (true) with check (true);

-- ---- interconsultas_facturables / precios_interconsulta / precios_consulta / consultas ----
-- Privadas por médico (billing personal, no de equipo).
create policy "medico_own_interconsultas_facturables" on public.interconsultas_facturables for all to authenticated
  using (medico_id = auth.uid()) with check (medico_id = auth.uid());
create policy "medico_own_precios_interconsulta" on public.precios_interconsulta for all to authenticated
  using (medico_id = auth.uid()) with check (medico_id = auth.uid());
create policy "medico_own_precios_consulta" on public.precios_consulta for all to authenticated
  using (medico_id = auth.uid()) with check (medico_id = auth.uid());
create policy "medico_own_consultas" on public.consultas for all to authenticated
  using (medico_id = auth.uid()) with check (medico_id = auth.uid());

-- ---- pacientes ----
-- Dueño (médico) tiene acceso total. Un residente ve/edita (no borra) los
-- pacientes de SU supervisor, opcionalmente restringido a ciertos sanatorios
-- (sanatorios_permitidos null = sin restricción).
create policy "medico_own_pacientes" on public.pacientes for all to authenticated
  using (medico_id = auth.uid()) with check (medico_id = auth.uid());

create policy "residente_select_pacientes_supervisor" on public.pacientes for select to authenticated
  using (
    medico_id = (select supervisor_id from medicos where id = auth.uid())
    and (
      (select sanatorios_permitidos from medicos where id = auth.uid()) is null
      or pacientes.sanatorio = any(coalesce((select sanatorios_permitidos from medicos where id = auth.uid()), array[]::text[]))
    )
  );

create policy "residente_insert_pacientes_supervisor" on public.pacientes for insert to authenticated
  with check (
    medico_id = (select supervisor_id from medicos where id = auth.uid())
    and (
      (select sanatorios_permitidos from medicos where id = auth.uid()) is null
      or pacientes.sanatorio = any(coalesce((select sanatorios_permitidos from medicos where id = auth.uid()), array[]::text[]))
    )
  );

create policy "residente_update_pacientes_supervisor" on public.pacientes for update to authenticated
  using (
    medico_id = (select supervisor_id from medicos where id = auth.uid())
    and (
      (select sanatorios_permitidos from medicos where id = auth.uid()) is null
      or pacientes.sanatorio = any(coalesce((select sanatorios_permitidos from medicos where id = auth.uid()), array[]::text[]))
    )
  )
  with check (
    medico_id = (select supervisor_id from medicos where id = auth.uid())
    and (
      (select sanatorios_permitidos from medicos where id = auth.uid()) is null
      or pacientes.sanatorio = any(coalesce((select sanatorios_permitidos from medicos where id = auth.uid()), array[]::text[]))
    )
  );
-- (deliberadamente NO hay policy de DELETE para residente sobre pacientes)

-- ---- internaciones ---- (mismo criterio supervisor+sanatorio que pacientes, sin DELETE)
create policy "medico_own_internaciones" on public.internaciones for all to authenticated
  using (medico_id = auth.uid()) with check (medico_id = auth.uid());

create policy "residente_select_internaciones_supervisor" on public.internaciones for select to authenticated
  using (
    medico_id = (select supervisor_id from medicos where id = auth.uid())
    and (
      (select sanatorios_permitidos from medicos where id = auth.uid()) is null
      or internaciones.sanatorio = any(coalesce((select sanatorios_permitidos from medicos where id = auth.uid()), array[]::text[]))
    )
  );

create policy "residente_insert_internaciones_supervisor" on public.internaciones for insert to authenticated
  with check (
    medico_id = (select supervisor_id from medicos where id = auth.uid())
    and (
      (select sanatorios_permitidos from medicos where id = auth.uid()) is null
      or internaciones.sanatorio = any(coalesce((select sanatorios_permitidos from medicos where id = auth.uid()), array[]::text[]))
    )
  );

create policy "residente_update_internaciones_supervisor" on public.internaciones for update to authenticated
  using (
    medico_id = (select supervisor_id from medicos where id = auth.uid())
    and (
      (select sanatorios_permitidos from medicos where id = auth.uid()) is null
      or internaciones.sanatorio = any(coalesce((select sanatorios_permitidos from medicos where id = auth.uid()), array[]::text[]))
    )
  )
  with check (
    medico_id = (select supervisor_id from medicos where id = auth.uid())
    and (
      (select sanatorios_permitidos from medicos where id = auth.uid()) is null
      or internaciones.sanatorio = any(coalesce((select sanatorios_permitidos from medicos where id = auth.uid()), array[]::text[]))
    )
  );

-- ---- medico_calendar_tokens ---- (estrictamente privado, ni siquiera otro médico lo ve)
create policy "self_all_medico_calendar_tokens" on public.medico_calendar_tokens for all to authenticated
  using (medico_id = auth.uid()) with check (medico_id = auth.uid());

-- ---- push_subscriptions ---- (sin dato sensible, abierta a cualquier autenticado)
create policy "authenticated_full_access_push_subscriptions" on public.push_subscriptions for all to authenticated
  using (true) with check (true);

-- ============================================================================
-- STORAGE — buckets y policies
-- ============================================================================
-- buckets reales en el proyecto:
--   'interconsultas'          public=true   (propósito histórico/no confirmado — auditar antes de reusar)
--   'estudios-imagenes'       public=false  (TC/PET por paciente, privado por médico)
--   'interconsultas-capturas' public=false  (capturas de WhatsApp subidas desde la app)

-- estudios-imagenes: path = {medico_id}/{paciente_id}/{tc|pet}/{timestamp}_{filename}
create policy "medico_own_images_select" on storage.objects for select to authenticated
  using (bucket_id = 'estudios-imagenes' and (storage.foldername(name))[1] = auth.uid()::text);
create policy "medico_own_images_insert" on storage.objects for insert to authenticated
  with check (bucket_id = 'estudios-imagenes' and (storage.foldername(name))[1] = auth.uid()::text);
create policy "medico_own_images_delete" on storage.objects for delete to authenticated
  using (bucket_id = 'estudios-imagenes' and (storage.foldername(name))[1] = auth.uid()::text);

-- un residente puede ver/subir imágenes bajo la carpeta de SU supervisor
create policy "residente_select_imagenes_supervisor" on storage.objects for select to authenticated
  using (bucket_id = 'estudios-imagenes'
    and (storage.foldername(name))[1] = (select supervisor_id::text from medicos where id = auth.uid()));
create policy "residente_insert_imagenes_supervisor" on storage.objects for insert to authenticated
  with check (bucket_id = 'estudios-imagenes'
    and (storage.foldername(name))[1] = (select supervisor_id::text from medicos where id = auth.uid()));

-- interconsultas-capturas: abierto a cualquier autenticado (cola compartida de equipo)
create policy "authenticated_select_capturas" on storage.objects for select to authenticated
  using (bucket_id = 'interconsultas-capturas');
create policy "authenticated_insert_capturas" on storage.objects for insert to authenticated
  with check (bucket_id = 'interconsultas-capturas');
create policy "authenticated_delete_capturas" on storage.objects for delete to authenticated
  using (bucket_id = 'interconsultas-capturas');

```

---

## 3. Estructura del proyecto

```
C:\Users\pablo\cloude\                          (directorio de trabajo — NO es un repo git)
│
├── index.html                                  ← LA APP. Único archivo frontend, ~3700 líneas.
│                                                  HTML + <style> + <script> en un solo documento.
│                                                  Ver Sección 4 para el contenido completo.
├── manifest.json                                Manifest de PWA (nombre, íconos, colores, display:standalone)
├── sw.js                                        Service worker: cachea el shell básico, maneja push
│                                                  notifications (evento 'push') y clicks en notificaciones.
├── icon-192.png / icon-512.png                  Íconos de la PWA (logo real de Pablo, no genérico).
├── logo/
│   └── LOGO SOLO PULMON.png                     Logo original de origen, usado para regenerar los íconos.
├── videos-cirugia/                              Carpeta de videos educativos (uso separado, no integrada a la app).
│
├── .env                                          Todos los secretos del proyecto (gitignored, NUNCA se
│                                                  commitea — no hay git de todos modos). Ver más abajo.
├── .gitignore
│
├── supabase/
│   └── functions/                                Las 5 Edge Functions (Deno). Cada una en su propia carpeta
│       │                                          con un único index.ts — así es como Supabase espera el
│       │                                          código para el deploy (`supabase functions deploy` o,
│       │                                          como en este proyecto, vía la Management API directamente).
│       ├── invite-medico/index.ts                Invita a un nuevo médico/residente (Auth admin API + RLS
│       │                                          anti-tampering vía JWT metadata).
│       ├── delete-medico/index.ts                Borra un integrante del equipo (fila + usuario de Auth).
│       ├── sync-calendar-event/index.ts          Sincroniza fecha_qx/hora_qx de un paciente con el Google
│       │                                          Calendar de todos los médicos conectados.
│       ├── google-oauth-callback/index.ts        Recibe el redirect de Google OAuth, guarda el refresh_token.
│       └── notify-new-ic/index.ts                Envía push notifications (Web Push/VAPID) en cada
│                                                  interconsulta nueva; disparada por un trigger de Postgres.
│
└── supabase_schema*.sql                          ~19 archivos de migración incremental, uno por feature/ronda
                                                   (ej: supabase_schema_residentes_v3.sql, _admin_sanatorios.sql,
                                                   _interconsultas_piso.sql). Son el HISTORIAL de cómo se llegó
                                                   al esquema actual, aplicados a mano vía la Management API de
                                                   Supabase en el orden en que se escribieron — no están pensados
                                                   para correrse todos de nuevo en otro proyecto (algunos hacen
                                                   `alter policy` sobre policies creadas en un archivo anterior).
                                                   Para recrear el esquema en un proyecto nuevo, usar el SQL
                                                   consolidado de la Sección 2, no estos archivos.
```

**No hay separación en "componentes" porque no hay framework** — dentro de `index.html`, la organización real es:

| Bloque (dentro de `<script>`) | Qué hace |
|---|---|
| Inicialización | `SUPABASE_URL`/`SUPABASE_ANON_KEY`, `createClient()`, estado global en memoria (`pacientes`, `internaciones`, `items`, `medicos`, `sanatoriosRef`, `zonas`, `contacts`, `currentUser`, `currentMedico`, `currentPacienteId`, etc.) |
| Auth / onboarding | Login, `onAuthStateChange` (maneja el evento `INITIAL_SESSION` para evitar una race condition con links de invitación), pantalla "Completá tu perfil" para altas nuevas |
| Interconsultas | Parser de texto de WhatsApp (regex), parser de mensajes sueltos, cards agrupadas por sanatorio, modal de carga manual, subida de capturas, exportación CSV con borrado automático a 4 meses |
| Pacientes / Ficha | Lista + vista de detalle ("ficha") con ~30 campos, antecedentes (checklist jsonb), preQx (laboratorio/RCV/funcional respiratorio/imágenes/nódulo pulmonar), calculadoras de riesgo (Brock/Herder), subida de imágenes a Storage, WhatsApp FAB, historial de cirugías |
| Agenda | Calendario (día/semana/mes) derivado 100% de `fecha_qx` de los pacientes — no es una tabla propia |
| Internados | Episodios de internación agrupados por sanatorio, evoluciones (jsonb append-only), alta |
| Consultorio | Ledger de facturación de consultas + interconsultas facturables, precios por sanatorio/OS |
| Resumen | Dashboard que agrega datos ya cargados de los tres módulos anteriores (sin fetch propio) |
| Médicos / equipo | Invitar, borrar, asignar rol/supervisor/sanatorios permitidos, panel admin de sanatorios (dirección/zona/contactos) |
| Integraciones | Google Calendar (conectar/sincronizar), Web Push (activar notificaciones), WhatsApp (`wa.me`/intent Android) |
| Helpers compartidos | `escapeHtml`, `normalize` (para comparar nombres tolerando acentos/mayúsculas), `flashIn`/`flash` (mensajes de UI), `sanatorioColor` (color determinístico por hash del nombre), `efectivoMedicoId` (dueño real de un registro nuevo — el propio id o el del supervisor si sos residente) |

**Variables de entorno usadas** (todas en `.env`, ninguna commiteada a ningún repo porque no hay repo):

| Variable | Dónde se usa | ¿Secreta? |
|---|---|---|
| `SUPABASE_URL` | Frontend (hardcodeada en `index.html`) + Edge Functions (`SB_URL`) | No — es pública por diseño |
| `SUPABASE_ANON_KEY` (publishable key) | Frontend (hardcodeada en `index.html`) | No — pública, protegida por RLS |
| `SUPABASE_SECRET_KEY` | Edge Functions (`SB_SECRET_KEY`), scripts de administración | **Sí** — bypassa RLS por completo |
| `SUPABASE_MGMT_TOKEN` | Scripts de administración (deploy de Edge Functions, migraciones SQL, config de Auth) — Personal Access Token a nivel de cuenta Supabase, no del proyecto | **Sí** |
| `SUPABASE_PROJECT_REF` | Scripts de administración | No, pero es un identificador — no compartir sin necesidad |
| `VERCEL_TOKEN` | Scripts de deploy | **Sí** |
| `GOOGLE_CLIENT_ID` | Frontend (hardcodeado) + Edge Functions | No — los client ID de OAuth no son secretos |
| `GOOGLE_CLIENT_SECRET` | Edge Functions únicamente | **Sí** |
| `TELEGRAM_BOT_TOKEN` / `TELEGRAM_CHAT_ID` | Rutina programada en la nube (fuera de este repo) | **Sí** el token |
| `VAPID_PUBLIC_KEY` / `VAPID_PRIVATE_KEY` | Frontend (pública) / Edge Function `notify-new-ic` (privada) | Solo la privada |
| `INTERNAL_FUNCTION_SECRET` | Función SQL `notify_nueva_interconsulta()` + Edge Function `notify-new-ic` | **Sí** |


---

## 4. Código fuente principal

Como la app es un único archivo sin componentes separables, esta sección contiene **el código fuente completo y real** de `index.html` (frontend íntegro: dashboard/Resumen, ficha de pacientes, agenda, internados, interconsultas, consultorio, y los "servicios" de conexión a Supabase — que en esta arquitectura son simplemente las llamadas directas `sb.from(...)`/`sb.functions.invoke(...)` esparcidas junto a cada feature, no un archivo de servicios separado) y de las 5 Edge Functions completas.

### 4.1 `index.html` — frontend completo


```html
<!DOCTYPE html>
<html lang="es">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>Gestión Médica</title>
<link rel="manifest" href="/manifest.json">
<link rel="icon" href="/icon-192.png">
<link rel="apple-touch-icon" href="/icon-192.png">
<meta name="theme-color" content="#2563eb">
<meta name="mobile-web-app-capable" content="yes">
<meta name="apple-mobile-web-app-capable" content="yes">
<meta name="apple-mobile-web-app-status-bar-style" content="black-translucent">
<meta name="apple-mobile-web-app-title" content="Gestión Médica">
<script>
  (function(){
    try {
      var t = localStorage.getItem('tema');
      if(t === 'light' || t === 'dark') document.documentElement.setAttribute('data-theme', t);
    } catch(e){}
  })();
</script>
<script src="https://cdn.jsdelivr.net/npm/@supabase/supabase-js@2"></script>
<style>
  :root{
    --bg:#f4f6f8; --panel:#ffffff; --border:#dde3ea; --text:#1f2937;
    --muted:#6b7280; --accent:#2563eb; --accent-dark:#1d4ed8;
    --pending:#f59e0b; --done:#16a34a; --danger:#dc2626; --danger-dark:#b91c1c;
    --purple:#7c3aed; --purple-bg:rgba(124,58,237,0.15);
  }
  @media (prefers-color-scheme: dark){
    :root:not([data-theme="light"]){ --bg:#12161c; --panel:#1a2029; --border:#2a323e; --text:#e5e9f0; --muted:#8b94a3; }
  }
  :root[data-theme="dark"]{ --bg:#12161c; --panel:#1a2029; --border:#2a323e; --text:#e5e9f0; --muted:#8b94a3; }
  *{box-sizing:border-box}
  body{
    margin:0; font-family:-apple-system,Segoe UI,Roboto,Helvetica,Arial,sans-serif;
    background:var(--bg); color:var(--text); padding:24px;
  }
  h1{font-size:20px; margin:0 0 4px 0}
  .sub{color:var(--muted); font-size:13px; margin-bottom:20px}
  .panel{
    background:var(--panel); border:1px solid var(--border); border-radius:10px;
    padding:16px; margin-bottom:16px;
  }
  .panel h2{font-size:16px; margin:0 0 12px 0; font-weight:700}
  .panel h3.subhead{font-size:13px; font-weight:700; color:var(--text); margin:20px 0 10px 0; padding-bottom:6px; border-bottom:1px solid var(--border)}
  textarea{
    width:100%; min-height:110px; resize:vertical; font-family:inherit; font-size:13px;
    padding:10px; border:1px solid var(--border); border-radius:8px;
    background:var(--bg); color:var(--text);
  }
  .row{display:flex; gap:10px; align-items:center; margin-top:10px; flex-wrap:wrap}
  button{
    cursor:pointer; border:none; border-radius:8px; padding:9px 14px;
    font-size:13px; font-weight:600; background:var(--accent); color:#fff;
  }
  button:hover{background:var(--accent-dark)}
  button:disabled{opacity:.6; cursor:default}
  button.secondary{background:transparent; color:var(--text); border:1px solid var(--border)}
  button.secondary:hover{background:var(--border)}
  button.danger{background:var(--danger)}
  button.danger:hover{background:var(--danger-dark)}
  button.success{background:var(--done)}
  button.success:hover{background:#15803d}
  .msg{font-size:12px; color:var(--muted); margin-top:8px; min-height:16px}
  .msg.error{color:var(--danger)}
  .toolbar{display:flex; gap:10px; flex-wrap:wrap; align-items:center; margin-bottom:14px}
  input[type=text], input[type=email], input[type=password], input[type=date], input[type=time], select, textarea.small{
    padding:8px 10px; border:1px solid var(--border); border-radius:8px;
    background:var(--panel); color:var(--text); font-size:13px;
  }
  input[type=text]{min-width:220px}
  table{width:100%; border-collapse:collapse; font-size:13px}
  th, td{text-align:left; padding:8px 10px; border-bottom:1px solid var(--border); vertical-align:top}
  th{cursor:pointer; user-select:none; color:var(--muted); font-weight:600; font-size:11px; text-transform:uppercase; letter-spacing:.03em; white-space:nowrap}
  th:hover{color:var(--text)}
  tr:hover td{background:rgba(37,99,235,0.04)}
  td[contenteditable=true]{outline:none; min-width:60px}
  td[contenteditable=true]:focus{background:rgba(37,99,235,0.08); border-radius:4px}
  .badge{
    display:inline-block; padding:3px 9px; border-radius:999px; font-size:11px; font-weight:600;
    cursor:pointer; white-space:nowrap;
  }
  .badge.pendiente{background:rgba(245,158,11,0.15); color:var(--pending)}
  .badge.resuelta{background:rgba(22,163,74,0.15); color:var(--done)}
  .badge.consultorio{background:rgba(37,99,235,0.15); color:var(--accent)}
  .badge.quirurgica{background:var(--purple-bg); color:var(--purple)}
  select.estadoSelect{font-size:11px; font-weight:600; border-radius:999px; padding:3px 8px}
  .orig{color:var(--muted); font-size:11px; max-width:260px; overflow:hidden; text-overflow:ellipsis; white-space:nowrap; cursor:pointer}
  .orig:hover{white-space:normal; overflow:visible}
  .del{color:var(--danger); cursor:pointer; font-size:16px; line-height:1}
  .empty{color:var(--muted); text-align:center; padding:30px; font-size:13px}
  .count{color:var(--muted); font-size:12px; margin-left:auto}
  details summary{cursor:pointer; font-size:12px; color:var(--muted)}
  .contactList{list-style:none; margin:10px 0 0 0; padding:0; display:flex; flex-direction:column; gap:6px; max-height:160px; overflow-y:auto}
  .contactList li{
    display:flex; align-items:center; gap:8px; font-size:13px;
    background:var(--bg); border:1px solid var(--border); border-radius:8px; padding:6px 10px;
  }
  .contactList li .arrow{color:var(--muted)}
  .contactList li .sanat{font-weight:600}
  .contactList li .del{margin-left:auto}
  .contactForm{display:flex; gap:8px; flex-wrap:wrap; align-items:center}
  .contactForm input, .contactForm select{flex:1; min-width:140px}
  .sanDropdown{position:relative; display:inline-block}
  .sanDropdownBtn{font-size:12px; padding:6px 10px; white-space:nowrap}
  .sanDropdownPanel{
    display:none; position:absolute; z-index:30; top:calc(100% + 4px); left:0;
    background:var(--panel); border:1px solid var(--border); border-radius:8px; padding:8px;
    min-width:200px; max-height:240px; overflow-y:auto; flex-direction:column; gap:2px;
    box-shadow:0 6px 20px rgba(0,0,0,.25);
  }
  .sanDropdownPanel.open{display:flex}
  .sanDropdownPanel label{display:flex; align-items:center; gap:8px; font-size:13px; padding:4px 6px; border-radius:6px; cursor:pointer}
  .sanDropdownPanel label:hover{background:var(--bg)}
  .sanDropdownPanel label.todosOpt{border-bottom:1px solid var(--border); margin-bottom:2px; padding-bottom:6px; font-weight:600}
  .loginWrap{
    min-height:80vh; display:flex; align-items:center; justify-content:center;
  }
  .loginBox{
    background:var(--panel); border:1px solid var(--border); border-radius:12px;
    padding:28px; width:100%; max-width:340px;
  }
  .loginLabel{display:block; font-size:12px; color:var(--muted); margin:10px 0 4px}
  .loginBox input{width:100%}
  .topbar{display:flex; align-items:flex-start; justify-content:space-between; gap:10px; flex-wrap:wrap}
  .navtabs{display:flex; gap:6px; margin:16px 0; border-bottom:1px solid var(--border); flex-wrap:wrap}
  .navtab{
    background:transparent; color:var(--muted); border:none; border-bottom:2px solid transparent;
    border-radius:0; padding:10px 4px; margin-right:18px; font-size:13px; font-weight:600;
  }
  .navtab:hover{background:transparent; color:var(--text)}
  .navtab.active{color:var(--accent); border-bottom-color:var(--accent)}
  .view{display:none}
  .view.active{display:block}
  .userchip{font-size:12px; color:var(--muted)}
  .userchip b{color:var(--text)}
  .fichaGrid{display:grid; grid-template-columns:repeat(auto-fill, minmax(200px,1fr)); gap:12px}
  .fichaGrid label, #viewPacientes textarea{display:flex; flex-direction:column; gap:5px; font-size:12px; color:var(--muted)}
  .fichaGrid input, #viewPacientes textarea{font-size:13px; color:var(--text)}
  #viewPacientes textarea{width:100%; min-height:70px; padding:8px 10px; border:1px solid var(--border); border-radius:8px; background:var(--bg); color:var(--text); font-family:inherit; resize:vertical}
  .antGrid{display:grid; grid-template-columns:repeat(auto-fill, minmax(190px,1fr)); gap:8px}
  .antGrid label{display:flex; align-items:center; gap:7px; font-size:13px; font-weight:normal; cursor:pointer}
  .imgSubcard{border:1px solid var(--border); border-radius:8px; padding:14px; margin-top:14px}
  .imgSubcard h3{font-size:13px; margin:0 0 10px 0}
  .fotoGrid{display:flex; flex-wrap:wrap; gap:8px; margin-top:10px}
  .fotoThumb{position:relative; width:84px; height:84px; border-radius:6px; overflow:hidden; border:1px solid var(--border); background:var(--bg)}
  .fotoThumb img{width:100%; height:100%; object-fit:cover; display:block}
  .fotoThumb .del{position:absolute; top:2px; right:2px; background:rgba(0,0,0,0.6); color:#fff; border-radius:50%; width:18px; height:18px; display:flex; align-items:center; justify-content:center; font-size:12px; line-height:1}
  .pacRow{cursor:pointer}
  select.matSelect{
    font-weight:800; text-transform:uppercase; letter-spacing:.03em; font-size:12px;
    border-radius:8px; padding:8px 10px; border:2px solid transparent;
  }
  select.matSelect option{text-transform:none; font-weight:normal}
  select.matSelect[value=""], select.matSelect:not([data-set]){background:var(--panel); color:var(--muted); border-color:var(--border)}
  select.matSelect.mat-no_requiere{background:var(--purple-bg); color:var(--purple); border-color:var(--purple)}
  select.matSelect.mat-pendiente_autorizacion{background:rgba(220,38,38,0.15); color:var(--danger); border-color:var(--danger)}
  select.matSelect.mat-autorizados{background:rgba(37,99,235,0.15); color:var(--accent); border-color:var(--accent)}
  select.matSelect.mat-en_quirofano{background:rgba(22,163,74,0.15); color:var(--done); border-color:var(--done)}
  .fieldFull{display:flex; flex-direction:column; gap:5px; font-size:12px; color:var(--muted); margin-top:14px}
  .fieldFull input, .fieldFull textarea, .fieldFull select{font-size:13px; color:var(--text)}
  .sanatorioDot{display:inline-block; width:11px; height:11px; border-radius:50%; margin-right:6px; flex-shrink:0; box-shadow:0 0 0 1px rgba(255,255,255,0.15)}
  .sanatorioChip{display:inline-flex; align-items:center}
  tr.sanatorioRow{border-left:4px solid transparent}

  .calNav{display:flex; align-items:center; gap:6px}
  .calLabel{font-weight:700; font-size:15px; margin-left:8px; text-transform:capitalize}
  .calViewSwitch{display:flex; gap:4px}
  .calViewBtn.active{background:var(--accent); color:#fff; border-color:var(--accent)}
  .calMonthGrid{display:grid; grid-template-columns:repeat(7,1fr); gap:1px; background:var(--border)}
  .calMonthHead{background:transparent}
  .calDowLabel{background:var(--bg); padding:8px; font-size:11px; font-weight:700; text-transform:uppercase; color:var(--muted); text-align:center}
  .calDayCell{background:var(--panel); min-height:96px; padding:6px; font-size:11px}
  .calDayCell.otherMonth{opacity:.4}
  .calDayCell.today .calDayNum{background:var(--accent); color:#fff; border-radius:50%}
  .calDayNum{display:inline-flex; align-items:center; justify-content:center; width:20px; height:20px; font-weight:700; margin-bottom:4px}
  .calEventChip{display:block; font-size:11px; padding:2px 6px; border-radius:4px; margin-top:2px; white-space:nowrap; overflow:hidden; text-overflow:ellipsis; cursor:pointer; color:#fff; font-weight:600}
  .calMoreLabel{font-size:10px; color:var(--muted); margin-top:2px; cursor:default}
  .calWeekGrid{display:grid; grid-template-columns:repeat(7,1fr); gap:10px; padding:16px}
  .calWeekDay{background:var(--bg); border:1px solid var(--border); border-radius:8px; padding:10px; min-height:160px}
  .calWeekDay.today{border-color:var(--accent)}
  .calWeekDayHead{font-size:12px; font-weight:700; margin-bottom:8px; text-transform:capitalize}
  .calEmptyDay{font-size:11px; color:var(--muted)}
  .calWeekEvent{background:var(--panel); border-radius:6px; padding:6px 8px; margin-bottom:6px; cursor:pointer}
  .calWeekEventName{font-size:12px; font-weight:700}
  .calWeekEventMeta{font-size:11px; color:var(--muted); margin-top:2px}
  .calDayList{display:flex; flex-direction:column; gap:10px; padding:16px}
  .calDayItem{background:var(--bg); border:1px solid var(--border); border-radius:8px; padding:12px 14px; cursor:pointer}
  .calDayItemName{font-weight:700; font-size:14px}
  .calDayItemMeta{font-size:12px; color:var(--muted); margin-top:4px}
  .badge.mat-no_requiere{background:var(--purple-bg); color:var(--purple); text-transform:uppercase; font-weight:800; letter-spacing:.03em}
  .badge.mat-pendiente_autorizacion{background:rgba(220,38,38,0.15); color:var(--danger); text-transform:uppercase; font-weight:800; letter-spacing:.03em}
  .badge.mat-autorizados{background:rgba(37,99,235,0.15); color:var(--accent); text-transform:uppercase; font-weight:800; letter-spacing:.03em}
  .badge.mat-en_quirofano{background:rgba(22,163,74,0.15); color:var(--done); text-transform:uppercase; font-weight:800; letter-spacing:.03em}
  .badge.cond-pendiente{background:rgba(107,114,128,0.15); color:var(--muted)}
  .badge.cond-programar{background:rgba(245,158,11,0.15); color:var(--pending)}
  .badge.cond-programado{background:rgba(37,99,235,0.15); color:var(--accent)}
  .badge.cond-operado{background:rgba(22,163,74,0.15); color:var(--done)}
  .fab{
    position:fixed; bottom:28px; right:28px; width:56px; height:56px; border-radius:50%;
    font-size:28px; line-height:1; display:flex; align-items:center; justify-content:center;
    box-shadow:0 4px 14px rgba(0,0,0,0.3); z-index:50; padding:0;
  }
  a.fab.whatsappFab{background:#25D366; color:#fff; text-decoration:none}
  a.fab.whatsappFab:hover{background:#1fb457}
  .internadosGroup{margin-bottom:24px}
  .internadosGroupHead{
    display:flex; align-items:center; gap:8px; padding:9px 14px; background:var(--panel);
    border:1px solid var(--border); border-radius:8px; margin-bottom:12px;
  }
  .internadosGroupTitle{font-weight:700; font-size:15px}
  .internadosGroupCount{margin-left:auto; font-size:12px; color:var(--muted); background:var(--bg); padding:2px 9px; border-radius:999px; border:1px solid var(--border)}
  .internadosCards{display:grid; grid-template-columns:repeat(auto-fill, minmax(240px,1fr)); gap:14px; margin-bottom:14px}
  .resumenSubhead{font-size:11px; font-weight:700; color:var(--muted); text-transform:uppercase; letter-spacing:.04em; margin:4px 0 8px 2px}
  .pretestResult{margin-top:16px; padding:14px; background:var(--bg); border:1px solid var(--border); border-radius:8px}
  .pretestModelo{font-size:11px; color:var(--muted); text-transform:uppercase; letter-spacing:.03em; font-weight:700}
  .pretestNumero{font-size:34px; font-weight:800; margin-top:4px; line-height:1}
  .pretestBar{height:10px; border-radius:999px; background:var(--border); margin-top:12px; overflow:hidden}
  .pretestBarFill{height:100%; border-radius:999px; transition:width .3s; width:0}
  .pretestCategoria{font-size:12px; font-weight:700; margin-top:8px}
  .internadoCard{
    background:var(--panel); border:1px solid var(--border); border-radius:10px; padding:14px;
    cursor:pointer; transition:box-shadow .15s;
  }
  .internadoCard:hover{box-shadow:0 2px 10px rgba(0,0,0,0.12)}
  .internadoCard .habCama{font-size:11px; color:var(--muted); text-transform:uppercase; letter-spacing:.03em}
  .internadoCard .nombre{font-weight:700; font-size:14px; margin-top:2px}
  .internadoCard .meta{font-size:12px; color:var(--muted); margin-top:6px}
  .internadoCard .dias{font-size:11px; color:var(--accent); font-weight:600; margin-top:8px}
  .modalOverlay{
    position:fixed; inset:0; background:rgba(0,0,0,0.5); z-index:100;
    display:flex; align-items:center; justify-content:center; padding:20px;
  }
  .modalCard{
    background:var(--panel); border-radius:12px; padding:20px; width:100%; max-width:480px;
    max-height:85vh; overflow-y:auto;
  }
  .evolucionList{margin-top:12px; display:flex; flex-direction:column; gap:10px; max-height:220px; overflow-y:auto}
  .evolucionItem{background:var(--bg); border:1px solid var(--border); border-radius:8px; padding:8px 10px}
  .evolucionItem .fecha{font-size:11px; color:var(--muted); font-weight:600}
  .evolucionItem .texto{font-size:13px; margin-top:3px; white-space:pre-wrap}
</style>
</head>
<body>

<div id="loginScreen" class="loginWrap">
  <form id="loginForm" class="loginBox">
    <h1>Gestión Médica</h1>
    <div class="sub">Ingresá con tu cuenta para acceder.</div>
    <label class="loginLabel">Email</label>
    <input type="email" id="loginEmail" required autocomplete="username">
    <label class="loginLabel">Contraseña</label>
    <input type="password" id="loginPassword" required autocomplete="current-password">
    <button type="submit" id="btnLogin" style="width:100%; margin-top:16px">Ingresar</button>
    <div class="msg" id="loginMsg"></div>
  </form>
</div>

<div id="setupScreen" class="loginWrap" style="display:none">
  <form id="setupForm" class="loginBox" style="max-width:380px">
    <h1>Completá tu perfil</h1>
    <div class="sub">Para empezar a usar la app necesitamos algunos datos.</div>
    <label class="loginLabel">Nombre y apellido</label>
    <input type="text" id="setupNombre" required style="width:100%">
    <label class="loginLabel">Especialidad</label>
    <input type="text" id="setupEspecialidad" placeholder="ej: Cirugía torácica" style="width:100%">
    <label class="loginLabel">Contraseña nueva (dejar vacío para no cambiarla)</label>
    <input type="password" id="setupPassword" minlength="6" placeholder="mínimo 6 caracteres" style="width:100%">
    <button type="submit" id="btnSetup" style="width:100%; margin-top:16px">Guardar y continuar</button>
    <div class="msg" id="setupMsg"></div>
  </form>
</div>

<div id="appScreen" style="display:none">
  <div class="topbar">
    <div>
      <h1>Gestión Médica</h1>
      <div class="sub" id="userchip"></div>
    </div>
    <div class="row" style="margin-top:0">
      <button class="secondary" id="btnTheme">🌙 Modo oscuro</button>
      <button class="secondary" id="btnGoogleCal">📅 Conectar Google Calendar</button>
      <button class="secondary" id="btnNotif">🔔 Activar notificaciones</button>
      <button class="secondary" id="btnLogout">Cerrar sesión</button>
    </div>
  </div>

  <div class="navtabs">
    <button class="navtab active" data-view="viewResumen">Resumen</button>
    <button class="navtab" data-view="viewInterconsultas">Interconsultas</button>
    <button class="navtab" data-view="viewPacientes">Pacientes</button>
    <button class="navtab" data-view="viewAgenda">Agenda</button>
    <button class="navtab" data-view="viewInternados">Internados</button>
    <button class="navtab" data-view="viewConsultorio">Consultorio</button>
  </div>

  <details class="panel" id="panelMedicos">
    <summary style="font-size:14px; font-weight:600">👥 Médicos del equipo</summary>
    <div style="margin-top:16px">
      <ul class="contactList" id="medicosList"></ul>
      <div class="contactForm" style="margin-top:12px">
        <input type="email" id="inviteEmail" placeholder="Email del médico a invitar">
        <input type="text" id="inviteNombre" placeholder="Nombre y apellido">
        <input type="text" id="inviteEspecialidad" placeholder="Especialidad (opcional)">
        <select id="inviteRol">
          <option value="medico">Médico</option>
          <option value="residente">Residente</option>
        </select>
        <div class="sanDropdown" id="inviteSanatoriosDropdown" style="display:none">
          <button type="button" class="secondary sanDropdownBtn" id="inviteSanatoriosBtn">Todos los sanatorios ▾</button>
          <div class="sanDropdownPanel" id="inviteSanatoriosPanel"></div>
        </div>
        <button id="btnInvite" class="secondary">Invitar</button>
      </div>
      <div class="msg" id="inviteMsg"></div>
    </div>
  </details>

  <details class="panel" id="panelSanatoriosAdmin" style="display:none">
    <summary style="font-size:14px; font-weight:600">🏥 Sanatorios</summary>
    <div style="margin-top:16px">
      <div class="msg" style="margin-top:0; margin-bottom:8px">Dirección, zona de facturación y contactos vinculados de cada sanatorio, todo en un solo lugar — visible y editable solo para vos.</div>
      <div class="contactForm">
        <input type="text" id="nuevoSanatorioNombre" placeholder="Nombre del sanatorio nuevo">
        <button id="btnAddSanatorioAdmin" class="secondary">Agregar sanatorio</button>
      </div>
      <div id="sanatoriosAdminGrid" style="margin-top:16px"></div>
    </div>
  </details>

  <!-- ==================== RESUMEN ==================== -->
  <div class="view active" id="viewResumen">
    <div class="toolbar">
      <span class="count" id="resumenCount"></span>
    </div>
    <div id="resumenContainer"></div>
    <div class="empty" id="resumenEmpty">No hay cirugías programadas, internados ni interconsultas pendientes.</div>
  </div>

  <!-- ==================== INTERCONSULTAS ==================== -->
  <div class="view" id="viewInterconsultas">
    <div class="toolbar">
      <input type="text" id="search" placeholder="Buscar paciente, sanatorio, diagnóstico...">
      <select id="filterSanatorio"><option value="">Todos los sanatorios</option></select>
      <select id="filterZona"><option value="">Todas las zonas</option></select>
      <select id="filterEstado">
        <option value="">Todos los estados</option>
        <option value="pendiente" selected>Pendientes</option>
        <option value="resuelta">Resueltas</option>
      </select>
      <label style="font-size:12px; color:var(--muted); display:flex; align-items:center; gap:6px">Desde <input type="date" id="filterDesde"></label>
      <label style="font-size:12px; color:var(--muted); display:flex; align-items:center; gap:6px">Hasta <input type="date" id="filterHasta"></label>
      <button class="secondary" id="btnExport">Exportar CSV</button>
      <button class="danger" id="btnClear">Borrar todo</button>
      <span class="count" id="count"></span>
    </div>

    <div id="icGrid"></div>
    <div class="empty" id="emptyState">Todavía no cargaste interconsultas.</div>

    <details class="panel" id="panelCargarDatos" style="margin-top:16px">
      <summary style="font-size:14px; font-weight:600">➕ Cargar mensajes</summary>

      <div style="margin-top:16px">
        <h2>Cargar mensajes</h2>
        <textarea id="input" placeholder="Pegá acá el texto exportado del chat de WhatsApp (o uno o varios mensajes de interconsulta sueltos)..."></textarea>
        <div class="row">
          <button id="btnProcess">Procesar mensajes</button>
          <button id="btnAddManual" class="secondary">+ Agregar fila manual</button>
          <span class="msg" id="msg"></span>
        </div>
        <details style="margin-top:8px">
          <summary>¿Cómo exporto el chat de WhatsApp?</summary>
          <div class="msg" style="margin-top:6px">
            En el chat: menú (⋮) → Más → Exportar chat → Sin archivos multimedia. Se genera un .txt: abrilo, copiá el contenido y pegalo acá.
            También podés pegar mensajes sueltos copiados a mano, uno por línea o separados en párrafos.
          </div>
        </details>

        <div style="margin-top:16px; padding-top:16px; border-top:1px solid var(--border)">
          <div class="row" style="margin-top:0">
            <input type="file" id="capturaFile" accept="image/*" multiple>
            <span class="msg" style="margin:0" id="capturaMsg"></span>
          </div>
          <div class="msg" style="margin-top:6px">
            📷 O subí directamente la captura de pantalla de WhatsApp, igual que si se la mandaras al bot de Telegram. Se procesa sola en segundo plano (puede demorar hasta 2 horas) y la interconsulta aparece automáticamente arriba.
          </div>
          <ul class="contactList" id="capturasPendientesList" style="margin-top:10px"></ul>
        </div>
      </div>

      <div style="margin-top:24px">
        <h2>Valor de interconsulta por sanatorio</h2>
        <div class="msg" style="margin-top:0; margin-bottom:8px">Si un sanatorio te paga la interconsulta aparte (ej: Berazategui), cargá el valor acá. Al contestar o programar una interconsulta de ese sanatorio, se registra sola para facturación en la pestaña Consultorio.</div>
        <div class="contactForm">
          <input type="text" id="valorIcSanatorio" placeholder="Sanatorio" list="sanatoriosDatalist">
          <input type="number" id="valorIcInput" placeholder="Valor" step="0.01" min="0">
          <button id="btnAddValorIc" class="secondary">Vincular</button>
        </div>
        <ul class="contactList" id="valorIcList"></ul>
      </div>

    </details>
  </div>

  <!-- ==================== PACIENTES ==================== -->
  <div class="view" id="viewPacientes">

    <!-- ---- Listado ---- -->
    <div id="pacListView">
      <div class="toolbar">
        <input type="text" id="pacSearch" placeholder="Buscar por nombre, DNI o teléfono...">
        <span class="count" id="pacCount"></span>
      </div>

      <div class="panel">
        <h2>Nuevo paciente</h2>
        <div class="contactForm">
          <input type="text" id="pacNombre" placeholder="Nombre y apellido *">
          <input type="text" id="pacSanatorio" placeholder="Sanatorio" list="sanatoriosDatalist3">
          <input type="number" id="pacEdad" placeholder="Edad" min="0" max="130" style="max-width:90px">
          <input type="text" id="pacDni" placeholder="DNI">
          <input type="text" id="pacOs" placeholder="OS (obra social)">
          <input type="text" id="pacNroAfiliado" placeholder="Nro. afiliado">
          <input type="text" id="pacTelefono" placeholder="Teléfono">
          <input type="text" id="pacDiagnostico" placeholder="Diagnóstico">
          <button id="btnAddPaciente">Agregar</button>
        </div>
        <div class="msg" id="pacMsg"></div>
      </div>

      <div class="panel" style="padding:0; overflow-x:auto">
        <table>
          <thead>
            <tr>
              <th>Nombre</th>
              <th>Sanatorio</th>
              <th>Edad</th>
              <th>DNI</th>
              <th>Diagnóstico</th>
              <th>Fecha Qx</th>
              <th>Condición</th>
              <th></th>
            </tr>
          </thead>
          <tbody id="pacTbody"></tbody>
        </table>
        <div class="empty" id="pacEmpty">Todavía no cargaste pacientes.</div>
      </div>
    </div>

    <!-- ---- Ficha detallada ---- -->
    <div id="pacDetailView" style="display:none">
      <div class="row" style="margin-top:0; margin-bottom:6px">
        <button class="secondary" id="btnPacBack">← Volver a la lista</button>
      </div>

      <div class="panel">
        <div class="row" style="margin-top:0; justify-content:space-between">
          <h2 style="margin:0">Datos generales</h2>
          <span id="pdCondicion"></span>
        </div>
        <div class="fichaGrid">
          <label>Nombre y apellido<input type="text" data-pk="nombre" id="pdNombre"></label>
          <label>Sanatorio <span id="pdSanatorioDot" class="sanatorioDot" style="background:transparent"></span><input type="text" data-pk="sanatorio" id="pdSanatorio" list="sanatoriosDatalist3"></label>
          <label>Edad<input type="number" data-pk="edad" id="pdEdad" min="0" max="130"></label>
          <label>Sexo
            <select data-pk="sexo" id="pdSexo">
              <option value="">Sin definir</option>
              <option value="masculino">Masculino</option>
              <option value="femenino">Femenino</option>
            </select>
          </label>
          <label>DNI<input type="text" data-pk="dni" id="pdDni"></label>
          <label>OS (obra social)<input type="text" data-pk="os" id="pdOs"></label>
          <label>Nro. afiliado<input type="text" data-pk="nro_afiliado" id="pdNroAfiliado"></label>
          <label>Teléfono<input type="text" data-pk="telefono" id="pdTelefono"></label>
          <label>Diagnóstico<input type="text" data-pk="diagnostico" id="pdDiagnostico"></label>
          <label style="grid-column:1/-1">Notas<textarea data-pk="notas" id="pdNotas" placeholder="Notas generales..."></textarea></label>
        </div>
        <details style="margin-top:14px" id="copagoDetails">
          <summary style="font-size:13px; font-weight:600; color:var(--text)" title="Copago">💰</summary>
          <div class="fichaGrid" style="margin-top:12px">
            <label>Monto<input type="text" data-pk="copago_monto" id="pdCopagoMonto" placeholder="ej: 50000"></label>
            <label>Estado
              <select data-pk="copago_estado" id="pdCopagoEstado">
                <option value="">Sin definir</option>
                <option value="pago">Pago</option>
                <option value="pendiente">Pendiente</option>
                <option value="no_acepta">No acepta</option>
              </select>
            </label>
          </div>
        </details>
      </div>

      <div class="panel">
        <h2>Antecedentes personales</h2>
        <div class="antGrid" id="pdAntecedentesGrid"></div>
        <label class="fieldFull">Otros antecedentes
          <input type="text" id="pdAntecedentesOtros" placeholder="Otros antecedentes no listados">
        </label>
      </div>

      <div class="panel">
        <h2>Operación</h2>
        <div class="fichaGrid">
          <label>Operación a realizar<input type="text" data-pk="operacion" id="pdOperacion"></label>
          <label>Fecha Qx<input type="date" data-pk="fecha_qx" id="pdFechaQx"></label>
          <label>Hora Qx<input type="time" data-pk="hora_qx" id="pdHoraQx"></label>
          <label>Materiales
            <select class="matSelect" data-pk="materiales" id="pdMateriales">
              <option value="">Sin definir</option>
              <option value="no_requiere">No requiere</option>
              <option value="pendiente_autorizacion">Pendiente de autorización</option>
              <option value="autorizados">Autorizados</option>
              <option value="en_quirofano">En quirófano</option>
            </select>
          </label>
          <label>Consentimiento informado (link)
            <div class="row" style="margin-top:0; gap:6px; flex-wrap:nowrap">
              <input type="text" data-pk="consentimiento_link" id="pdConsentimientoLink" placeholder="https://..." style="flex:1; min-width:0">
              <button type="button" class="secondary linkOpenBtn" data-target="pdConsentimientoLink" title="Abrir consentimiento" style="padding:8px 10px">🔗</button>
            </div>
          </label>
          <label>Estado del consentimiento
            <select data-pk="consentimiento_estado" id="pdConsentimientoEstado">
              <option value="">Sin definir</option>
              <option value="pendiente">Pendiente</option>
              <option value="entregado">Entregado</option>
              <option value="firmado">Firmado</option>
            </select>
          </label>
        </div>
        <div class="msg" id="fechaQxLockMsg" style="margin-top:8px">Definí Materiales en "En quirófano" o "No requiere" para poder programar la fecha.</div>
        <label style="display:flex; align-items:center; gap:8px; margin-top:14px; font-size:13px; font-weight:normal; cursor:pointer">
          <input type="checkbox" id="pdOperado"> Ya fue operado (marca hoy como Fecha Qx)
        </label>
        <div class="row" style="margin-top:14px">
          <button type="button" class="secondary" id="btnReprogramarCx">📅 Reprogramar</button>
          <button type="button" class="danger" id="btnCancelarCx">✕ Cancelar cirugía</button>
          <button type="button" class="secondary" id="btnAgregarCirugia">+ Agregar cirugía (reoperar)</button>
        </div>
        <div id="historialCirugias"></div>
      </div>

      <div class="panel">
        <h2>Datos clínicos</h2>
        <textarea data-pk="datos_clinicos" id="pdDatosClinicos" placeholder="Datos médicos breves..."></textarea>
      </div>

      <div class="panel">
        <h2>Prequirúrgico</h2>
        <h3 class="subhead" style="margin-top:0">Laboratorio</h3>
        <div class="fichaGrid" id="pqLaboratorioGrid"></div>

        <h3 class="subhead">RCV (riesgo cardiovascular)</h3>
        <textarea data-pqx="rcv" id="pqRcv" style="min-height:60px"></textarea>

        <h3 class="subhead">Funcional respiratorio</h3>
        <div class="fichaGrid">
          <label>Espirometría · CVF<input type="text" data-pqx="funcional_respiratorio.espirometria.cvf" id="pqCvf" placeholder="ej: 3.2 L (85%)"></label>
          <label>Espirometría · VEF1<input type="text" data-pqx="funcional_respiratorio.espirometria.vef1" id="pqVef1" placeholder="ej: 2.5 L (78%)"></label>
          <label>DLCO<input type="text" data-pqx="funcional_respiratorio.dlco" id="pqDlco" placeholder="ej: 75%"></label>
        </div>

        <h3 class="subhead">Imágenes</h3>
        <div class="imgSubcard">
          <h3>TC</h3>
          <div class="fichaGrid">
            <label>Link del estudio
              <div class="row" style="margin-top:0; gap:6px; flex-wrap:nowrap">
                <input type="text" data-pqx="imagenes.tc.link" id="pqTcLink" placeholder="https://..." style="flex:1; min-width:0">
                <button type="button" class="secondary linkOpenBtn" data-target="pqTcLink" title="Abrir estudio" style="padding:8px 10px">🔗</button>
              </div>
            </label>
            <label>Usuario<input type="text" data-pqx="imagenes.tc.usuario" id="pqTcUsuario"></label>
            <label>Contraseña<input type="text" data-pqx="imagenes.tc.password" id="pqTcPassword"></label>
          </div>
          <div class="row">
            <input type="file" id="pqTcFile" accept="image/*" multiple>
            <span class="msg" style="margin:0" id="pqTcMsg"></span>
          </div>
          <div class="fotoGrid" id="pqTcFotos"></div>
        </div>

        <div class="imgSubcard">
          <h3>PET</h3>
          <div class="fichaGrid">
            <label>Link del estudio
              <div class="row" style="margin-top:0; gap:6px; flex-wrap:nowrap">
                <input type="text" data-pqx="imagenes.pet.link" id="pqPetLink" placeholder="https://..." style="flex:1; min-width:0">
                <button type="button" class="secondary linkOpenBtn" data-target="pqPetLink" title="Abrir estudio" style="padding:8px 10px">🔗</button>
              </div>
            </label>
            <label>Usuario<input type="text" data-pqx="imagenes.pet.usuario" id="pqPetUsuario"></label>
            <label>Contraseña<input type="text" data-pqx="imagenes.pet.password" id="pqPetPassword"></label>
            <label>Captación FDG
              <select data-pqx="imagenes.pet.captacion" id="pqPetCaptacion">
                <option value="">Sin cargar</option>
                <option value="ninguna">Sin captación</option>
                <option value="discreta">Discreta</option>
                <option value="moderada">Moderada</option>
                <option value="intensa">Intensa</option>
              </select>
            </label>
          </div>
          <div class="row">
            <input type="file" id="pqPetFile" accept="image/*" multiple>
            <span class="msg" style="margin:0" id="pqPetMsg"></span>
          </div>
          <div class="fotoGrid" id="pqPetFotos"></div>
        </div>
      </div>

      <div class="panel" id="pretestNoduloSection" style="display:none">
        <h2>Pretest nódulo pulmonar</h2>
        <div class="fichaGrid">
          <label>Diámetro (mm)<input type="number" min="0" step="1" data-pqx="nodulo.diametro_mm" id="pqNoduloDiametro"></label>
          <label>N° de nódulos<input type="number" min="1" step="1" data-pqx="nodulo.numero_nodulos" id="pqNoduloCantidad" placeholder="1"></label>
          <label>Tipo de nódulo
            <select data-pqx="nodulo.tipo" id="pqNoduloTipo">
              <option value="solido">Sólido</option>
              <option value="subsolido">Subsólido (parcialmente sólido)</option>
              <option value="no_solido">No sólido (vidrio esmerilado)</option>
            </select>
          </label>
        </div>
        <div class="antGrid" style="margin-top:12px">
          <label><input type="checkbox" data-pqx="nodulo.espiculacion" id="pqNoduloEspiculacion"> Espiculación</label>
          <label><input type="checkbox" data-pqx="nodulo.lobulo_superior" id="pqNoduloLoboSuperior"> Lóbulo superior</label>
          <label><input type="checkbox" data-pqx="nodulo.enfisema" id="pqNoduloEnfisema"> Enfisema</label>
          <label><input type="checkbox" data-pqx="nodulo.antecedente_familiar" id="pqNoduloFamiliar"> Antecedente familiar de cáncer de pulmón</label>
        </div>
        <div class="pretestResult">
          <div class="pretestModelo" id="pretestModeloLabel">Modelo de Brock (CT)</div>
          <div class="pretestNumero" id="pretestNumero"></div>
          <div class="pretestBar"><div class="pretestBarFill" id="pretestBarFill"></div></div>
          <div class="pretestCategoria" id="pretestCategoria"></div>
        </div>
        <div class="pretestResult" id="pretestHerderBlock" style="display:none; margin-top:10px">
          <div class="pretestModelo">Modelo de Herder (Mayo + PET) · complementario</div>
          <div class="pretestNumero" id="pretestHerderNumero"></div>
          <div class="pretestBar"><div class="pretestBarFill" id="pretestHerderBarFill"></div></div>
          <div class="pretestCategoria" id="pretestHerderCategoria"></div>
        </div>
      </div>

      <div class="panel">
        <h2>Protocolo quirúrgico y anatomía patológica</h2>
        <label class="fieldFull" style="margin-top:0">Protocolo quirúrgico (link)
          <div class="row" style="margin-top:0; gap:6px; flex-wrap:nowrap">
            <input type="text" data-pk="protocolo_qx_link" id="pdProtocoloLink" placeholder="https://..." style="flex:1; min-width:0">
            <button type="button" class="secondary linkOpenBtn" data-target="pdProtocoloLink" title="Abrir link" style="padding:8px 10px">🔗</button>
          </div>
        </label>
        <label class="fieldFull">Anatomía patológica
          <textarea data-pk="anatomia_patologica_link" id="pdAnatPatLink" placeholder="Escribir informe de anatomía patológica..."></textarea>
        </label>
      </div>

      <a id="pdWhatsappFab" class="fab whatsappFab" href="#" target="_blank" rel="noopener" title="Abrir WhatsApp" style="display:none">💬</a>
    </div>
  </div>
  <datalist id="sanatoriosDatalist3"></datalist>

  <!-- ==================== AGENDA (calendario quirúrgico) ==================== -->
  <div class="view" id="viewAgenda">
    <div class="toolbar">
      <div class="calNav">
        <button class="secondary" id="calPrev">‹</button>
        <button class="secondary" id="calToday">Hoy</button>
        <button class="secondary" id="calNext">›</button>
        <span id="calLabel" class="calLabel"></span>
      </div>
      <div class="calViewSwitch">
        <button class="secondary calViewBtn active" data-calview="day">Día</button>
        <button class="secondary calViewBtn" data-calview="week">Semana</button>
        <button class="secondary calViewBtn" data-calview="month">Mes</button>
      </div>
      <select id="agFilterSanatorio"><option value="">Todos los sanatorios</option></select>
    </div>

    <div class="panel" id="calContainer" style="padding:0; overflow:hidden"></div>

    <button id="btnFabAdd" class="fab" title="Agregar paciente">+</button>
  </div>

  <!-- ==================== INTERNADOS ==================== -->
  <div class="view" id="viewInternados">
    <div class="toolbar">
      <select id="intFilterSanatorio"><option value="">Todos los sanatorios</option></select>
      <select id="intFilterSector"><option value="">Todos los sectores</option></select>
      <span class="count" id="intCount"></span>
    </div>

    <div class="panel">
      <h2>Nuevo ingreso</h2>
      <div class="contactForm">
        <input type="text" id="intPaciente" placeholder="Paciente" list="pacientesDatalistInt">
        <input type="text" id="intSanatorio" placeholder="Sanatorio" list="sanatoriosDatalist">
        <input type="text" id="intSector" placeholder="Sector / Piso" list="sectoresDatalist">
        <input type="text" id="intHabitacion" placeholder="Habitación">
        <input type="text" id="intCama" placeholder="Cama">
        <input type="date" id="intFechaIngreso">
        <button id="btnAddInternacion">Ingresar</button>
      </div>
      <div class="msg" id="intMsg"></div>
    </div>

    <div class="internadosGrid" id="internadosGrid"></div>
    <div class="empty" id="intEmpty">No hay pacientes internados activos.</div>
  </div>

  <div class="modalOverlay" id="evolucionOverlay" style="display:none">
    <div class="modalCard">
      <div class="row" style="margin-top:0; justify-content:space-between">
        <h2 style="margin:0" id="evolucionTitulo">Evolución</h2>
        <span class="del" id="btnCerrarEvolucion" title="Cerrar">✕</span>
      </div>
      <div class="msg" id="evolucionSub" style="margin-top:2px"></div>
      <div class="contactForm" style="margin-top:8px">
        <input type="text" id="evolSector" placeholder="Sector / Piso" list="sectoresDatalist">
        <input type="text" id="evolHabitacion" placeholder="Habitación">
        <input type="text" id="evolCama" placeholder="Cama">
      </div>
      <div class="msg" id="evolucionLocMsg" style="margin-top:4px"></div>
      <div id="evolucionList" class="evolucionList"></div>
      <div class="row" style="margin-top:12px">
        <textarea id="evolucionInput" placeholder="Nueva evolución..." style="min-height:60px; flex:1"></textarea>
      </div>
      <div class="row">
        <button id="btnAddEvolucion">Agregar evolución</button>
        <button class="danger" id="btnDarDeAlta">Dar de alta</button>
      </div>
    </div>
  </div>

  <div class="modalOverlay" id="manualIcOverlay" style="display:none">
    <div class="modalCard">
      <div class="row" style="margin-top:0; justify-content:space-between">
        <h2 style="margin:0">Agregar interconsulta manual</h2>
        <span class="del" id="btnCerrarManualIc" title="Cerrar">✕</span>
      </div>
      <form id="manualIcForm">
        <label class="loginLabel">Nombre y apellido</label>
        <input type="text" id="manualIcPaciente" required style="width:100%">
        <label class="loginLabel">Sanatorio</label>
        <input type="text" id="manualIcSanatorio" list="sanatoriosDatalist" style="width:100%">
        <label class="loginLabel">Diagnóstico</label>
        <input type="text" id="manualIcDiagnostico" style="width:100%">
        <label class="loginLabel">Fecha</label>
        <input type="date" id="manualIcFecha" style="width:100%">
        <div class="row" style="margin-top:0">
          <div style="flex:1">
            <label class="loginLabel">Piso</label>
            <input type="text" id="manualIcPiso" style="width:100%">
          </div>
          <div style="flex:1">
            <label class="loginLabel">Cama</label>
            <input type="text" id="manualIcCama" style="width:100%">
          </div>
        </div>
        <button type="submit" style="width:100%; margin-top:16px">Guardar</button>
        <div class="msg" id="manualIcMsg"></div>
      </form>
    </div>
  </div>

  <!-- ==================== CONSULTORIO ==================== -->
  <div class="view" id="viewConsultorio">
    <div class="toolbar">
      <select id="consFilterSanatorio"><option value="">Todos los sanatorios</option></select>
      <select id="consFilterOs">
        <option value="">Todas las OS</option>
        <option value="PAMI">PAMI</option>
        <option value="OSDE">OSDE</option>
        <option value="Swiss Medical">Swiss Medical</option>
        <option value="Medife">Medife</option>
        <option value="Samisalud">Samisalud</option>
        <option value="IOMA">IOMA</option>
        <option value="Particular">Particular</option>
      </select>
      <label style="font-size:12px; color:var(--muted); display:flex; align-items:center; gap:6px">Desde <input type="date" id="consFilterDesde"></label>
      <label style="font-size:12px; color:var(--muted); display:flex; align-items:center; gap:6px">Hasta <input type="date" id="consFilterHasta"></label>
      <button class="secondary" id="btnExportConsultas">Exportar CSV</button>
      <span class="count" id="consCount"></span>
    </div>

    <div class="panel">
      <h2>Nuevo registro</h2>
      <div class="contactForm">
        <input type="date" id="consFecha">
        <input type="text" id="consSanatorio" placeholder="Sanatorio" list="sanatoriosDatalist">
        <input type="text" id="consPaciente" placeholder="Paciente">
        <select id="consOs">
          <option value="">OS</option>
          <option value="PAMI">PAMI</option>
          <option value="OSDE">OSDE</option>
          <option value="Swiss Medical">Swiss Medical</option>
          <option value="Medife">Medife</option>
          <option value="Samisalud">Samisalud</option>
          <option value="IOMA">IOMA</option>
          <option value="Particular">Particular</option>
        </select>
        <input type="number" id="consValor" placeholder="Valor" step="0.01" min="0">
        <button id="btnAddConsulta">Agregar</button>
      </div>
      <div class="msg" id="consMsg"></div>
    </div>

    <details class="panel" id="panelPreciosConsulta">
      <summary style="font-size:14px; font-weight:600">💰 Precios por sanatorio y obra social</summary>
      <div style="margin-top:16px">
        <div class="msg" style="margin-top:0; margin-bottom:8px">Se usa para autocompletar el valor al cargar una consulta nueva.</div>
        <div class="contactForm">
          <input type="text" id="precioSanatorio" placeholder="Sanatorio" list="sanatoriosDatalist">
          <select id="precioOs">
            <option value="">OS</option>
            <option value="unico">Valor único (todas las OS)</option>
            <option value="PAMI">PAMI</option>
            <option value="OSDE">OSDE</option>
            <option value="Swiss Medical">Swiss Medical</option>
            <option value="Medife">Medife</option>
            <option value="Samisalud">Samisalud</option>
            <option value="IOMA">IOMA</option>
            <option value="Particular">Particular</option>
          </select>
          <input type="number" id="precioValor" placeholder="Valor" step="0.01" min="0">
          <button id="btnAddPrecio" class="secondary">Vincular</button>
        </div>
        <ul class="contactList" id="preciosList"></ul>
      </div>
    </details>

    <details class="panel" id="panelIcFacturables">
      <summary style="font-size:14px; font-weight:600">📋 Interconsultas facturables (Berazategui, etc.)</summary>
      <div style="margin-top:16px">
        <div class="msg" style="margin-top:0; margin-bottom:8px">Se cargan solas al contestar o programar una interconsulta de un sanatorio con valor de interconsulta configurado (panel de Interconsultas). Borralas una vez que ya las facturaste, así llevás el control de lo pendiente.</div>
        <div class="toolbar" style="margin-top:0">
          <span class="count" id="icFactCount"></span>
          <button class="secondary" id="btnExportIcFacturables">Exportar CSV</button>
        </div>
        <div id="icFacturablesGrid"></div>
        <div class="empty" id="icFacturablesEmpty" style="display:none">Sin interconsultas facturables pendientes de exportar.</div>
      </div>
    </details>

    <div id="consultasGrid"></div>
    <div class="empty" id="consEmpty">Todavía no cargaste consultas.</div>
  </div>

  <datalist id="sanatoriosDatalist"></datalist>
  <datalist id="sectoresDatalist"></datalist>
  <datalist id="pacientesDatalistInt"></datalist>
</div>

<script>
if('serviceWorker' in navigator){
  window.addEventListener('load', () => navigator.serviceWorker.register('/sw.js').catch(() => {}));
}

(function(){
  const SUPABASE_URL = 'https://cwcsounmbitxmlxedqdu.supabase.co';
  const SUPABASE_ANON_KEY = 'sb_publishable_rnjTnwiI3kQHTBXBVl8sGA_Cip2sfJ2';
  const VAPID_PUBLIC_KEY = 'BMeaUny_IWTFYB6CayMJj1KhVh6Ufv1XwGX9dZeeJMERhKEpWdEiwAh8O8VkGkNdOC-SfCHfUq49KYIaWdHgM4g';
  const GOOGLE_CLIENT_ID = '612852155292-615n055ps8mn9kc08hoch1qh9bumq597.apps.googleusercontent.com';
  const GOOGLE_OAUTH_REDIRECT = SUPABASE_URL + '/functions/v1/google-oauth-callback';
  const sb = window.supabase.createClient(SUPABASE_URL, SUPABASE_ANON_KEY);

  const $ = sel => document.querySelector(sel);

  function urlBase64ToUint8Array(base64String){
    const padding = '='.repeat((4 - base64String.length % 4) % 4);
    const base64 = (base64String + padding).replace(/-/g, '+').replace(/_/g, '/');
    const rawData = atob(base64);
    const outputArray = new Uint8Array(rawData.length);
    for(let i = 0; i < rawData.length; ++i) outputArray[i] = rawData.charCodeAt(i);
    return outputArray;
  }

  async function activarNotificaciones(){
    if(!('serviceWorker' in navigator) || !('PushManager' in window)){
      flash('Tu navegador no soporta notificaciones push.', true);
      return;
    }
    const perm = await Notification.requestPermission();
    if(perm !== 'granted'){
      flash('No se activaron las notificaciones (permiso denegado).', true);
      return;
    }
    const reg = await navigator.serviceWorker.ready;
    let sub = await reg.pushManager.getSubscription();
    if(!sub){
      sub = await reg.pushManager.subscribe({
        userVisibleOnly: true,
        applicationServerKey: urlBase64ToUint8Array(VAPID_PUBLIC_KEY)
      });
    }
    const raw = sub.toJSON();
    const { error } = await sb.from('push_subscriptions').upsert({
      endpoint: raw.endpoint,
      p256dh: raw.keys.p256dh,
      auth: raw.keys.auth
    }, { onConflict: 'endpoint' });
    if(error){ flash('Error al guardar la suscripción: ' + error.message, true); return; }
    flash('Notificaciones activadas.');
  }

  async function syncBadge(){
    if(!('setAppBadge' in navigator)) return;
    const count = items.filter(it => it.estado === 'pendiente').length;
    try {
      if(count > 0) await navigator.setAppBadge(count);
      else await navigator.clearAppBadge();
    } catch(e) {}
  }

  let currentUser = null;
  let currentMedico = null;
  let items = [];
  let contacts = [];
  let zonas = [];
  let capturasPendientes = [];
  let preciosInterconsulta = [];
  let interconsultasFacturables = [];
  let sanatoriosRef = [];
  let medicos = [];
  let pacientes = [];
  let sortKey = 'default', sortDir = 'asc';

  function isUtiUci(it){
    const hay = ((it.habitacion || '') + ' ' + (it.cama || '')).toLowerCase();
    return /\b(uti|uci)\b/.test(hay);
  }

  function camaNumeric(it){
    const m = String(it.cama || '').match(/\d+/);
    return m ? parseInt(m[0], 10) : Number.MAX_SAFE_INTEGER;
  }

  function defaultCompare(a, b){
    const sa = (a.sanatorio || '').toLowerCase(), sb = (b.sanatorio || '').toLowerCase();
    if(sa !== sb) return sa < sb ? -1 : 1;
    const ua = isUtiUci(a) ? 0 : 1, ub = isUtiUci(b) ? 0 : 1;
    if(ua !== ub) return ua - ub;
    const ca = camaNumeric(a), cb = camaNumeric(b);
    if(ca !== cb) return ca - cb;
    return 0;
  }

  function digitsOnly(s){ return String(s || '').replace(/\D+/g, ''); }

  function lookupSanatorioForSender(sender){
    if(!sender) return '';
    const s = sender.trim().toLowerCase();
    if(!s) return '';
    const sDigits = digitsOnly(sender);
    let bestLen = -1, bestSan = '';
    for(const c of contacts){
      const cName = (c.contacto || '').trim().toLowerCase();
      if(!cName) continue;
      let isMatch = (s === cName || s.includes(cName) || cName.includes(s));
      if(!isMatch && sDigits.length >= 6){
        const cDigits = digitsOnly(c.contacto);
        if(cDigits.length >= 6 && (sDigits.includes(cDigits) || cDigits.includes(sDigits))) isMatch = true;
      }
      if(isMatch){
        if(cName.length > bestLen){ bestLen = cName.length; bestSan = c.sanatorio; }
      }
    }
    return bestSan;
  }

  function lookupZonaForSanatorio(sanatorio){
    if(!sanatorio) return '';
    const s = normalize(sanatorio);
    const match = zonas.find(z => normalize(z.sanatorio) === s);
    return match ? match.zona : '';
  }

  // ---- Parsing ----
  // WhatsApp export line: "DD/MM/YY(YY), HH:MM[:SS] [a.m./p.m.] - Sender: Message"
  // or iOS: "[DD/MM/YY, HH:MM:SS] Sender: Message"
  const lineStart = /^\[?(\d{1,2}\/\d{1,2}\/\d{2,4}),?\s+(\d{1,2}:\d{2}(?::\d{2})?\s?(?:[ap]\.?\s?m\.?)?)\]?\s*[-–]\s*([^:]{1,60}):\s?(.*)$/i;
  const lineStartIOS = /^\[(\d{1,2}\/\d{1,2}\/\d{2,4}),?\s+(\d{1,2}:\d{2}(?::\d{2})?\s?(?:[ap]\.?\s?m\.?)?)\]\s*([^:]{1,60}):\s?(.*)$/i;

  function splitIntoMessages(raw){
    const lines = raw.split(/\r?\n/);
    const messages = [];
    let current = null;
    for(const line of lines){
      let m = line.match(lineStart) || line.match(lineStartIOS);
      if(m){
        if(current) messages.push(current);
        current = { fecha: m[1], hora: m[2], sender: m[3].trim(), text: m[4] };
      } else if(current){
        current.text += '\n' + line;
      } else {
        if(line.trim() !== ''){
          if(!current) current = { fecha:'', hora:'', sender:'', text: line };
          else current.text += '\n' + line;
        }
      }
    }
    if(current) messages.push(current);

    if(messages.length <= 1 && !raw.match(lineStart) && !raw.match(lineStartIOS)){
      return raw.split(/\n\s*\n/).map(t => t.trim()).filter(Boolean).map(t => ({fecha:'', hora:'', sender:'', text:t}));
    }
    return messages.filter(m => m.text && m.text.trim() !== '');
  }

  function extractField(text, patterns){
    for(const p of patterns){
      const m = text.match(p);
      if(m && m[1]) return m[1].trim().replace(/[.,;]+$/,'');
    }
    return '';
  }

  function parseMessage(raw){
    const text = raw.text;
    let sanatorio = extractField(text, [
      /sanatorio[:\s]+([^\n,;]+)/i,
      /cl[íi]nica[:\s]+([^\n,;]+)/i,
      /hospital[:\s]+([^\n,;]+)/i
    ]);
    if(!sanatorio) sanatorio = lookupSanatorioForSender(raw.sender);
    const zona = lookupZonaForSanatorio(sanatorio);
    const paciente = extractField(text, [
      /paciente[:\s]+([^\n,;]+)/i,
      /pcte\.?[:\s]+([^\n,;]+)/i
    ]);
    const habitacion = extractField(text, [
      /habitaci[oó]n[:\s]+([^\n,;]+)/i,
      /\bhab\.?[:\s]+([^\n,;\s]+)/i
    ]);
    const piso = extractField(text, [
      /piso[:\s]+([^\n,;]+)/i
    ]);
    const cama = extractField(text, [
      /\bcama[:\s]+([^\n,;]+)/i
    ]);
    const diagnostico = extractField(text, [
      /diagn[oó]stico[:\s]+([^\n;]+)/i,
      /\bdx\.?[:\s]+([^\n;]+)/i
    ]);
    let fecha = raw.fecha || '';
    if(fecha && raw.hora) fecha = fecha + ' ' + raw.hora;

    return {
      fecha,
      sanatorio, zona, paciente, habitacion, piso, cama, diagnostico,
      estado: 'pendiente',
      fechaResuelta: '',
      original: (raw.sender ? raw.sender + ': ' : '') + text.trim()
    };
  }

  function normalize(s){
    return String(s || '')
      .toLowerCase()
      .normalize('NFD').replace(/[̀-ͯ]/g, '')
      .replace(/\s+/g, ' ')
      .trim();
  }

  // ---- Color por sanatorio (determinístico, consistente en toda la app) ----
  const SANATORIO_PALETTE = [
    '#ef4444','#f97316','#f59e0b','#eab308','#84cc16','#22c55e','#10b981',
    '#14b8a6','#06b6d4','#0ea5e9','#3b82f6','#6366f1','#8b5cf6','#a855f7','#d946ef','#ec4899'
  ];
  function sanatorioColor(nombre){
    const n = normalize(nombre);
    if(!n) return null;
    let h = 0;
    for(let i = 0; i < n.length; i++) h = (h * 31 + n.charCodeAt(i)) >>> 0;
    return SANATORIO_PALETTE[h % SANATORIO_PALETTE.length];
  }
  function sanatorioDot(nombre){
    const c = sanatorioColor(nombre);
    return c ? `<span class="sanatorioDot" style="background:${c}"></span>` : '';
  }
  function sanatorioChip(nombre){
    return `<span class="sanatorioChip">${sanatorioDot(nombre)}${escapeHtml(nombre)}</span>`;
  }

  // Busca una interconsulta ya cargada (en `list`) para el mismo paciente+sanatorio.
  function findDuplicate(newItem, list){
    list = list || items;
    const p = normalize(newItem.paciente);
    const s = normalize(newItem.sanatorio);
    if(!p) return null;
    const match = list.find(it => normalize(it.paciente) === p && (!s || normalize(it.sanatorio) === s));
    if(!match) return null;
    if(match.estado === 'pendiente') return { item: match, skip: true, reason: 'ya estaba pendiente' };
    if(match.estado === 'resuelta'){
      if(match.fechaResuelta){
        const days = (Date.now() - new Date(match.fechaResuelta).getTime()) / 86400000;
        if(days >= 2) return { item: match, skip: true, reason: 'ya resuelta hace 2+ días' };
      }
    }
    return { item: match, skip: false, reason: 'posible reingreso' };
  }

  function normalizeDateForSort(fecha){
    const m = fecha.match(/^(\d{1,2})\/(\d{1,2})\/(\d{2,4})\s*(\d{1,2}:\d{2})?/);
    if(!m) return fecha || '';
    let [, d, mo, y, hm] = m;
    if(y.length === 2) y = '20' + y;
    return `${y.padStart(4,'0')}-${mo.padStart(2,'0')}-${d.padStart(2,'0')} ${hm||'00:00'}`;
  }

  function mapRowToItem(row){
    return {
      id: row.id,
      fecha: row.fecha || '',
      sanatorio: row.sanatorio || '',
      zona: row.zona || '',
      paciente: row.paciente || '',
      habitacion: row.habitacion || '',
      piso: row.piso || '',
      cama: row.cama || '',
      diagnostico: row.diagnostico || '',
      estado: row.estado || 'pendiente',
      fechaResuelta: row.fecha_resuelta || '',
      exportadoAt: row.exportado_at || '',
      original: row.original || ''
    };
  }

  // ---- UI wiring ----
  const loginScreen = $('#loginScreen');
  const setupScreen = $('#setupScreen');
  const appScreen = $('#appScreen');
  const loginForm = $('#loginForm');
  const loginMsg = $('#loginMsg');
  const setupForm = $('#setupForm');
  const setupMsg = $('#setupMsg');
  const icGrid = $('#icGrid');
  const msgEl = $('#msg');
  const emptyState = $('#emptyState');
  const countEl = $('#count');
  const filterSanatorio = $('#filterSanatorio');
  const filterZona = $('#filterZona');
  const filterEstado = $('#filterEstado');
  const filterDesde = $('#filterDesde');
  const filterHasta = $('#filterHasta');
  const searchInput = $('#search');

  function flash(text, isError){
    msgEl.textContent = text;
    msgEl.classList.toggle('error', !!isError);
    setTimeout(() => { if(msgEl.textContent === text) msgEl.textContent = ''; }, 4000);
  }

  function flashIn(el, text, isError){
    el.textContent = text;
    el.classList.toggle('error', !!isError);
    setTimeout(() => { if(el.textContent === text) el.textContent = ''; }, 4000);
  }

  function escapeHtml(s){
    return String(s || '').replace(/[&<>"']/g, c => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
  }

  // ---- Auth ----
  loginForm.addEventListener('submit', async (e) => {
    e.preventDefault();
    const email = $('#loginEmail').value.trim();
    const password = $('#loginPassword').value;
    const btn = $('#btnLogin');
    btn.disabled = true;
    loginMsg.textContent = '';
    loginMsg.classList.remove('error');
    const { error } = await sb.auth.signInWithPassword({ email, password });
    btn.disabled = false;
    if(error){
      loginMsg.textContent = 'No se pudo ingresar: ' + error.message;
      loginMsg.classList.add('error');
    }
  });

  setupForm.addEventListener('submit', async (e) => {
    e.preventDefault();
    const nombre = $('#setupNombre').value.trim();
    const especialidad = $('#setupEspecialidad').value.trim();
    const password = $('#setupPassword').value;
    if(!nombre){ flashIn(setupMsg, 'Ingresá tu nombre.', true); return; }
    const btn = $('#btnSetup');
    btn.disabled = true;
    if(password){
      const { error: pwErr } = await sb.auth.updateUser({ password });
      if(pwErr){ flashIn(setupMsg, 'Error al establecer la contraseña: ' + pwErr.message, true); btn.disabled = false; return; }
    }
    const { data, error } = await sb.from('medicos')
      .upsert({ id: currentUser.id, nombre, especialidad: especialidad || null, rol: setupRol, supervisor_id: setupSupervisorId, sanatorios_permitidos: setupSanatorios }, { onConflict: 'id' })
      .select().single();
    btn.disabled = false;
    if(error){ flashIn(setupMsg, 'Error al guardar el perfil: ' + error.message, true); return; }
    currentMedico = data;
    await enterApp();
  });

  function temaEfectivo(){
    const guardado = localStorage.getItem('tema');
    if(guardado === 'light' || guardado === 'dark') return guardado;
    return window.matchMedia('(prefers-color-scheme: dark)').matches ? 'dark' : 'light';
  }
  function actualizarBotonTema(){
    $('#btnTheme').textContent = temaEfectivo() === 'dark' ? '☀️ Modo claro' : '🌙 Modo oscuro';
  }
  $('#btnTheme').addEventListener('click', () => {
    const nuevo = temaEfectivo() === 'dark' ? 'light' : 'dark';
    localStorage.setItem('tema', nuevo);
    document.documentElement.setAttribute('data-theme', nuevo);
    actualizarBotonTema();
  });
  actualizarBotonTema();

  $('#btnLogout').addEventListener('click', async () => {
    await sb.auth.signOut();
  });

  $('#btnNotif').addEventListener('click', activarNotificaciones);

  sb.auth.onAuthStateChange((event, session) => {
    // "INITIAL_SESSION" es el primer evento que dispara la librería, garantizado
    // recién después de terminar de resolver la sesión (incluyendo un token de
    // invitación/magic link que venga en la URL) — evita la carrera de usar
    // getSession() a mano, que puede devolver una sesión vieja del navegador
    // antes de que la libería termine de procesar el link recién clickeado.
    if(event === 'INITIAL_SESSION'){
      if(session){ currentUser = session.user; checkProfileAndEnter(); } else showLogin();
      return;
    }
    if(event === 'SIGNED_IN'){ currentUser = session.user; checkProfileAndEnter(); }
    if(event === 'SIGNED_OUT'){ showLogin(); }
  });

  function showLogin(){
    loginScreen.style.display = 'flex';
    setupScreen.style.display = 'none';
    appScreen.style.display = 'none';
    $('#loginPassword').value = '';
  }

  let setupRol = 'medico';
  let setupSupervisorId = null;
  let setupSanatorios = null;

  function showSetup(prefill){
    loginScreen.style.display = 'none';
    setupScreen.style.display = 'flex';
    appScreen.style.display = 'none';
    setupRol = 'medico';
    setupSupervisorId = null;
    setupSanatorios = null;
    if(prefill){
      $('#setupNombre').value = prefill.nombre || '';
      $('#setupEspecialidad').value = prefill.especialidad || '';
      if(prefill.rol === 'residente'){
        setupRol = 'residente';
        setupSupervisorId = prefill.supervisor_id || null;
        setupSanatorios = Array.isArray(prefill.sanatorios_permitidos) && prefill.sanatorios_permitidos.length > 0
          ? prefill.sanatorios_permitidos : null;
      }
    }
  }

  async function checkProfileAndEnter(){
    const { data, error } = await sb.from('medicos').select('*').eq('id', currentUser.id).maybeSingle();
    if(error){ flashIn(loginMsg, 'Error al verificar el perfil: ' + error.message, true); return; }
    if(!data){
      const meta = currentUser.user_metadata || {};
      showSetup({ nombre: meta.nombre || '', especialidad: meta.especialidad || '', rol: meta.rol || 'medico', supervisor_id: meta.supervisor_id || null, sanatorios_permitidos: meta.sanatorios_permitidos || null });
      return;
    }
    currentMedico = data;
    await enterApp();
  }

  async function enterApp(){
    loginScreen.style.display = 'none';
    setupScreen.style.display = 'none';
    appScreen.style.display = 'block';
    $('#userchip').innerHTML = `<b>${escapeHtml(currentMedico.nombre)}</b>${currentMedico.especialidad ? ' · ' + escapeHtml(currentMedico.especialidad) : ''}${currentMedico.rol === 'residente' ? ' · Residente' : ''}`;
    const panelSanatoriosAdmin = $('#panelSanatoriosAdmin');
    if(panelSanatoriosAdmin) panelSanatoriosAdmin.style.display = currentMedico.es_admin ? '' : 'none';
    aplicarRestriccionesRol();
    await loadAll();
    await checkGoogleCalendarStatus();
    handleGoogleCalendarRedirect();
  }

  function aplicarRestriccionesRol(){
    if(currentMedico.rol !== 'residente') return;
    ['viewInterconsultas', 'viewConsultorio'].forEach(id => {
      const tab = document.querySelector(`.navtab[data-view="${id}"]`);
      if(tab) tab.style.display = 'none';
    });
    const panelMedicos = $('#panelMedicos');
    if(panelMedicos) panelMedicos.style.display = 'none';
    const copagoDetails = $('#copagoDetails');
    if(copagoDetails) copagoDetails.style.display = 'none';
    const activeTab = document.querySelector('.navtab.active');
    if(activeTab && activeTab.style.display === 'none'){
      document.querySelector('.navtab[data-view="viewResumen"]').click();
    }
  }

  // ---- Google Calendar ----
  async function checkGoogleCalendarStatus(){
    const { data } = await sb.from('medico_calendar_tokens').select('connected_at').eq('medico_id', currentUser.id).maybeSingle();
    const btn = $('#btnGoogleCal');
    if(data){
      btn.textContent = '📅 Google Calendar conectado ✓';
      btn.disabled = true;
    } else {
      btn.textContent = '📅 Conectar Google Calendar';
      btn.disabled = false;
    }
  }

  $('#btnGoogleCal').addEventListener('click', () => {
    const params = new URLSearchParams({
      client_id: GOOGLE_CLIENT_ID,
      redirect_uri: GOOGLE_OAUTH_REDIRECT,
      response_type: 'code',
      scope: 'https://www.googleapis.com/auth/calendar.events',
      access_type: 'offline',
      prompt: 'consent',
      state: currentUser.id
    });
    window.location.href = 'https://accounts.google.com/o/oauth2/v2/auth?' + params.toString();
  });

  function handleGoogleCalendarRedirect(){
    const params = new URLSearchParams(window.location.search);
    const calendar = params.get('calendar');
    if(!calendar) return;
    if(calendar === 'connected'){
      flash('Google Calendar conectado correctamente.');
      checkGoogleCalendarStatus();
    } else {
      flash('No se pudo conectar Google Calendar. Probá de nuevo.', true);
    }
    params.delete('calendar');
    const qs = params.toString();
    history.replaceState(null, '', window.location.pathname + (qs ? '?' + qs : ''));
  }

  // Encadena las sincronizaciones una atrás de la otra — si dos campos que
  // disparan sync (ej: fecha_qx y hora_qx) se guardan casi juntos, la segunda
  // tiene que esperar a que la primera ya haya escrito el event id en la DB;
  // si corrieran en paralelo, las dos verían "no hay evento todavía" y cada
  // una crearía uno nuevo en vez de que la segunda actualice el de la primera.
  let calendarSyncQueue = Promise.resolve();
  function syncCalendarEvent(pacienteId){
    calendarSyncQueue = calendarSyncQueue.then(async () => {
      const { error } = await sb.functions.invoke('sync-calendar-event', { body: { paciente_id: pacienteId } });
      if(error) flashIn($('#pacMsg'), 'No se pudo sincronizar con Google Calendar: ' + (await mensajeErrorFuncion(error)), true);
    }).catch(() => {});
    return calendarSyncQueue;
  }

  // sb.functions.invoke() no expone el mensaje real cuando la función responde
  // con un status distinto de 2xx (solo dice "Edge Function returned a non-2xx
  // status code") — el mensaje real (ej: "email rate limit exceeded", "no
  // tenés permiso...") queda en el Response crudo dentro de error.context.
  async function mensajeErrorFuncion(error){
    try {
      const body = await error.context.json();
      if(body && body.error) return body.error;
    } catch(_e){}
    return error.message;
  }

  async function loadAll(){
    const [itemsRes, contactsRes, zonasRes, sanatoriosRes, medicosRes, pacientesRes, internacionesRes, consultasRes, preciosRes, capturasRes, preciosIcRes, icFacturablesRes] = await Promise.all([
      sb.from('interconsultas').select('*').order('created_at', { ascending: false }),
      sb.from('contactos').select('*').order('created_at', { ascending: true }),
      sb.from('zonas').select('*').order('created_at', { ascending: true }),
      sb.from('sanatorios').select('*').order('nombre', { ascending: true }),
      sb.from('medicos').select('*').order('nombre', { ascending: true }),
      sb.from('pacientes').select('*').order('nombre', { ascending: true }),
      sb.from('internaciones').select('*').order('fecha_ingreso', { ascending: false }),
      sb.from('consultas').select('*').order('fecha', { ascending: false }),
      sb.from('precios_consulta').select('*'),
      sb.from('interconsultas_capturas_pendientes').select('*').order('created_at', { ascending: false }),
      sb.from('precios_interconsulta').select('*'),
      sb.from('interconsultas_facturables').select('*').order('fecha', { ascending: false })
    ]);
    if(itemsRes.error) flash('Error al cargar interconsultas: ' + itemsRes.error.message, true);
    if(contactsRes.error) flash('Error al cargar contactos: ' + contactsRes.error.message, true);
    if(zonasRes.error) flash('Error al cargar zonas: ' + zonasRes.error.message, true);
    items = (itemsRes.data || []).map(mapRowToItem);
    contacts = (contactsRes.data || []).map(c => ({ id: c.id, contacto: c.contacto, sanatorio: c.sanatorio }));
    zonas = (zonasRes.data || []).map(z => ({ id: z.id, sanatorio: z.sanatorio, zona: z.zona }));
    sanatoriosRef = (sanatoriosRes.data || []);
    medicos = (medicosRes.data || []);
    pacientes = (pacientesRes.data || []);
    internaciones = (internacionesRes.data || []);
    consultas = (consultasRes.data || []);
    preciosConsulta = (preciosRes.data || []);
    capturasPendientes = (capturasRes.data || []);
    preciosInterconsulta = (preciosIcRes.data || []);
    interconsultasFacturables = (icFacturablesRes.data || []);
    renderCapturasPendientes();
    renderPreciosIc();
    renderIcFacturables();
    renderSanatoriosAdmin();
    renderMedicos();
    render();
    renderPacientes();
    renderCalendar();
    renderInternados();
    renderResumen();
    renderConsultas();
    renderPreciosConsulta();
    $('#intFechaIngreso').value = toISODate(new Date());
    $('#consFecha').value = toISODate(new Date());
  }


  // ---- Nav ----
  document.querySelectorAll('.navtab').forEach(btn => {
    btn.addEventListener('click', () => {
      document.querySelectorAll('.navtab').forEach(b => b.classList.toggle('active', b === btn));
      document.querySelectorAll('.view').forEach(v => v.classList.toggle('active', v.id === btn.dataset.view));
    });
  });

  // ---- Médicos / invitación ----
  function renderMedicos(){
    const list = $('#medicosList');
    const esMedico = currentMedico && currentMedico.rol === 'medico';
    list.innerHTML = medicos.length === 0
      ? '<li style="color:var(--muted); justify-content:center">Sin médicos cargados.</li>'
      : medicos.map(m => `
        <li>
          <span>${escapeHtml(m.nombre)}</span>
          ${m.especialidad ? `<span class="arrow">·</span><span class="sanat">${escapeHtml(m.especialidad)}</span>` : ''}
          ${m.id === currentUser.id
            ? '<span class="msg" style="margin:0; margin-left:auto">(vos)</span>'
            : esMedico
              ? `<select class="rolSelect" data-id="${m.id}" style="margin-left:auto; font-size:12px; padding:4px 8px">
                  <option value="medico" ${m.rol !== 'residente' ? 'selected' : ''}>Médico</option>
                  <option value="residente" ${m.rol === 'residente' ? 'selected' : ''}>Residente</option>
                </select>
                ${m.rol === 'residente' ? `<div class="sanDropdown">
                  <button type="button" class="secondary sanDropdownBtn sanatoriosBtn" data-id="${m.id}">${escapeHtml(sanatorioResumenTexto(m.sanatorios_permitidos))} ▾</button>
                  <div class="sanDropdownPanel sanatoriosPanel" data-id="${m.id}">${sanatorioCheckboxesHtml(m.sanatorios_permitidos)}</div>
                </div>` : ''}
                <span class="del" data-action="deleteMedico" data-id="${m.id}" title="Borrar">✕</span>`
              : `<span class="msg" style="margin:0; margin-left:auto">${m.rol === 'residente' ? 'Residente' : ''}</span>`
          }
        </li>
      `).join('');
  }

  // "__todos__" = sin restricción (sanatorios_permitidos = null). Cualquier
  // otra combinación de checkboxes marcados = restringido a esos nombres.
  function sanatorioCheckboxesHtml(seleccionados){
    const nombres = sanatoriosRef.map(s => s.nombre).sort((a,b) => a.localeCompare(b));
    const esTodos = !seleccionados;
    return `<label class="todosOpt"><input type="checkbox" value="__todos__" ${esTodos ? 'checked' : ''}> Todos los sanatorios</label>`
      + nombres.map(n => `<label><input type="checkbox" value="${escapeHtml(n)}" ${!esTodos && seleccionados.includes(n) ? 'checked' : ''}> ${escapeHtml(n)}</label>`).join('');
  }

  function sanatorioResumenTexto(seleccionados){
    if(!seleccionados) return 'Todos los sanatorios';
    return seleccionados.length === 1 ? seleccionados[0] : `${seleccionados.length} sanatorios`;
  }

  // Mantiene "Todos" y sanatorios puntuales mutuamente excluyentes dentro de
  // un mismo panel de checkboxes: si se marca uno, se desmarca el otro grupo.
  function normalizarSeleccionSanatorios(panel, huboClickEnTodos){
    const boxes = Array.from(panel.querySelectorAll('input[type="checkbox"]'));
    const todosBox = boxes.find(b => b.value === '__todos__');
    if(huboClickEnTodos && todosBox.checked){
      boxes.forEach(b => { if(b !== todosBox) b.checked = false; });
    } else if(boxes.some(b => b !== todosBox && b.checked)){
      todosBox.checked = false;
    } else {
      todosBox.checked = true;
    }
  }

  function sanatoriosSeleccionados(panel){
    const marcados = Array.from(panel.querySelectorAll('input[type="checkbox"]:checked')).map(b => b.value).filter(v => v !== '__todos__');
    return marcados.length === 0 ? null : marcados;
  }

  function cerrarDropdownsSanatorios(exceptPanel){
    document.querySelectorAll('.sanDropdownPanel.open').forEach(p => { if(p !== exceptPanel) p.classList.remove('open'); });
  }
  document.addEventListener('click', (e) => {
    if(!e.target.closest('.sanDropdown')) cerrarDropdownsSanatorios(null);
  });

  $('#medicosList').addEventListener('change', async (e) => {
    const rolSel = e.target.closest('.rolSelect');
    if(rolSel){
      const nuevoRol = rolSel.value;
      const patch = { rol: nuevoRol, supervisor_id: nuevoRol === 'residente' ? currentUser.id : null, sanatorios_permitidos: null };
      const { error } = await sb.from('medicos').update(patch).eq('id', rolSel.dataset.id);
      if(error){ flash('Error al actualizar el rol: ' + error.message, true); return; }
      const m = medicos.find(x => x.id === rolSel.dataset.id);
      if(m) Object.assign(m, patch);
      flash(nuevoRol === 'residente' ? 'Ahora ve solo tus pacientes, agenda y resumen.' : 'Ahora tiene acceso completo.');
      renderMedicos();
      return;
    }
    const sanBox = e.target.closest('.sanatoriosPanel input[type="checkbox"]');
    if(sanBox){
      const panel = sanBox.closest('.sanatoriosPanel');
      normalizarSeleccionSanatorios(panel, sanBox.value === '__todos__');
      const sanatorios_permitidos = sanatoriosSeleccionados(panel);
      const { error } = await sb.from('medicos').update({ sanatorios_permitidos }).eq('id', panel.dataset.id);
      if(error){ flash('Error al actualizar los sanatorios: ' + error.message, true); return; }
      const m = medicos.find(x => x.id === panel.dataset.id);
      if(m) m.sanatorios_permitidos = sanatorios_permitidos;
      const btn = document.querySelector(`.sanatoriosBtn[data-id="${panel.dataset.id}"]`);
      if(btn) btn.textContent = sanatorioResumenTexto(sanatorios_permitidos) + ' ▾';
      flash(sanatorios_permitidos ? `Restringido a: ${sanatorios_permitidos.join(', ')}.` : 'Ahora ve todos los sanatorios.');
    }
  });

  $('#medicosList').addEventListener('click', (e) => {
    const btn = e.target.closest('.sanatoriosBtn');
    if(!btn) return;
    const panel = document.querySelector(`.sanatoriosPanel[data-id="${btn.dataset.id}"]`);
    if(!panel) return;
    const abierto = panel.classList.contains('open');
    cerrarDropdownsSanatorios(null);
    panel.classList.toggle('open', !abierto);
  });

  $('#medicosList').addEventListener('click', async (e) => {
    const del = e.target.closest('[data-action="deleteMedico"]');
    if(!del) return;
    const m = medicos.find(x => x.id === del.dataset.id);
    if(!m) return;

    const pacientesCount = pacientes.filter(p => p.medico_id === m.id).length;
    const internacionesCount = internaciones.filter(i => i.medico_id === m.id).length;
    const consultasCount = consultas.filter(c => c.medico_id === m.id).length;
    let msg = `¿Borrar a ${m.nombre}? Pierde el acceso a la cuenta de inmediato.`;
    if(pacientesCount || internacionesCount || consultasCount){
      msg += ` ADEMÁS se borran TODOS sus datos propios: ${pacientesCount} paciente(s), ${internacionesCount} internación(es), ${consultasCount} consulta(s) de Consultorio. Esta acción no se puede deshacer.`;
    } else {
      msg += ` No tiene pacientes, internaciones ni consultas propias asociadas. Esta acción no se puede deshacer.`;
    }
    if(!confirm(msg)) return;

    del.textContent = '…';
    const { data, error } = await sb.functions.invoke('delete-medico', { body: { medico_id: m.id } });
    if(error){ flash('Error al borrar: ' + (await mensajeErrorFuncion(error)), true); renderMedicos(); return; }
    if(data && data.error){ flash('Error al borrar: ' + data.error, true); renderMedicos(); return; }
    medicos = medicos.filter(x => x.id !== m.id);
    pacientes = pacientes.filter(p => p.medico_id !== m.id);
    internaciones = internaciones.filter(i => i.medico_id !== m.id);
    consultas = consultas.filter(c => c.medico_id !== m.id);
    renderMedicos();
    renderPacientes();
    renderCalendar();
    renderInternados();
    renderConsultas();
    render();
    flash(data && data.warning ? data.warning : `${m.nombre} fue borrado.`, !!(data && data.warning));
  });

  function actualizarVisibilidadInviteSanatorios(){
    const rol = $('#inviteRol').value;
    const wrap = $('#inviteSanatoriosDropdown');
    const panel = $('#inviteSanatoriosPanel');
    wrap.style.display = rol === 'residente' ? '' : 'none';
    if(rol === 'residente'){
      // Se re-arma cada vez (no solo la primera vez) para reflejar sanatorios
      // agregados después de que el formulario ya estaba abierto/usado antes,
      // preservando lo que ya estuviera tildado.
      const actual = sanatoriosSeleccionados(panel);
      panel.innerHTML = sanatorioCheckboxesHtml(actual);
      $('#inviteSanatoriosBtn').textContent = sanatorioResumenTexto(actual) + ' ▾';
    }
  }
  $('#inviteRol').addEventListener('change', actualizarVisibilidadInviteSanatorios);
  $('#inviteSanatoriosBtn').addEventListener('click', (e) => {
    e.stopPropagation();
    const panel = $('#inviteSanatoriosPanel');
    const abierto = panel.classList.contains('open');
    cerrarDropdownsSanatorios(null);
    panel.classList.toggle('open', !abierto);
  });
  $('#inviteSanatoriosPanel').addEventListener('change', (e) => {
    const box = e.target.closest('input[type="checkbox"]');
    if(!box) return;
    const panel = $('#inviteSanatoriosPanel');
    normalizarSeleccionSanatorios(panel, box.value === '__todos__');
    $('#inviteSanatoriosBtn').textContent = sanatorioResumenTexto(sanatoriosSeleccionados(panel)) + ' ▾';
  });

  $('#btnInvite').addEventListener('click', async () => {
    const email = $('#inviteEmail').value.trim();
    const nombre = $('#inviteNombre').value.trim();
    const especialidad = $('#inviteEspecialidad').value.trim();
    const rol = $('#inviteRol').value;
    const sanatorios = rol === 'residente' ? sanatoriosSeleccionados($('#inviteSanatoriosPanel')) : null;
    if(!email || !nombre){ flashIn($('#inviteMsg'), 'Completá el email y el nombre.', true); return; }
    const btn = $('#btnInvite');
    btn.disabled = true;
    const { data, error } = await sb.functions.invoke('invite-medico', { body: { email, nombre, especialidad, rol, sanatorios } });
    btn.disabled = false;
    if(error){ flashIn($('#inviteMsg'), 'Error al invitar: ' + (await mensajeErrorFuncion(error)), true); return; }
    if(data && data.error){ flashIn($('#inviteMsg'), 'Error al invitar: ' + data.error, true); return; }
    $('#inviteEmail').value = '';
    $('#inviteNombre').value = '';
    $('#inviteEspecialidad').value = '';
    $('#inviteRol').value = 'medico';
    actualizarVisibilidadInviteSanatorios();
    flashIn($('#inviteMsg'), `Invitación enviada a ${email} (${rol === 'residente' ? 'residente' : 'médico'}).`);
  });

  // ---- Mutations: interconsultas ----
  $('#btnProcess').addEventListener('click', async () => {
    const raw = $('#input').value;
    if(!raw.trim()){ flash('Pegá algún texto primero.'); return; }
    const parsed = splitIntoMessages(raw).map(parseMessage);
    if(parsed.length === 0){ flash('No se detectaron mensajes.'); return; }

    let working = items.slice();
    let toInsert = [], skipped = 0;
    for(const p of parsed){
      const dup = findDuplicate(p, working);
      if(dup && dup.skip){ skipped++; continue; }
      working.push(p);
      toInsert.push(p);
    }

    if(toInsert.length === 0){
      $('#input').value = '';
      flash(`Se agregaron 0 interconsulta(s)` + (skipped ? `, se omitieron ${skipped} por duplicadas/ya resueltas.` : '.'));
      return;
    }

    const rows = toInsert.map(p => ({
      fecha: p.fecha || null, sanatorio: p.sanatorio || null, zona: p.zona || null, paciente: p.paciente || null,
      habitacion: p.habitacion || null, piso: p.piso || null, cama: p.cama || null, diagnostico: p.diagnostico || null,
      estado: 'pendiente', original: p.original || null
    }));
    const { data, error } = await sb.from('interconsultas').insert(rows).select();
    if(error){ flash('Error al guardar: ' + error.message, true); return; }
    items = items.concat(data.map(mapRowToItem));
    $('#input').value = '';
    render();
    flash(`Se agregaron ${data.length} interconsulta(s)` + (skipped ? `, se omitieron ${skipped} por duplicadas/ya resueltas.` : '.'));
  });

  const manualIcOverlay = $('#manualIcOverlay');
  function abrirManualIc(){
    $('#manualIcForm').reset();
    $('#manualIcMsg').textContent = '';
    $('#manualIcFecha').value = new Date().toISOString().slice(0,10);
    manualIcOverlay.style.display = 'flex';
    setTimeout(() => $('#manualIcPaciente').focus(), 50);
  }
  function cerrarManualIc(){ manualIcOverlay.style.display = 'none'; }
  $('#btnAddManual').addEventListener('click', abrirManualIc);
  $('#btnCerrarManualIc').addEventListener('click', cerrarManualIc);
  manualIcOverlay.addEventListener('click', (e) => { if(e.target === manualIcOverlay) cerrarManualIc(); });

  $('#manualIcForm').addEventListener('submit', async (e) => {
    e.preventDefault();
    const paciente = $('#manualIcPaciente').value.trim();
    const sanatorio = $('#manualIcSanatorio').value.trim();
    const diagnostico = $('#manualIcDiagnostico').value.trim();
    const fecha = $('#manualIcFecha').value;
    const piso = $('#manualIcPiso').value.trim();
    const cama = $('#manualIcCama').value.trim();
    if(!paciente){ flashIn($('#manualIcMsg'), 'Completá el nombre y apellido.', true); return; }

    if(sanatorio) await ensureSanatorioRef(sanatorio);
    const row = {
      paciente, sanatorio: sanatorio || null, diagnostico: diagnostico || null, fecha: fecha || null,
      piso: piso || null, cama: cama || null, zona: lookupZonaForSanatorio(sanatorio) || null,
      estado: 'pendiente'
    };
    const { data, error } = await sb.from('interconsultas').insert(row).select().single();
    if(error){ flashIn($('#manualIcMsg'), 'Error al guardar: ' + error.message, true); return; }
    items.unshift(mapRowToItem(data));
    render();
    cerrarManualIc();
  });

  $('#btnClear').addEventListener('click', async () => {
    if(items.length === 0) return;
    if(confirm('¿Borrar todas las interconsultas guardadas? Esta acción no se puede deshacer.')){
      const { error } = await sb.from('interconsultas').delete().not('id', 'is', null);
      if(error){ flash('Error al borrar: ' + error.message, true); return; }
      items = [];
      render();
    }
  });

  $('#btnExport').addEventListener('click', async () => {
    const filtered = getFiltered();
    const rows = [['Fecha','Sanatorio','Zona','Paciente','Piso','Habitacion','Cama','Diagnostico','Estado','Original']];
    filtered.forEach(it => rows.push([it.fecha, it.sanatorio, it.zona, it.paciente, it.piso, it.habitacion, it.cama, it.diagnostico, it.estado, it.original]));
    const csv = rows.map(r => r.map(v => '"' + String(v||'').replace(/"/g,'""') + '"').join(',')).join('\n');
    const blob = new Blob(['﻿' + csv], {type:'text/csv;charset=utf-8;'});
    const a = document.createElement('a');
    a.href = URL.createObjectURL(blob);
    a.download = 'interconsultas.csv';
    a.click();

    // Marca como exportadas solo las resueltas (las pendientes nunca se marcan/borran automáticamente).
    // Esto arranca/renueva el plazo de 4 meses para el borrado automático en el servidor.
    const idsResueltas = filtered.filter(it => it.estado === 'resuelta').map(it => it.id);
    if(idsResueltas.length > 0){
      const nowIso = new Date().toISOString();
      const { error } = await sb.from('interconsultas').update({ exportado_at: nowIso }).in('id', idsResueltas);
      if(error){
        flash('CSV descargado, pero no se pudo registrar la fecha de exportación: ' + error.message, true);
      } else {
        items.forEach(it => { if(idsResueltas.includes(it.id)) it.exportadoAt = nowIso; });
      }
    }
  });

  searchInput.addEventListener('input', render);
  filterSanatorio.addEventListener('change', render);
  filterZona.addEventListener('change', render);
  filterEstado.addEventListener('change', render);
  filterDesde.addEventListener('change', render);
  filterHasta.addEventListener('change', render);

  function fechaDateOnly(fecha){
    const norm = normalizeDateForSort(fecha);
    const m = norm.match(/^(\d{4}-\d{2}-\d{2})/);
    return m ? m[1] : '';
  }

  function getFiltered(){
    const q = searchInput.value.trim().toLowerCase();
    const san = filterSanatorio.value;
    const zon = filterZona.value;
    const est = filterEstado.value;
    const desde = filterDesde.value;
    const hasta = filterHasta.value;
    let list = items.filter(it => {
      if(san && it.sanatorio !== san) return false;
      if(zon && it.zona !== zon) return false;
      if(est && it.estado !== est) return false;
      if(desde || hasta){
        const fd = fechaDateOnly(it.fecha);
        if(!fd) return false;
        if(desde && fd < desde) return false;
        if(hasta && fd > hasta) return false;
      }
      if(q){
        const hay = [it.paciente, it.sanatorio, it.diagnostico, it.piso, it.habitacion, it.cama, it.original].join(' ').toLowerCase();
        if(!hay.includes(q)) return false;
      }
      return true;
    });
    if(sortKey === 'default'){
      list.sort(defaultCompare);
    } else {
      list.sort((a,b) => {
        let va = a[sortKey] || '', vb = b[sortKey] || '';
        if(sortKey === 'fecha'){ va = normalizeDateForSort(va); vb = normalizeDateForSort(vb); }
        else { va = va.toLowerCase(); vb = vb.toLowerCase(); }
        if(va < vb) return sortDir === 'asc' ? -1 : 1;
        if(va > vb) return sortDir === 'asc' ? 1 : -1;
        return 0;
      });
    }
    return list;
  }

  function allSanatorioNames(){
    const fromItems = items.map(it => it.sanatorio);
    const fromContacts = contacts.map(c => c.sanatorio);
    const fromZonas = zonas.map(z => z.sanatorio);
    const fromRef = sanatoriosRef.map(s => s.nombre);
    const fromPacientes = pacientes.map(p => p.sanatorio);
    return Array.from(new Set(fromItems.concat(fromContacts, fromZonas, fromRef, fromPacientes).filter(Boolean))).sort();
  }

  function updateSanatorioOptions(){
    const current = filterSanatorio.value;
    const set = allSanatorioNames();
    filterSanatorio.innerHTML = '<option value="">Todos los sanatorios</option>' +
      set.map(s => `<option value="${escapeHtml(s)}">${escapeHtml(s)}</option>`).join('');
    if(set.includes(current)) filterSanatorio.value = current;
    const dlHtml = set.map(s => `<option value="${escapeHtml(s)}"></option>`).join('');
    $('#sanatoriosDatalist').innerHTML = dlHtml;
    $('#sanatoriosDatalist3').innerHTML = dlHtml;

    const currentAg = agFilterSanatorio.value;
    agFilterSanatorio.innerHTML = '<option value="">Todos los sanatorios</option>' +
      set.map(s => `<option value="${escapeHtml(s)}">${escapeHtml(s)}</option>`).join('');
    if(set.includes(currentAg)) agFilterSanatorio.value = currentAg;

    const currentZona = filterZona.value;
    const zonaSet = Array.from(new Set(items.map(it => it.zona).concat(zonas.map(z => z.zona)).filter(Boolean))).sort();
    filterZona.innerHTML = '<option value="">Todas las zonas</option>' +
      zonaSet.map(z => `<option value="${escapeHtml(z)}">${escapeHtml(z)}</option>`).join('');
    if(zonaSet.includes(currentZona)) filterZona.value = currentZona;
  }

  async function ensureSanatorioRef(nombre){
    if(!nombre) return;
    const exists = sanatoriosRef.some(s => normalize(s.nombre) === normalize(nombre));
    if(exists) return;
    const { data, error } = await sb.from('sanatorios').upsert({ nombre }, { onConflict: 'nombre' }).select().single();
    if(error){
      // Solo el admin puede agregar sanatorios nuevos al maestro compartido —
      // para cualquier otro médico/residente esto es un rechazo esperado de
      // RLS, no un error real: el paciente/registro igual se guarda con ese
      // nombre de sanatorio como texto libre, solo no queda en el listado
      // compartido hasta que el admin lo agregue desde "🏥 Sanatorios".
      console.warn('No se pudo registrar "' + nombre + '" en el maestro de sanatorios (posiblemente por permisos):', error.message);
      return;
    }
    if(data){
      sanatoriosRef.push(data);
      // Refresca los desplegables de sanatorio del panel de equipo (invitación
      // y por-residente) para que un sanatorio recién creado aparezca sin
      // tener que reabrir/recargar nada.
      if($('#inviteRol').value === 'residente') actualizarVisibilidadInviteSanatorios();
      renderMedicos();
    }
  }

  const CAPTURAS_BUCKET = 'interconsultas-capturas';
  const CAPTURA_ESTADO_LABEL = { pendiente: '⏳ Pendiente de procesar', procesada: '✅ Procesada', error: '⚠️ Error' };

  function renderCapturasPendientes(){
    const list = $('#capturasPendientesList');
    const visibles = capturasPendientes.filter(c => c.estado !== 'procesada');
    list.innerHTML = visibles.length === 0
      ? '<li style="color:var(--muted); justify-content:center">Sin capturas pendientes de procesar.</li>'
      : visibles.map(c => {
        const nombreArchivo = c.storage_path.split('/').pop();
        const fecha = new Date(c.created_at).toLocaleString('es-AR', {day:'2-digit', month:'2-digit', hour:'2-digit', minute:'2-digit'});
        const estadoLabel = CAPTURA_ESTADO_LABEL[c.estado] || c.estado;
        return `
        <li data-id="${c.id}">
          <span>${escapeHtml(nombreArchivo)}</span>
          <span class="arrow">·</span>
          <span class="sanat" title="${escapeHtml(c.error_mensaje || '')}">${estadoLabel} · ${fecha}</span>
          <span class="del" data-action="deleteCaptura" data-id="${c.id}" data-path="${escapeHtml(c.storage_path)}" title="Quitar de la cola">✕</span>
        </li>
      `;
      }).join('');
  }

  $('#capturaFile').addEventListener('change', async (e) => {
    const files = Array.from(e.target.files || []);
    if(files.length === 0) return;
    const msgEl = $('#capturaMsg');
    msgEl.textContent = 'Subiendo...';
    for(const file of files){
      const safeName = file.name.replace(/[^a-zA-Z0-9.\-_]/g, '_');
      const path = `${currentUser.id}/${Date.now()}_${safeName}`;
      const { error: upErr } = await sb.storage.from(CAPTURAS_BUCKET).upload(path, file);
      if(upErr){ flashIn(msgEl, 'Error al subir: ' + upErr.message, true); continue; }
      const { data, error } = await sb.from('interconsultas_capturas_pendientes')
        .insert({ medico_id: currentUser.id, storage_path: path, estado: 'pendiente' })
        .select().single();
      if(error){ flashIn(msgEl, 'Error al registrar: ' + error.message, true); continue; }
      capturasPendientes.unshift(data);
    }
    e.target.value = '';
    renderCapturasPendientes();
    flashIn(msgEl, 'Se subió, se procesa sola en segundo plano.');
  });

  $('#capturasPendientesList').addEventListener('click', async (e) => {
    const del = e.target.closest('[data-action="deleteCaptura"]');
    if(del){
      if(!confirm('¿Quitar esta captura de la cola? Si todavía no se procesó, esa interconsulta no se va a cargar.')) return;
      await sb.storage.from(CAPTURAS_BUCKET).remove([del.dataset.path]);
      const { error } = await sb.from('interconsultas_capturas_pendientes').delete().eq('id', del.dataset.id);
      if(error){ flash('Error al borrar: ' + error.message, true); return; }
      capturasPendientes = capturasPendientes.filter(c => c.id !== del.dataset.id);
      renderCapturasPendientes();
    }
  });

  function renderPreciosIc(){
    $('#valorIcList').innerHTML = preciosInterconsulta.length === 0
      ? '<li style="color:var(--muted); justify-content:center">Sin valores cargados todavía.</li>'
      : preciosInterconsulta.slice().sort((a,b) => a.sanatorio.localeCompare(b.sanatorio)).map(p => `
        <li data-id="${p.id}">
          <span>${escapeHtml(p.sanatorio)}</span>
          <span class="arrow">→</span>
          <span class="sanat">$${Number(p.valor).toFixed(2)} por interconsulta</span>
          <span class="del" data-action="deleteValorIc" data-id="${p.id}" title="Quitar">✕</span>
        </li>
      `).join('');
  }

  function lookupPrecioInterconsulta(sanatorio){
    if(!sanatorio) return null;
    const p = preciosInterconsulta.find(x => normalize(x.sanatorio) === normalize(sanatorio));
    return p ? p.valor : null;
  }

  async function registrarInterconsultaFacturable(item, tipo, valor){
    const row = {
      medico_id: currentUser.id,
      sanatorio: item.sanatorio || null,
      paciente: item.paciente || null,
      fecha: toISODate(new Date()),
      tipo,
      valor
    };
    const { data, error } = await sb.from('interconsultas_facturables').insert(row).select().single();
    if(error){ flash('Error al registrar facturación: ' + error.message, true); return; }
    interconsultasFacturables.push(data);
    renderIcFacturables();
  }

  $('#btnAddValorIc').addEventListener('click', async () => {
    const sanatorio = $('#valorIcSanatorio').value.trim();
    const valor = parseFloat($('#valorIcInput').value);
    if(!sanatorio || !valor){ flash('Completá el sanatorio y el valor.'); return; }
    const { data, error } = await sb.from('precios_interconsulta')
      .upsert({ medico_id: currentUser.id, sanatorio, valor }, { onConflict: 'medico_id,sanatorio' })
      .select().single();
    if(error){ flash('Error al vincular: ' + error.message, true); return; }
    preciosInterconsulta = preciosInterconsulta.filter(p => normalize(p.sanatorio) !== normalize(sanatorio));
    preciosInterconsulta.push(data);
    await ensureSanatorioRef(sanatorio);
    $('#valorIcSanatorio').value = ''; $('#valorIcInput').value = '';
    renderPreciosIc();
  });

  $('#valorIcList').addEventListener('click', async (e) => {
    const del = e.target.closest('[data-action="deleteValorIc"]');
    if(del){
      const { error } = await sb.from('precios_interconsulta').delete().eq('id', del.dataset.id);
      if(error){ flash('Error al borrar: ' + error.message, true); return; }
      preciosInterconsulta = preciosInterconsulta.filter(p => p.id !== del.dataset.id);
      renderPreciosIc();
    }
  });

  // ---- Panel admin-only: Sanatorios (dirección + zona + contactos, todo junto) ----
  function renderSanatoriosAdmin(){
    const grid = $('#sanatoriosAdminGrid');
    const nombres = sanatoriosRef.map(s => s.nombre).sort((a,b) => a.localeCompare(b));
    grid.innerHTML = nombres.length === 0
      ? '<div class="msg" style="text-align:center">Sin sanatorios cargados todavía.</div>'
      : nombres.map(nombre => {
        const s = sanatoriosRef.find(x => normalize(x.nombre) === normalize(nombre));
        const zonaRow = zonas.find(z => normalize(z.sanatorio) === normalize(nombre));
        const contactosSanatorio = contacts.filter(c => normalize(c.sanatorio) === normalize(nombre));
        const color = sanatorioColor(nombre) || '#64748b';
        return `
          <div class="internadosGroup">
            <div class="internadosGroupHead" style="border-left:6px solid ${color}">
              <span class="sanatorioDot" style="background:${color}"></span>
              <span class="internadosGroupTitle">${escapeHtml(nombre)}</span>
              <span class="del" data-action="deleteSanatorioAdmin" data-nombre="${escapeHtml(nombre)}" title="Borrar sanatorio" style="margin-left:auto">✕</span>
            </div>
            <div class="panel" style="margin-top:0">
              <div class="fichaGrid">
                <label>Dirección
                  <input type="text" data-field="direccion" data-id="${s.id}" value="${escapeHtml(s.direccion || '')}" placeholder="Sin cargar">
                </label>
                <label>Zona de facturación
                  <input type="text" data-field="zona" data-nombre="${escapeHtml(nombre)}" data-zona-id="${zonaRow ? zonaRow.id : ''}" value="${escapeHtml(zonaRow ? zonaRow.zona : '')}" placeholder="Sin cargar">
                </label>
              </div>
              <h3 class="subhead" style="margin-top:14px">Contactos vinculados</h3>
              <div class="msg" style="margin-top:0; margin-bottom:8px">Si un mensaje no menciona el sanatorio explícitamente, se completa según quién lo envía.</div>
              <div class="contactForm">
                <input type="text" class="nuevoContactoInput" data-nombre="${escapeHtml(nombre)}" placeholder="Nombre o número tal como figura en WhatsApp">
                <button type="button" class="secondary" data-action="addContactoAdmin" data-nombre="${escapeHtml(nombre)}">Vincular</button>
              </div>
              <ul class="contactList" style="margin-top:8px">
                ${contactosSanatorio.length === 0
                  ? '<li style="color:var(--muted); justify-content:center">Sin contactos vinculados.</li>'
                  : contactosSanatorio.map(c => `
                    <li data-id="${c.id}">
                      <span>${escapeHtml(c.contacto)}</span>
                      <span class="del" data-action="deleteContactoAdmin" data-id="${c.id}" title="Quitar">✕</span>
                    </li>
                  `).join('')}
              </ul>
            </div>
          </div>
        `;
      }).join('');
  }

  $('#btnAddSanatorioAdmin').addEventListener('click', async () => {
    const nombre = $('#nuevoSanatorioNombre').value.trim();
    if(!nombre){ flash('Ingresá el nombre del sanatorio.', true); return; }
    const { data, error } = await sb.from('sanatorios').upsert({ nombre }, { onConflict: 'nombre' }).select().single();
    if(error){ flash('Error al agregar: ' + error.message, true); return; }
    sanatoriosRef = sanatoriosRef.filter(s => normalize(s.nombre) !== normalize(nombre));
    sanatoriosRef.push(data);
    $('#nuevoSanatorioNombre').value = '';
    renderSanatoriosAdmin();
    render();
  });

  $('#sanatoriosAdminGrid').addEventListener('blur', async (e) => {
    const field = e.target.dataset.field;
    if(!field) return;
    const value = e.target.value.trim();
    if(field === 'direccion'){
      const { error } = await sb.from('sanatorios').update({ direccion: value || null }).eq('id', e.target.dataset.id);
      if(error){ flash('Error al guardar: ' + error.message, true); return; }
      const s = sanatoriosRef.find(x => x.id === e.target.dataset.id);
      if(s) s.direccion = value || null;
    } else if(field === 'zona'){
      const nombre = e.target.dataset.nombre;
      const zonaId = e.target.dataset.zonaId;
      if(!value){
        if(zonaId){
          const { error } = await sb.from('zonas').delete().eq('id', zonaId);
          if(error){ flash('Error al guardar: ' + error.message, true); return; }
          zonas = zonas.filter(z => z.id !== zonaId);
          renderSanatoriosAdmin();
        }
        return;
      }
      const { data, error } = await sb.from('zonas').upsert({ sanatorio: nombre, zona: value }, { onConflict: 'sanatorio' }).select().single();
      if(error){ flash('Error al guardar: ' + error.message, true); return; }
      zonas = zonas.filter(z => normalize(z.sanatorio) !== normalize(nombre));
      zonas.push(data);
      renderSanatoriosAdmin();
    }
  }, true);

  $('#sanatoriosAdminGrid').addEventListener('click', async (e) => {
    const addContacto = e.target.closest('[data-action="addContactoAdmin"]');
    if(addContacto){
      const nombre = addContacto.dataset.nombre;
      const input = document.querySelector(`.nuevoContactoInput[data-nombre="${CSS.escape(nombre)}"]`);
      const contacto = input.value.trim();
      if(!contacto) return;
      const { data, error } = await sb.from('contactos').insert({ contacto, sanatorio: nombre }).select().single();
      if(error){ flash('Error al vincular: ' + error.message, true); return; }
      contacts.push({ id: data.id, contacto: data.contacto, sanatorio: data.sanatorio });
      input.value = '';
      renderSanatoriosAdmin();
      return;
    }
    const delContacto = e.target.closest('[data-action="deleteContactoAdmin"]');
    if(delContacto){
      const { error } = await sb.from('contactos').delete().eq('id', delContacto.dataset.id);
      if(error){ flash('Error al borrar: ' + error.message, true); return; }
      contacts = contacts.filter(c => c.id !== delContacto.dataset.id);
      renderSanatoriosAdmin();
      return;
    }
    const delSanatorio = e.target.closest('[data-action="deleteSanatorioAdmin"]');
    if(delSanatorio){
      const nombre = delSanatorio.dataset.nombre;
      if(!confirm(`¿Borrar "${nombre}"? También se borran su dirección, zona y contactos vinculados. Esta acción no se puede deshacer.`)) return;
      const s = sanatoriosRef.find(x => normalize(x.nombre) === normalize(nombre));
      if(s){
        const { error } = await sb.from('sanatorios').delete().eq('id', s.id);
        if(error){ flash('Error al borrar: ' + error.message, true); return; }
        sanatoriosRef = sanatoriosRef.filter(x => x.id !== s.id);
      }
      const zonaRow = zonas.find(z => normalize(z.sanatorio) === normalize(nombre));
      if(zonaRow){ await sb.from('zonas').delete().eq('id', zonaRow.id); zonas = zonas.filter(z => z.id !== zonaRow.id); }
      const contactosSanatorio = contacts.filter(c => normalize(c.sanatorio) === normalize(nombre));
      for(const c of contactosSanatorio){ await sb.from('contactos').delete().eq('id', c.id); }
      contacts = contacts.filter(c => normalize(c.sanatorio) !== normalize(nombre));
      renderSanatoriosAdmin();
      render();
    }
  });

  function icCardHtml(it){
    const color = sanatorioColor(it.sanatorio) || '#64748b';
    return `<div class="internadoCard" data-id="${it.id}" style="border-left:5px solid ${color}">
      <div class="row" style="margin-top:0; justify-content:space-between; align-items:center">
        <span class="badge ${it.estado}" data-id="${it.id}" data-toggle="estado">${it.estado}</span>
        <span class="del" data-id="${it.id}" data-action="delete" title="Borrar">✕</span>
      </div>
      <div class="nombre" contenteditable="true" data-id="${it.id}" data-key="paciente" style="margin-top:6px">${escapeHtml(it.paciente)}</div>
      <div class="meta" contenteditable="true" data-id="${it.id}" data-key="sanatorio" style="font-weight:600">${escapeHtml(it.sanatorio)}</div>
      <div class="habCama">
        <span contenteditable="true" data-id="${it.id}" data-key="piso">${escapeHtml(it.piso)}</span> ·
        <span contenteditable="true" data-id="${it.id}" data-key="habitacion">${escapeHtml(it.habitacion)}</span> ·
        <span contenteditable="true" data-id="${it.id}" data-key="cama">${escapeHtml(it.cama)}</span>
      </div>
      <div class="meta" contenteditable="true" data-id="${it.id}" data-key="diagnostico">${escapeHtml(it.diagnostico)}</div>
      <div class="meta" contenteditable="true" data-id="${it.id}" data-key="fecha">${escapeHtml(it.fecha)}</div>
      <div class="meta" contenteditable="true" data-id="${it.id}" data-key="zona">${escapeHtml(it.zona)}</div>
      <div class="orig" title="${escapeHtml(it.original)}">${escapeHtml(it.original)}</div>
      <button class="secondary" data-action="programarCx" data-id="${it.id}" style="margin-top:10px; width:100%; font-size:12px; padding:7px">→ Programar Cx</button>
      <button class="success" data-action="contestada" data-id="${it.id}" style="margin-top:6px; width:100%; font-size:12px; padding:7px">✓ Contestada</button>
    </div>`;
  }

  function render(){
    updateSanatorioOptions();
    const list = getFiltered();
    countEl.textContent = `${list.length} de ${items.length} interconsulta(s)`;
    emptyState.style.display = items.length === 0 ? 'block' : 'none';

    const groups = {};
    list.forEach(it => {
      const key = it.sanatorio || 'Sin sanatorio';
      (groups[key] = groups[key] || []).push(it);
    });
    const nombres = Object.keys(groups).sort((a,b) => a.localeCompare(b));

    icGrid.innerHTML = nombres.map(nombre => {
      const color = sanatorioColor(nombre === 'Sin sanatorio' ? '' : nombre) || '#64748b';
      return `
        <div class="internadosGroup">
          <div class="internadosGroupHead" style="border-left:6px solid ${color}">
            <span class="sanatorioDot" style="background:${color}; width:12px; height:12px"></span>
            <span class="internadosGroupTitle">${escapeHtml(nombre)}</span>
            <span class="internadosGroupCount">${groups[nombre].length}</span>
          </div>
          <div class="internadosCards">${groups[nombre].map(icCardHtml).join('')}</div>
        </div>
      `;
    }).join('');

    syncBadge();
    renderResumen();
  }

  icGrid.addEventListener('blur', async (e) => {
    const el = e.target;
    if(!el.dataset || !el.dataset.key) return;
    const item = items.find(i => i.id === el.dataset.id);
    if(!item) return;
    const value = el.textContent.trim();
    if((item[el.dataset.key] || '') === value) return;
    item[el.dataset.key] = value;
    const { error } = await sb.from('interconsultas').update({ [el.dataset.key]: value || null }).eq('id', item.id);
    if(error) flash('Error al guardar: ' + error.message, true);
    if(el.dataset.key === 'sanatorio'){
      if(value) await ensureSanatorioRef(value);
      render();
    }
  }, true);

  icGrid.addEventListener('click', async (e) => {
    const prog = e.target.closest('[data-action="programarCx"]');
    if(prog){
      await programarCxDesdeInterconsulta(prog.dataset.id);
      return;
    }
    const contestada = e.target.closest('[data-action="contestada"]');
    if(contestada){
      if(!confirm('¿Marcar esta interconsulta como contestada? Se va a borrar de la lista y no se puede deshacer.')) return;
      const item = items.find(i => i.id === contestada.dataset.id);
      const valorIc = item ? lookupPrecioInterconsulta(item.sanatorio) : null;
      if(item && valorIc != null) await registrarInterconsultaFacturable(item, 'contestada', valorIc);
      const { error } = await sb.from('interconsultas').delete().eq('id', contestada.dataset.id);
      if(error){ flash('Error al borrar: ' + error.message, true); return; }
      items = items.filter(i => i.id !== contestada.dataset.id);
      render();
      return;
    }
    const badge = e.target.closest('[data-toggle="estado"]');
    if(badge){
      const item = items.find(i => i.id === badge.dataset.id);
      if(item){
        const nuevoEstado = item.estado === 'pendiente' ? 'resuelta' : 'pendiente';
        const nuevaFechaResuelta = nuevoEstado === 'resuelta' ? new Date().toISOString().slice(0,10) : null;
        const { error } = await sb.from('interconsultas')
          .update({ estado: nuevoEstado, fecha_resuelta: nuevaFechaResuelta })
          .eq('id', item.id);
        if(error){ flash('Error al guardar: ' + error.message, true); return; }
        item.estado = nuevoEstado;
        item.fechaResuelta = nuevaFechaResuelta || '';
        render();
      }
      return;
    }
    const del = e.target.closest('[data-action="delete"]');
    if(del){
      if(!confirm('¿Borrar esta interconsulta? Esta acción no se puede deshacer.')) return;
      const { error } = await sb.from('interconsultas').delete().eq('id', del.dataset.id);
      if(error){ flash('Error al borrar: ' + error.message, true); return; }
      items = items.filter(i => i.id !== del.dataset.id);
      render();
    }
  });

  async function programarCxDesdeInterconsulta(icId){
    const it = items.find(i => i.id === icId);
    if(!it) return;
    const nombreBuscado = (it.paciente || '').trim();
    if(!nombreBuscado){ flash('Esta interconsulta no tiene paciente cargado.', true); return; }

    const valorIc = lookupPrecioInterconsulta(it.sanatorio);
    let registrarYBorrar = false;
    if(valorIc != null){
      registrarYBorrar = confirm(`Esta interconsulta es de ${it.sanatorio} (valor de interconsulta: $${valorIc}). Se va a registrar para facturación y se va a borrar de la lista de interconsultas. ¿Continuar?`);
    }
    if(registrarYBorrar){
      await registrarInterconsultaFacturable(it, 'programada', valorIc);
      const { error } = await sb.from('interconsultas').delete().eq('id', it.id);
      if(!error){ items = items.filter(i => i.id !== it.id); render(); }
    }

    let paciente = pacientes.find(p => normalize(p.nombre) === normalize(nombreBuscado));
    if(!paciente){
      const row = {
        medico_id: efectivoMedicoId(),
        nombre: nombreBuscado,
        sanatorio: it.sanatorio || null,
        diagnostico: it.diagnostico || null
      };
      const { data, error } = await sb.from('pacientes').insert(row).select().single();
      if(error){ flash('Error al crear el paciente: ' + error.message, true); return; }
      paciente = data;
      pacientes.push(paciente);
      pacientes.sort((a,b) => (a.nombre||'').localeCompare(b.nombre||''));
      renderPacientes();
    }

    document.querySelector('.navtab[data-view="viewPacientes"]').click();
    openPacienteDetail(paciente.id);
    flashIn($('#pacMsg'), 'Completá la ficha. Al poner la Fecha Qx el paciente pasa a internado automáticamente.');
  }

  // ==================== PACIENTES ====================
  const STORAGE_BUCKET = 'estudios-imagenes';
  const ANTECEDENTES_LIST = [
    ['hta','HTA'], ['dbt','Diabetes'], ['dlp','Dislipemia'], ['obesidad','Obesidad'],
    ['tabaquismo','Tabaquismo actual'], ['ex_tabaquismo','Ex-tabaquismo'], ['epoc','EPOC'], ['asma','Asma'],
    ['cardiopatia','Cardiopatía isquémica'], ['arritmia','Arritmia'], ['irc','Insuf. renal crónica'], ['hipotiroidismo','Hipotiroidismo'],
    ['cancer_previo','Cáncer previo'], ['cirugia_toracica_previa','Cirugía torácica previa'], ['tvp_tep','TVP/TEP previo'], ['alergias','Alergias']
  ];
  const LAB_FIELDS = [
    ['hto','HTO'], ['hb','HB'], ['leuco','LEUCO'], ['coagulograma','COAGULOGRAMA'],
    ['urea','UREA'], ['creatinina','CREATININA'], ['na','NA'], ['k','K'], ['cl','CL'], ['otros','OTROS']
  ];

  const CONDICION_LABEL = { operado: 'Operado', programado: 'Programado', programar: 'Programar', pendiente: 'Pendiente' };

  function isPreQxCompleto(p){
    const pq = p.preqx || {};
    const lab = pq.laboratorio || {};
    const tieneLab = Object.values(lab).some(v => (v || '').toString().trim() !== '');
    const tieneRcv = !!(pq.rcv || '').toString().trim();
    return tieneLab && tieneRcv;
  }

  // ---- Pretest de nódulo pulmonar (Mayo Clinic / Herder) ----
  function diagnosticoEsNodulo(diagnostico){
    const n = normalize(diagnostico || '');
    return n.includes('nodulo') && n.includes('pulmon');
  }

  // Mayo Clinic (Swensen) — usada internamente solo como insumo del modelo de Herder cuando hay PET.
  function calcularProbabilidadMayo(p){
    const edad = parseFloat(p.edad) || 0;
    const ant = p.antecedentes || {};
    const tabaquismo = (ant.tabaquismo || ant.ex_tabaquismo) ? 1 : 0;
    const cancerPrevio = ant.cancer_previo ? 1 : 0;
    const nodulo = (p.preqx || {}).nodulo || {};
    const diametro = parseFloat(nodulo.diametro_mm) || 0;
    const espiculacion = nodulo.espiculacion ? 1 : 0;
    const loboSuperior = nodulo.lobulo_superior ? 1 : 0;
    const x = -6.8272 + 0.0391 * edad + 0.7917 * tabaquismo + 1.3388 * cancerPrevio +
      0.1274 * diametro + 1.0407 * espiculacion + 0.7838 * loboSuperior;
    return 1 / (1 + Math.exp(-x));
  }

  const HERDER_PET_COEF = { ninguna: 0, discreta: 2.322, moderada: 4.617, intensa: 4.771 };

  function calcularProbabilidadHerder(probMayo, captacion){
    const coefPet = HERDER_PET_COEF[captacion] || 0;
    const x = -4.739 + 3.691 * probMayo + coefPet;
    return 1 / (1 + Math.exp(-x));
  }

  // Brock University / PanCan (McWilliams 2013) — modelo principal.
  function calcularProbabilidadBrock(p){
    const edad = parseFloat(p.edad) || 0;
    const femenino = p.sexo === 'femenino' ? 0.6011 : 0;
    const nodulo = (p.preqx || {}).nodulo || {};
    const familiar = nodulo.antecedente_familiar ? 0.2961 : 0;
    const enfisema = nodulo.enfisema ? 0.2953 : 0;
    const espiculacion = nodulo.espiculacion ? 0.7729 : 0;
    const loboSuperior = nodulo.lobulo_superior ? 0.6581 : 0;
    let tipoCoef = 0;
    if(nodulo.tipo === 'subsolido') tipoCoef = 0.377;
    else if(nodulo.tipo === 'no_solido') tipoCoef = -0.1276;
    const diametroMm = parseFloat(nodulo.diametro_mm) || 0;
    const numeroNodulos = parseFloat(nodulo.numero_nodulos) || 1;

    const sizeTerm = Math.pow(diametroMm / 10, -0.5) - 1.58113883;
    const x = 0.0287 * (edad - 62) + femenino + familiar + enfisema -
      5.3854 * sizeTerm + tipoCoef + loboSuperior -
      0.0824 * (numeroNodulos - 4) + espiculacion - 6.7892;
    return 1 / (1 + Math.exp(-x));
  }

  function pintarPretest(pct, selNumero, selBar, selCategoria){
    $(selNumero).textContent = pct + '%';
    const fill = $(selBar);
    fill.style.width = Math.min(100, pct) + '%';
    let color, categoria;
    if(pct < 5){ color = 'var(--done)'; categoria = 'Bajo riesgo (<5%)'; }
    else if(pct <= 65){ color = 'var(--pending)'; categoria = 'Riesgo intermedio (5–65%)'; }
    else { color = 'var(--danger)'; categoria = 'Alto riesgo (>65%)'; }
    fill.style.background = color;
    const catEl = $(selCategoria);
    catEl.textContent = categoria;
    catEl.style.color = color;
  }

  function recomputePretest(){
    const p = currentPaciente();
    const section = $('#pretestNoduloSection');
    if(!section) return;
    if(!p || !diagnosticoEsNodulo(p.diagnostico)){
      section.style.display = 'none';
      return;
    }
    section.style.display = 'block';

    const nodulo = (p.preqx || {}).nodulo || {};
    $('#pqNoduloDiametro').value = nodulo.diametro_mm || '';
    $('#pqNoduloCantidad').value = nodulo.numero_nodulos || '';
    $('#pqNoduloTipo').value = nodulo.tipo || 'solido';
    $('#pqNoduloEspiculacion').checked = !!nodulo.espiculacion;
    $('#pqNoduloLoboSuperior').checked = !!nodulo.lobulo_superior;
    $('#pqNoduloEnfisema').checked = !!nodulo.enfisema;
    $('#pqNoduloFamiliar').checked = !!nodulo.antecedente_familiar;

    const diametroMm = parseFloat(nodulo.diametro_mm);
    if(!diametroMm || diametroMm <= 0){
      $('#pretestNumero').textContent = '—';
      $('#pretestBarFill').style.width = '0%';
      $('#pretestBarFill').style.background = 'var(--border)';
      $('#pretestCategoria').textContent = 'Completá el diámetro para calcular.';
      $('#pretestCategoria').style.color = '';
      $('#pretestHerderBlock').style.display = 'none';
      return;
    }

    const probBrock = calcularProbabilidadBrock(p);
    const pctBrock = Math.round(probBrock * 1000) / 10;
    pintarPretest(pctBrock, '#pretestNumero', '#pretestBarFill', '#pretestCategoria');

    const petData = ((p.preqx || {}).imagenes || {}).pet || {};
    const captacion = petData.captacion || '';
    if(captacion){
      const probMayo = calcularProbabilidadMayo(p);
      const probHerder = calcularProbabilidadHerder(probMayo, captacion);
      const pctHerder = Math.round(probHerder * 1000) / 10;
      $('#pretestHerderBlock').style.display = 'block';
      pintarPretest(pctHerder, '#pretestHerderNumero', '#pretestHerderBarFill', '#pretestHerderCategoria');
    } else {
      $('#pretestHerderBlock').style.display = 'none';
    }
  }

  function pacienteCondicion(p){
    if(p.operado) return 'operado';
    if(p.fecha_qx) return 'programado';
    if(p.materiales === 'en_quirofano') return 'programar';
    if(p.materiales === 'no_requiere') return isPreQxCompleto(p) ? 'programar' : 'pendiente';
    if(p.materiales === 'pendiente_autorizacion' || p.materiales === 'autorizados') return 'pendiente';
    return '';
  }

  function condicionBadgeHtml(p){
    const cond = pacienteCondicion(p);
    if(!cond) return '<span class="msg" style="margin:0">Sin definir</span>';
    return `<span class="badge cond-${cond}">${CONDICION_LABEL[cond]}</span>`;
  }

  function setMatSelectClass(el, value){
    el.classList.remove('mat-no_requiere', 'mat-pendiente_autorizacion', 'mat-autorizados', 'mat-en_quirofano');
    if(value) el.classList.add('mat-' + value);
  }

  function updateFechaQxLock(materiales){
    const listo = materiales === 'en_quirofano' || materiales === 'no_requiere';
    $('#pdFechaQx').disabled = !listo;
    $('#pdHoraQx').disabled = !listo;
    $('#fechaQxLockMsg').style.display = listo ? 'none' : 'block';
  }

  const pacListView = $('#pacListView');
  const pacDetailView = $('#pacDetailView');
  const pacTbody = $('#pacTbody');
  const pacEmpty = $('#pacEmpty');
  const pacCount = $('#pacCount');
  const pacSearch = $('#pacSearch');
  let currentPacienteId = null;

  function getPath(obj, path){
    return path.split('.').reduce((o,k) => (o && o[k] !== undefined) ? o[k] : undefined, obj);
  }
  function setPath(obj, path, value){
    const keys = path.split('.');
    let cur = obj;
    for(let i = 0; i < keys.length - 1; i++){
      if(typeof cur[keys[i]] !== 'object' || cur[keys[i]] === null) cur[keys[i]] = {};
      cur = cur[keys[i]];
    }
    cur[keys[keys.length - 1]] = value;
  }

  function getFilteredPacientes(){
    const q = pacSearch.value.trim().toLowerCase();
    if(!q) return pacientes;
    return pacientes.filter(p => [p.nombre, p.dni, p.telefono, p.sanatorio, p.diagnostico].join(' ').toLowerCase().includes(q));
  }

  function renderPacientes(){
    const list = getFilteredPacientes();
    pacCount.textContent = `${list.length} de ${pacientes.length} paciente(s)`;
    pacEmpty.style.display = pacientes.length === 0 ? 'block' : 'none';
    pacTbody.innerHTML = list.map(p => `
      <tr class="pacRow" data-id="${p.id}" style="border-left:4px solid ${sanatorioColor(p.sanatorio) || 'transparent'}">
        <td>${escapeHtml(p.nombre)}</td>
        <td>${sanatorioChip(p.sanatorio)}</td>
        <td>${escapeHtml(p.edad)}</td>
        <td>${escapeHtml(p.dni)}</td>
        <td>${escapeHtml(p.diagnostico)}</td>
        <td>${escapeHtml(p.fecha_qx)}</td>
        <td>${condicionBadgeHtml(p)}</td>
        <td>${currentMedico.rol === 'residente' ? '' : `<span class="del" data-id="${p.id}" data-action="deletePaciente" title="Borrar">✕</span>`}</td>
      </tr>
    `).join('');
  }

  pacSearch.addEventListener('input', renderPacientes);

  function efectivoMedicoId(){
    return currentMedico.rol === 'residente' ? currentMedico.supervisor_id : currentUser.id;
  }

  $('#btnAddPaciente').addEventListener('click', async () => {
    const nombre = $('#pacNombre').value.trim();
    if(!nombre){ flashIn($('#pacMsg'), 'El nombre es obligatorio.', true); return; }
    const sanatorio = $('#pacSanatorio').value.trim();
    const row = {
      medico_id: efectivoMedicoId(),
      nombre,
      sanatorio: sanatorio || null,
      edad: $('#pacEdad').value ? parseInt($('#pacEdad').value, 10) : null,
      dni: $('#pacDni').value.trim() || null,
      os: $('#pacOs').value.trim() || null,
      nro_afiliado: $('#pacNroAfiliado').value.trim() || null,
      telefono: $('#pacTelefono').value.trim() || null,
      diagnostico: $('#pacDiagnostico').value.trim() || null
    };
    const { data, error } = await sb.from('pacientes').insert(row).select().single();
    if(error){ flashIn($('#pacMsg'), 'Error al guardar: ' + error.message, true); return; }
    pacientes.push(data);
    pacientes.sort((a,b) => (a.nombre||'').localeCompare(b.nombre||''));
    if(sanatorio) await ensureSanatorioRef(sanatorio);
    ['pacNombre','pacSanatorio','pacEdad','pacDni','pacOs','pacNroAfiliado','pacTelefono','pacDiagnostico'].forEach(id => $('#'+id).value = '');
    renderPacientes();
    render();
    renderCalendar();
    openPacienteDetail(data.id);
  });

  pacTbody.addEventListener('click', async (e) => {
    const del = e.target.closest('[data-action="deletePaciente"]');
    if(del){
      if(!confirm('¿Borrar este paciente? Esta acción no se puede deshacer.')) return;
      const toDelete = pacientes.find(p => p.id === del.dataset.id);
      if(toDelete && toDelete.fecha_qx){
        // Limpia primero los eventos de Google Calendar (si no, quedarían huérfanos):
        // borra la fecha para que sync-calendar-event los elimine, después borra el paciente.
        await sb.from('pacientes').update({ fecha_qx: null }).eq('id', del.dataset.id);
        await syncCalendarEvent(del.dataset.id);
      }
      const { error } = await sb.from('pacientes').delete().eq('id', del.dataset.id);
      if(error){ flashIn($('#pacMsg'), 'Error al borrar: ' + error.message, true); return; }
      pacientes = pacientes.filter(p => p.id !== del.dataset.id);
      renderPacientes();
      renderCalendar();
      return;
    }
    const row = e.target.closest('.pacRow');
    if(row) openPacienteDetail(row.dataset.id);
  });

  // ---- Ficha detallada ----
  function currentPaciente(){
    return pacientes.find(p => p.id === currentPacienteId);
  }

  function openPacienteDetail(id){
    currentPacienteId = id;
    pacListView.style.display = 'none';
    pacDetailView.style.display = 'block';
    renderPacienteDetail();
  }

  // Normaliza un teléfono argentino a formato E.164 para wa.me (asume celular: 549 + código de área + número)
  function normalizePhoneAR(raw){
    let d = (raw || '').replace(/\D/g, '');
    if(!d) return '';
    if(d.startsWith('00')) d = d.slice(2);
    if(d.startsWith('54')){
      d = d.slice(2);
      if(d.startsWith('9')) d = d.slice(1);
    }
    if(d.startsWith('0')) d = d.slice(1);
    return '549' + d;
  }

  function updateWhatsappFab(telefono){
    const fab = $('#pdWhatsappFab');
    const d = normalizePhoneAR(telefono);
    if(d.length < 11){ fab.style.display = 'none'; return; }
    const esAndroid = /Android/i.test(navigator.userAgent);
    fab.href = esAndroid
      ? `intent://send?phone=${d}#Intent;scheme=whatsapp;package=com.whatsapp.w4b;S.browser_fallback_url=${encodeURIComponent('https://wa.me/' + d)};end`
      : 'https://wa.me/' + d;
    fab.style.display = 'flex';
  }

  $('#btnPacBack').addEventListener('click', () => {
    currentPacienteId = null;
    pacDetailView.style.display = 'none';
    pacListView.style.display = 'block';
    renderPacientes();
  });

  function refreshCondicionBadge(){
    const p = currentPaciente();
    if(!p) return;
    $('#pdCondicion').innerHTML = condicionBadgeHtml(p);
  }

  function renderPacienteDetail(){
    const p = currentPaciente();
    if(!p) return;

    refreshCondicionBadge();
    $('#pdNombre').value = p.nombre || '';
    $('#pdSanatorio').value = p.sanatorio || '';
    $('#pdSanatorioDot').style.background = sanatorioColor(p.sanatorio) || 'transparent';
    $('#pdEdad').value = p.edad || '';
    $('#pdSexo').value = p.sexo || '';
    $('#pdDni').value = p.dni || '';
    $('#pdOs').value = p.os || '';
    $('#pdNroAfiliado').value = p.nro_afiliado || '';
    $('#pdTelefono').value = p.telefono || '';
    updateWhatsappFab(p.telefono);
    $('#pdDiagnostico').value = p.diagnostico || '';
    $('#pdOperacion').value = p.operacion || '';
    $('#pdFechaQx').value = p.fecha_qx || '';
    $('#pdHoraQx').value = (p.hora_qx || '').slice(0,5);
    $('#pdMateriales').value = p.materiales || '';
    setMatSelectClass($('#pdMateriales'), p.materiales || '');
    updateFechaQxLock(p.materiales || '');
    $('#pdConsentimientoLink').value = p.consentimiento_link || '';
    $('#pdConsentimientoEstado').value = p.consentimiento_estado || '';
    $('#pdOperado').checked = !!p.operado;
    renderHistorialCirugias(p);
    $('#pdDatosClinicos').value = p.datos_clinicos || '';
    $('#pdNotas').value = p.notas || '';
    $('#pdCopagoMonto').value = p.copago_monto || '';
    $('#pdCopagoEstado').value = p.copago_estado || '';
    $('#pdProtocoloLink').value = p.protocolo_qx_link || '';
    $('#pdAnatPatLink').value = p.anatomia_patologica_link || '';

    const ant = p.antecedentes || {};
    $('#pdAntecedentesGrid').innerHTML = ANTECEDENTES_LIST.map(([key,label]) => `
      <label><input type="checkbox" data-ant="${key}" ${ant[key] ? 'checked' : ''}> ${escapeHtml(label)}</label>
    `).join('');
    $('#pdAntecedentesOtros').value = ant.otros || '';

    const pq = p.preqx || {};
    const labValues = getPath(pq, 'laboratorio') || {};
    $('#pqLaboratorioGrid').innerHTML = LAB_FIELDS.map(([key,label]) => `
      <label>${escapeHtml(label)}<input type="text" data-pqx="laboratorio.${key}" value="${escapeHtml(typeof labValues === 'object' ? (labValues[key] || '') : '')}"></label>
    `).join('');
    $('#pqRcv').value = getPath(pq, 'rcv') || '';
    $('#pqCvf').value = getPath(pq, 'funcional_respiratorio.espirometria.cvf') || '';
    $('#pqVef1').value = getPath(pq, 'funcional_respiratorio.espirometria.vef1') || '';
    $('#pqDlco').value = getPath(pq, 'funcional_respiratorio.dlco') || '';
    $('#pqTcLink').value = getPath(pq, 'imagenes.tc.link') || '';
    $('#pqTcUsuario').value = getPath(pq, 'imagenes.tc.usuario') || '';
    $('#pqTcPassword').value = getPath(pq, 'imagenes.tc.password') || '';
    $('#pqPetLink').value = getPath(pq, 'imagenes.pet.link') || '';
    $('#pqPetUsuario').value = getPath(pq, 'imagenes.pet.usuario') || '';
    $('#pqPetPassword').value = getPath(pq, 'imagenes.pet.password') || '';
    $('#pqPetCaptacion').value = getPath(pq, 'imagenes.pet.captacion') || '';

    renderFotos('tc');
    renderFotos('pet');
    recomputePretest();
  }

  // Crea la internación si todavía no tiene una activa (no toca nada si ya estaba
  // internado). Piso/habitación/cama quedan vacíos para completar en Internados.
  async function ensurePacienteInternado(p){
    const activa = internaciones.find(i => i.paciente_id === p.id && !i.fecha_alta);
    if(activa) return activa;
    const row = {
      medico_id: efectivoMedicoId(),
      paciente_id: p.id,
      sanatorio: p.sanatorio || null,
      fecha_ingreso: toISODate(new Date())
    };
    const { data, error } = await sb.from('internaciones').insert(row).select().single();
    if(error){ flashIn($('#pacMsg'), 'Error al registrar como internado: ' + error.message, true); return null; }
    internaciones.push(data);
    renderInternados();
    render();
    return data;
  }

  async function savePacienteField(key, value){
    const p = currentPaciente();
    if(!p) return;
    p[key] = value;
    const { error } = await sb.from('pacientes').update({ [key]: value }).eq('id', p.id);
    if(error) flashIn($('#pacMsg'), 'Error al guardar: ' + error.message, true);
    if(key === 'sanatorio'){
      $('#pdSanatorioDot').style.background = sanatorioColor(value) || 'transparent';
      if(value){ await ensureSanatorioRef(value); render(); }
    }
    if(['fecha_qx','hora_qx','sanatorio','nombre','operacion','materiales'].includes(key)) renderCalendar();
    if(['fecha_qx','hora_qx','sanatorio','nombre','operacion'].includes(key)) syncCalendarEvent(p.id);
    if(['fecha_qx','materiales'].includes(key)) refreshCondicionBadge();
    if(['edad','diagnostico','sexo'].includes(key)) recomputePretest();
    if(key === 'telefono') updateWhatsappFab(value);
    if(key === 'fecha_qx' && value && !error){
      const yaInternado = internaciones.some(i => i.paciente_id === p.id && !i.fecha_alta);
      if(!yaInternado){
        await ensurePacienteInternado(p);
        flashIn($('#pacMsg'), 'Fecha Qx guardada. El paciente ya aparece como internado — completá piso/habitación/cama en Internados.');
      }
    }
  }

  async function savePreqx(){
    const p = currentPaciente();
    if(!p) return;
    const { error } = await sb.from('pacientes').update({ preqx: p.preqx || {} }).eq('id', p.id);
    if(error) flashIn($('#pacMsg'), 'Error al guardar: ' + error.message, true);
    refreshCondicionBadge();
    recomputePretest();
  }

  async function saveAntecedentes(){
    const p = currentPaciente();
    if(!p) return;
    const { error } = await sb.from('pacientes').update({ antecedentes: p.antecedentes || {} }).eq('id', p.id);
    if(error) flashIn($('#pacMsg'), 'Error al guardar: ' + error.message, true);
    recomputePretest();
  }

  pacDetailView.addEventListener('blur', (e) => {
    const el = e.target;
    if(el.dataset.pk){
      let value = el.value;
      if(el.tagName === 'INPUT' && el.type === 'number') value = value ? parseInt(value, 10) : null;
      else value = value.trim() || null;
      savePacienteField(el.dataset.pk, value);
    } else if(el.dataset.pqx){
      const p = currentPaciente();
      if(!p) return;
      if(!p.preqx) p.preqx = {};
      setPath(p.preqx, el.dataset.pqx, el.value.trim());
      savePreqx();
    } else if(el.id === 'pdAntecedentesOtros'){
      const p = currentPaciente();
      if(!p) return;
      if(!p.antecedentes) p.antecedentes = {};
      p.antecedentes.otros = el.value.trim();
      saveAntecedentes();
    }
  }, true);

  pacDetailView.addEventListener('change', (e) => {
    const el = e.target;
    if(el.tagName === 'SELECT' && el.dataset.pk){
      const value = el.value || null;
      savePacienteField(el.dataset.pk, value);
      if(el.classList.contains('matSelect')){ setMatSelectClass(el, value || ''); updateFechaQxLock(value || ''); }
      return;
    }
    if(el.dataset.pqx && (el.tagName === 'SELECT' || el.type === 'checkbox')){
      const p = currentPaciente();
      if(!p) return;
      if(!p.preqx) p.preqx = {};
      const value = el.type === 'checkbox' ? el.checked : el.value;
      setPath(p.preqx, el.dataset.pqx, value);
      savePreqx();
    }
  });

  pacDetailView.addEventListener('click', (e) => {
    const btn = e.target.closest('.linkOpenBtn');
    if(!btn) return;
    const input = $('#' + btn.dataset.target);
    if(!input) return;
    let url = input.value.trim();
    if(!url) return;
    if(!/^https?:\/\//i.test(url)) url = 'https://' + url;
    window.open(url, '_blank', 'noopener');
  });

  $('#pdOperado').addEventListener('change', async (e) => {
    const p = currentPaciente();
    if(!p) return;
    const checked = e.target.checked;
    const patch = { operado: checked };
    if(checked) patch.fecha_qx = toISODate(new Date());
    Object.assign(p, patch);
    const { error } = await sb.from('pacientes').update(patch).eq('id', p.id);
    if(error){ flashIn($('#pacMsg'), 'Error al guardar: ' + error.message, true); return; }
    if(checked) $('#pdFechaQx').value = p.fecha_qx;
    refreshCondicionBadge();
    renderCalendar();
    syncCalendarEvent(p.id);
    if(checked) irAInternadosParaIngreso(p);
  });

  function irAInternadosParaIngreso(p){
    const activa = internaciones.find(i => i.paciente_id === p.id && !i.fecha_alta);
    document.querySelector('.navtab[data-view="viewInternados"]').click();
    if(activa){
      openEvolucion(activa.id);
      flashIn($('#evolucionLocMsg'), 'Post-operatorio: actualizá el piso/cama (ej: pasa a UTI).');
      setTimeout(() => { const el = $('#evolSector'); if(el){ el.focus(); el.select(); } }, 150);
      return;
    }
    $('#intPaciente').value = p.nombre || '';
    $('#intSanatorio').value = p.sanatorio || '';
    $('#intFechaIngreso').value = toISODate(new Date());
    flashIn($('#intMsg'), 'Completá piso/habitación y cama para registrar el ingreso.');
    setTimeout(() => { const el = $('#intSector'); if(el) el.focus(); }, 150);
  }

  function renderHistorialCirugias(p){
    const el = $('#historialCirugias');
    const hist = p.cirugias || [];
    if(hist.length === 0){ el.innerHTML = ''; return; }
    el.innerHTML = `
      <details style="margin-top:10px">
        <summary style="font-size:12px; color:var(--muted); cursor:pointer">Historial de cirugías anteriores (${hist.length})</summary>
        <div class="fichaGrid" style="margin-top:10px">
          ${hist.slice().reverse().map(c => `
            <label class="fieldFull">${escapeHtml(c.fecha_qx || 'Sin fecha')}${c.hora_qx ? ' · ' + escapeHtml(c.hora_qx.slice(0,5)) : ''}
              <span style="font-size:13px; color:var(--text)">${escapeHtml(c.operacion || 'Sin descripción')}${c.operado ? ' · Operado' : ''}</span>
            </label>
          `).join('')}
        </div>
      </details>
    `;
  }

  $('#btnReprogramarCx').addEventListener('click', () => {
    const p = currentPaciente();
    if(!p) return;
    const fecha = $('#pdFechaQx');
    fecha.scrollIntoView({ behavior:'smooth', block:'center' });
    fecha.focus();
    if(typeof fecha.showPicker === 'function'){
      try { fecha.showPicker(); } catch(_e){}
    }
  });

  $('#btnCancelarCx').addEventListener('click', async () => {
    const p = currentPaciente();
    if(!p) return;
    const hayAlgoQueCancelar = p.fecha_qx || p.hora_qx || p.materiales || p.operado;
    if(!hayAlgoQueCancelar){ flashIn($('#pacMsg'), 'No hay ninguna cirugía programada para cancelar.', true); return; }
    if(!confirm('¿Cancelar esta cirugía? Se borra la fecha/hora de la agenda y de Google Calendar, y la condición vuelve a "Sin definir". El paciente sigue apareciendo como internado si ya lo estaba. Esta acción no se puede deshacer.')) return;

    const teniaFecha = !!p.fecha_qx;
    const patch = { fecha_qx: null, hora_qx: null, materiales: null, operado: false };
    Object.assign(p, patch);
    const { error } = await sb.from('pacientes').update(patch).eq('id', p.id);
    if(error){ flashIn($('#pacMsg'), 'Error al guardar: ' + error.message, true); return; }

    renderPacienteDetail();
    refreshCondicionBadge();
    renderCalendar();
    render();
    if(teniaFecha) await syncCalendarEvent(p.id);
    flashIn($('#pacMsg'), 'Cirugía cancelada.');
  });

  $('#btnAgregarCirugia').addEventListener('click', async () => {
    const p = currentPaciente();
    if(!p) return;
    const tieneDatos = p.operacion || p.fecha_qx || p.operado;
    if(!tieneDatos){ flashIn($('#pacMsg'), 'No hay una cirugía cargada todavía para archivar — completá los campos de Operación directamente.', true); return; }
    if(!confirm('¿Agregar una nueva cirugía? La cirugía actual se guarda en el historial y los campos de Operación quedan libres para cargar la nueva.')) return;

    const entry = {
      operacion: p.operacion || null,
      fecha_qx: p.fecha_qx || null,
      hora_qx: p.hora_qx || null,
      materiales: p.materiales || null,
      operado: !!p.operado
    };
    const teniaFecha = !!p.fecha_qx;
    const patch = {
      cirugias: (p.cirugias || []).concat([entry]),
      operacion: null,
      fecha_qx: null,
      hora_qx: null,
      materiales: null,
      operado: false
    };
    Object.assign(p, patch);
    const { error } = await sb.from('pacientes').update(patch).eq('id', p.id);
    if(error){ flashIn($('#pacMsg'), 'Error al guardar: ' + error.message, true); return; }

    renderPacienteDetail();
    refreshCondicionBadge();
    renderCalendar();
    render();
    if(teniaFecha) await syncCalendarEvent(p.id);
    flashIn($('#pacMsg'), 'Cirugía anterior guardada en el historial. Cargá los datos de la nueva.');
  });

  $('#pdAntecedentesGrid').addEventListener('change', (e) => {
    const cb = e.target.closest('[data-ant]');
    if(!cb) return;
    const p = currentPaciente();
    if(!p) return;
    if(!p.antecedentes) p.antecedentes = {};
    p.antecedentes[cb.dataset.ant] = cb.checked;
    saveAntecedentes();
  });

  async function renderFotos(tipo){
    const p = currentPaciente();
    const container = $('#pq' + (tipo === 'tc' ? 'Tc' : 'Pet') + 'Fotos');
    const fotos = (p && getPath(p.preqx || {}, `imagenes.${tipo}.fotos`)) || [];
    if(fotos.length === 0){ container.innerHTML = ''; return; }
    const htmls = await Promise.all(fotos.map(async path => {
      const { data } = await sb.storage.from(STORAGE_BUCKET).createSignedUrl(path, 3600);
      const url = data ? data.signedUrl : '';
      const delBtn = currentMedico.rol === 'residente' ? '' : `<span class="del" data-tipo="${tipo}" data-path="${escapeHtml(path)}" title="Borrar">✕</span>`;
      return `<div class="fotoThumb"><img src="${url}" loading="lazy">${delBtn}</div>`;
    }));
    container.innerHTML = htmls.join('');
  }

  async function uploadFotos(tipo, files){
    const p = currentPaciente();
    if(!p) return;
    const msgEl2 = $('#pq' + (tipo === 'tc' ? 'Tc' : 'Pet') + 'Msg');
    if(!p.preqx) p.preqx = {};
    const existing = getPath(p.preqx, `imagenes.${tipo}.fotos`) || [];
    if(existing.length + files.length > 5){
      flashIn(msgEl2, `Máximo 5 imágenes (ya hay ${existing.length}).`, true);
      return;
    }
    msgEl2.textContent = 'Subiendo...';
    const newPaths = existing.slice();
    for(const file of Array.from(files)){
      const safeName = file.name.replace(/[^a-zA-Z0-9.\-_]/g, '_');
      const path = `${efectivoMedicoId()}/${p.id}/${tipo}/${Date.now()}_${safeName}`;
      const { error } = await sb.storage.from(STORAGE_BUCKET).upload(path, file);
      if(error){ flashIn(msgEl2, 'Error al subir: ' + error.message, true); continue; }
      newPaths.push(path);
    }
    setPath(p.preqx, `imagenes.${tipo}.fotos`, newPaths);
    await savePreqx();
    msgEl2.textContent = '';
    renderFotos(tipo);
  }

  $('#pqTcFile').addEventListener('change', (e) => { if(e.target.files.length) uploadFotos('tc', e.target.files); e.target.value = ''; });
  $('#pqPetFile').addEventListener('change', (e) => { if(e.target.files.length) uploadFotos('pet', e.target.files); e.target.value = ''; });

  pacDetailView.addEventListener('click', async (e) => {
    const del = e.target.closest('.fotoThumb .del');
    if(!del) return;
    const p = currentPaciente();
    if(!p) return;
    const tipo = del.dataset.tipo, path = del.dataset.path;
    await sb.storage.from(STORAGE_BUCKET).remove([path]);
    const remaining = (getPath(p.preqx || {}, `imagenes.${tipo}.fotos`) || []).filter(x => x !== path);
    setPath(p.preqx, `imagenes.${tipo}.fotos`, remaining);
    await savePreqx();
    renderFotos(tipo);
  });

  // ==================== AGENDA (calendario quirúrgico) ====================
  const agFilterSanatorio = $('#agFilterSanatorio');
  const calContainer = $('#calContainer');
  const MATERIALES_LABEL = { no_requiere: 'No requiere', pendiente_autorizacion: 'Pendiente de autorización', autorizados: 'Autorizados', en_quirofano: 'En quirófano' };
  const DOW_LABELS = ['Lun','Mar','Mié','Jue','Vie','Sáb','Dom'];
  const MONTH_LABELS = ['enero','febrero','marzo','abril','mayo','junio','julio','agosto','septiembre','octubre','noviembre','diciembre'];
  let calView = 'month';
  let calDate = new Date();

  function toISODate(d){
    return d.getFullYear() + '-' + String(d.getMonth()+1).padStart(2,'0') + '-' + String(d.getDate()).padStart(2,'0');
  }
  function startOfWeek(d){
    const x = new Date(d);
    const day = (x.getDay() + 6) % 7;
    x.setDate(x.getDate() - day);
    x.setHours(0,0,0,0);
    return x;
  }
  function addDays(d, n){ const x = new Date(d); x.setDate(x.getDate()+n); return x; }
  function addMonths(d, n){ const x = new Date(d); x.setMonth(x.getMonth()+n); return x; }
  function sameDate(a,b){ return toISODate(a) === toISODate(b); }

  function getPacientesByFecha(){
    const map = {};
    const filterSan = agFilterSanatorio.value;
    pacientes.forEach(p => {
      if(!p.fecha_qx) return;
      if(filterSan && p.sanatorio !== filterSan) return;
      (map[p.fecha_qx] = map[p.fecha_qx] || []).push(p);
    });
    return map;
  }

  function calLabelText(){
    if(calView === 'day') return calDate.toLocaleDateString('es-AR', { weekday:'long', day:'numeric', month:'long', year:'numeric' });
    if(calView === 'week'){
      const s = startOfWeek(calDate), e = addDays(s,6);
      return `${s.getDate()} ${MONTH_LABELS[s.getMonth()].slice(0,3)} – ${e.getDate()} ${MONTH_LABELS[e.getMonth()].slice(0,3)} ${e.getFullYear()}`;
    }
    return MONTH_LABELS[calDate.getMonth()] + ' ' + calDate.getFullYear();
  }

  function eventChipHtml(p){
    const color = sanatorioColor(p.sanatorio) || '#64748b';
    const hora = p.hora_qx ? p.hora_qx.slice(0,5) + ' ' : '';
    const label = hora + p.nombre + (p.operacion ? ' — ' + p.operacion : '') + (p.sanatorio ? ' (' + p.sanatorio + ')' : '');
    return `<div class="calEventChip" data-id="${p.id}" style="background:${color}" title="${escapeHtml(label)}">${escapeHtml(hora + p.nombre)}</div>`;
  }

  function weekEventCardHtml(p){
    const color = sanatorioColor(p.sanatorio) || '#64748b';
    const hora = p.hora_qx ? p.hora_qx.slice(0,5) : '';
    return `<div class="calWeekEvent" data-id="${p.id}" style="border-left:3px solid ${color}">
      <div class="calWeekEventName">${hora ? escapeHtml(hora) + ' · ' : ''}${escapeHtml(p.nombre)}</div>
      ${p.operacion ? `<div class="calWeekEventMeta">${escapeHtml(p.operacion)}</div>` : ''}
      ${p.sanatorio ? `<div class="calWeekEventMeta">${sanatorioChip(p.sanatorio)}</div>` : ''}
    </div>`;
  }

  function renderMonthHtml(map){
    const year = calDate.getFullYear(), month = calDate.getMonth();
    const gridStart = startOfWeek(new Date(year, month, 1));
    const today = new Date();
    let html = `<div class="calMonthGrid calMonthHead">` + DOW_LABELS.map(d => `<div class="calDowLabel">${d}</div>`).join('') + `</div><div class="calMonthGrid">`;
    for(let i = 0; i < 42; i++){
      const d = addDays(gridStart, i);
      const iso = toISODate(d);
      const inMonth = d.getMonth() === month;
      const isToday = sameDate(d, today);
      const events = map[iso] || [];
      html += `<div class="calDayCell ${inMonth?'':'otherMonth'}">
        <div class="calDayNum ${isToday?'today':''}"><span class="${isToday?'today':''}">${d.getDate()}</span></div>
        ${events.slice(0,3).map(eventChipHtml).join('')}
        ${events.length > 3 ? `<div class="calMoreLabel">+${events.length-3} más</div>` : ''}
      </div>`;
    }
    html += `</div>`;
    return html;
  }

  function renderWeekHtml(map){
    const start = startOfWeek(calDate);
    const today = new Date();
    let html = `<div class="calWeekGrid">`;
    for(let i = 0; i < 7; i++){
      const d = addDays(start, i);
      const iso = toISODate(d);
      const events = map[iso] || [];
      const isToday = sameDate(d, today);
      html += `<div class="calWeekDay ${isToday?'today':''}">
        <div class="calWeekDayHead">${DOW_LABELS[i]} ${d.getDate()}</div>
        ${events.length === 0 ? '<div class="calEmptyDay">—</div>' : events.map(weekEventCardHtml).join('')}
      </div>`;
    }
    html += `</div>`;
    return html;
  }

  function renderDayHtml(map){
    const iso = toISODate(calDate);
    const events = map[iso] || [];
    if(events.length === 0) return `<div class="empty">No hay pacientes programados este día.</div>`;
    return `<div class="calDayList">` + events.map(p => `
      <div class="calDayItem" data-id="${p.id}" style="border-left:4px solid ${sanatorioColor(p.sanatorio)||'#64748b'}">
        <div class="calDayItemName">${p.hora_qx ? escapeHtml(p.hora_qx.slice(0,5)) + ' · ' : ''}${escapeHtml(p.nombre)}</div>
        <div class="calDayItemMeta">${sanatorioChip(p.sanatorio)}${p.operacion ? ' · ' + escapeHtml(p.operacion) : ''}</div>
        ${p.materiales ? `<span class="badge mat-${p.materiales}" style="margin-top:6px; display:inline-block">${MATERIALES_LABEL[p.materiales]}</span>` : ''}
      </div>
    `).join('') + `</div>`;
  }

  function renderCalendar(){
    $('#calLabel').textContent = calLabelText();
    document.querySelectorAll('.calViewBtn').forEach(b => b.classList.toggle('active', b.dataset.calview === calView));
    const map = getPacientesByFecha();
    if(calView === 'month') calContainer.innerHTML = renderMonthHtml(map);
    else if(calView === 'week') calContainer.innerHTML = renderWeekHtml(map);
    else calContainer.innerHTML = renderDayHtml(map);
    renderInternados();
  }

  function openPacienteFromAgenda(id){
    document.querySelector('.navtab[data-view="viewPacientes"]').click();
    openPacienteDetail(id);
  }

  document.querySelectorAll('.calViewBtn').forEach(b => {
    b.addEventListener('click', () => { calView = b.dataset.calview; renderCalendar(); });
  });
  $('#calPrev').addEventListener('click', () => {
    calDate = calView === 'month' ? addMonths(calDate, -1) : addDays(calDate, calView === 'week' ? -7 : -1);
    renderCalendar();
  });
  $('#calNext').addEventListener('click', () => {
    calDate = calView === 'month' ? addMonths(calDate, 1) : addDays(calDate, calView === 'week' ? 7 : 1);
    renderCalendar();
  });
  $('#calToday').addEventListener('click', () => { calDate = new Date(); renderCalendar(); });
  agFilterSanatorio.addEventListener('change', renderCalendar);

  calContainer.addEventListener('click', (e) => {
    const el = e.target.closest('[data-id]');
    if(el) openPacienteFromAgenda(el.dataset.id);
  });

  $('#btnFabAdd').addEventListener('click', () => {
    document.querySelector('.navtab[data-view="viewPacientes"]').click();
    pacDetailView.style.display = 'none';
    pacListView.style.display = 'block';
    $('#pacNombre').focus();
    $('#pacNombre').scrollIntoView({ behavior:'smooth', block:'center' });
  });

  // ==================== INTERNADOS ====================
  let internaciones = [];
  let currentInternacionId = null;
  const intFilterSanatorio = $('#intFilterSanatorio');
  const intFilterSector = $('#intFilterSector');
  const internadosGrid = $('#internadosGrid');
  const intEmpty = $('#intEmpty');
  const intCount = $('#intCount');

  function diasInternado(fechaIngreso){
    const ms = new Date(toISODate(new Date())) - new Date(fechaIngreso);
    return Math.max(0, Math.round(ms / 86400000));
  }

  function activeInternaciones(){
    return internaciones.filter(i => !i.fecha_alta);
  }

  function pacienteNombreFor(pacienteId){
    const p = pacientes.find(x => x.id === pacienteId);
    return p ? p.nombre : '';
  }
  function pacienteOsFor(pacienteId){
    const p = pacientes.find(x => x.id === pacienteId);
    return p ? p.os : '';
  }

  function getFilteredInternaciones(){
    const san = intFilterSanatorio.value;
    const sector = intFilterSector.value;
    return activeInternaciones().filter(i => {
      if(san && i.sanatorio !== san) return false;
      if(sector && i.sector !== sector) return false;
      return true;
    });
  }

  function updateInternadosFilters(){
    const active = activeInternaciones();
    const sanSet = Array.from(new Set(
      active.map(i => i.sanatorio).filter(Boolean)
    )).sort();
    const currentSan = intFilterSanatorio.value;
    intFilterSanatorio.innerHTML = '<option value="">Todos los sanatorios</option>' +
      sanSet.map(s => `<option value="${escapeHtml(s)}">${escapeHtml(s)}</option>`).join('');
    if(sanSet.includes(currentSan)) intFilterSanatorio.value = currentSan;

    const sectorSet = Array.from(new Set(active.map(i => i.sector).filter(Boolean))).sort();
    const currentSector = intFilterSector.value;
    intFilterSector.innerHTML = '<option value="">Todos los sectores</option>' +
      sectorSet.map(s => `<option value="${escapeHtml(s)}">${escapeHtml(s)}</option>`).join('');
    if(sectorSet.includes(currentSector)) intFilterSector.value = currentSector;
    $('#sectoresDatalist').innerHTML = sectorSet.map(s => `<option value="${escapeHtml(s)}"></option>`).join('');

    $('#pacientesDatalistInt').innerHTML = pacientes.map(p => `<option value="${escapeHtml(p.nombre)}"></option>`).join('');
  }

  function internadoCardHtml(i, color){
    const nombre = pacienteNombreFor(i.paciente_id);
    const os = pacienteOsFor(i.paciente_id);
    return `<div class="internadoCard" data-id="${i.id}" style="border-left:5px solid ${color}">
      <div class="habCama">${escapeHtml(i.habitacion)}${i.cama ? ' · Cama ' + escapeHtml(i.cama) : ''}</div>
      <div class="nombre">${escapeHtml(nombre)}</div>
      <div class="meta">${i.sector ? escapeHtml(i.sector) : ''}</div>
      ${os ? `<div class="meta">${escapeHtml(os)}</div>` : ''}
      <div class="dias">${diasInternado(i.fecha_ingreso)} día(s) internado</div>
    </div>`;
  }

  function renderInternados(){
    updateInternadosFilters();
    const list = getFilteredInternaciones();
    intCount.textContent = `${list.length} internado(s)`;
    intEmpty.style.display = list.length === 0 ? 'block' : 'none';

    const groups = {};
    list.forEach(i => {
      const key = i.sanatorio || 'Sin sanatorio';
      (groups[key] = groups[key] || { internados: [] }).internados.push(i);
    });
    const sanatorioNames = Object.keys(groups).sort((a,b) => a.localeCompare(b));

    internadosGrid.innerHTML = sanatorioNames.map(nombre => {
      const g = groups[nombre];
      const pacientesGrupo = g.internados.slice().sort((a,b) => {
        const sa = a.sector || '', sb = b.sector || '';
        if(sa !== sb) return sa.localeCompare(sb);
        const ha = a.habitacion || '', hb = b.habitacion || '';
        if(ha !== hb) return ha.localeCompare(hb);
        return camaNumeric(a) - camaNumeric(b);
      });
      const color = sanatorioColor(nombre === 'Sin sanatorio' ? '' : nombre) || '#64748b';
      return `
        <div class="internadosGroup">
          <div class="internadosGroupHead" style="border-left:6px solid ${color}">
            <span class="sanatorioDot" style="background:${color}; width:12px; height:12px"></span>
            <span class="internadosGroupTitle">${escapeHtml(nombre)}</span>
            <span class="internadosGroupCount">${pacientesGrupo.length}</span>
          </div>
          ${pacientesGrupo.length ? `
            <div class="resumenSubhead">Internados (${pacientesGrupo.length})</div>
            <div class="internadosCards">${pacientesGrupo.map(i => internadoCardHtml(i, color)).join('')}</div>
          ` : ''}
        </div>
      `;
    }).join('');
    renderResumen();
  }

  intFilterSanatorio.addEventListener('change', renderInternados);
  intFilterSector.addEventListener('change', renderInternados);

  $('#btnAddInternacion').addEventListener('click', async () => {
    const nombrePaciente = $('#intPaciente').value.trim();
    if(!nombrePaciente){ flashIn($('#intMsg'), 'Ingresá el nombre del paciente.', true); return; }
    const sanatorio = $('#intSanatorio').value.trim();
    const sector = $('#intSector').value.trim();
    const habitacion = $('#intHabitacion').value.trim();
    const cama = $('#intCama').value.trim();
    const fechaIngreso = $('#intFechaIngreso').value || toISODate(new Date());

    let paciente = pacientes.find(p => normalize(p.nombre) === normalize(nombrePaciente));
    if(!paciente){
      const { data, error } = await sb.from('pacientes')
        .insert({ medico_id: efectivoMedicoId(), nombre: nombrePaciente, sanatorio: sanatorio || null })
        .select().single();
      if(error){ flashIn($('#intMsg'), 'Error al crear paciente: ' + error.message, true); return; }
      paciente = data;
      pacientes.push(paciente);
      pacientes.sort((a,b) => (a.nombre||'').localeCompare(b.nombre||''));
      renderPacientes();
    }

    const row = {
      medico_id: efectivoMedicoId(),
      paciente_id: paciente.id,
      sanatorio: sanatorio || null,
      sector: sector || null,
      habitacion: habitacion || null,
      cama: cama || null,
      fecha_ingreso: fechaIngreso
    };
    const { data, error } = await sb.from('internaciones').insert(row).select().single();
    if(error){ flashIn($('#intMsg'), 'Error al ingresar: ' + error.message, true); return; }
    internaciones.push(data);
    if(sanatorio) await ensureSanatorioRef(sanatorio);
    ['intPaciente','intSanatorio','intSector','intHabitacion','intCama'].forEach(id => $('#'+id).value = '');
    $('#intFechaIngreso').value = toISODate(new Date());
    renderInternados();
    render();
  });

  function currentInternacion(){
    return internaciones.find(i => i.id === currentInternacionId);
  }

  internadosGrid.addEventListener('click', (e) => {
    const card = e.target.closest('.internadoCard');
    if(card) openEvolucion(card.dataset.id);
  });

  function renderEvolucionList(){
    const i = currentInternacion();
    if(!i) return;
    const entries = (i.evoluciones || []).slice().sort((a,b) => b.fecha.localeCompare(a.fecha));
    $('#evolucionList').innerHTML = entries.length === 0
      ? '<div class="msg" style="margin:0">Sin evoluciones cargadas todavía.</div>'
      : entries.map(e => `
        <div class="evolucionItem">
          <div class="fecha">${new Date(e.fecha).toLocaleString('es-AR', {day:'2-digit', month:'2-digit', year:'numeric', hour:'2-digit', minute:'2-digit'})}</div>
          <div class="texto">${escapeHtml(e.texto)}</div>
        </div>
      `).join('');
  }

  function openEvolucion(id){
    currentInternacionId = id;
    const i = currentInternacion();
    if(!i) return;
    $('#evolucionTitulo').textContent = pacienteNombreFor(i.paciente_id);
    $('#evolucionSub').textContent = i.sanatorio || '';
    $('#evolSector').value = i.sector || '';
    $('#evolHabitacion').value = i.habitacion || '';
    $('#evolCama').value = i.cama || '';
    $('#evolucionLocMsg').textContent = '';
    renderEvolucionList();
    $('#evolucionInput').value = '';
    $('#evolucionOverlay').style.display = 'flex';
  }

  async function saveInternacionField(key, value){
    const i = currentInternacion();
    if(!i) return;
    const newValue = value || null;
    if(i[key] === newValue) return;
    i[key] = newValue;
    const { error } = await sb.from('internaciones').update({ [key]: newValue }).eq('id', i.id);
    if(error){ flashIn($('#evolucionLocMsg'), 'Error al guardar: ' + error.message, true); return; }
    renderInternados();
  }
  $('#evolSector').addEventListener('blur', () => saveInternacionField('sector', $('#evolSector').value.trim()));
  $('#evolHabitacion').addEventListener('blur', () => saveInternacionField('habitacion', $('#evolHabitacion').value.trim()));
  $('#evolCama').addEventListener('blur', () => saveInternacionField('cama', $('#evolCama').value.trim()));

  $('#btnCerrarEvolucion').addEventListener('click', () => {
    $('#evolucionOverlay').style.display = 'none';
    currentInternacionId = null;
  });

  $('#btnAddEvolucion').addEventListener('click', async () => {
    const i = currentInternacion();
    if(!i) return;
    const texto = $('#evolucionInput').value.trim();
    if(!texto) return;
    const entry = { fecha: new Date().toISOString(), texto };
    const nuevas = (i.evoluciones || []).concat([entry]);
    const { error } = await sb.from('internaciones').update({ evoluciones: nuevas }).eq('id', i.id);
    if(error){ flashIn($('#evolucionSub'), 'Error al guardar: ' + error.message, true); return; }
    i.evoluciones = nuevas;
    $('#evolucionInput').value = '';
    renderEvolucionList();
  });

  $('#btnDarDeAlta').addEventListener('click', async () => {
    const i = currentInternacion();
    if(!i) return;
    if(!confirm('¿Dar de alta a este paciente? Va a salir de la lista de internados activos.')) return;
    const hoy = toISODate(new Date());
    const { error } = await sb.from('internaciones').update({ fecha_alta: hoy }).eq('id', i.id);
    if(error){ flashIn($('#evolucionSub'), 'Error al dar de alta: ' + error.message, true); return; }
    i.fecha_alta = hoy;
    $('#evolucionOverlay').style.display = 'none';
    currentInternacionId = null;
    renderInternados();
  });

  // ==================== RESUMEN ====================
  const resumenContainer = $('#resumenContainer');
  const resumenCount = $('#resumenCount');
  const resumenEmpty = $('#resumenEmpty');

  function resumenCirugiaCardHtml(p, color){
    const meta = [p.edad ? p.edad + ' años' : '', p.os || ''].filter(Boolean).join(' · ');
    const fechaLine = p.fecha_qx ? escapeHtml(p.fecha_qx) + (p.hora_qx ? ' · ' + escapeHtml(p.hora_qx.slice(0,5)) : '') : '';
    return `<div class="internadoCard" data-paciente-id="${p.id}" style="border-left:5px solid ${color}">
      <div class="nombre">${escapeHtml(p.nombre)}</div>
      ${meta ? `<div class="meta">${escapeHtml(meta)}</div>` : ''}
      ${p.operacion ? `<div class="meta">${escapeHtml(p.operacion)}</div>` : ''}
      ${p.diagnostico ? `<div class="meta">${escapeHtml(p.diagnostico)}</div>` : ''}
      <div style="margin-top:6px">${condicionBadgeHtml(p)}</div>
      ${fechaLine ? `<div class="dias">${fechaLine}</div>` : ''}
    </div>`;
  }

  function resumenInterconsultaCardHtml(it, color){
    return `<div class="internadoCard" data-ic-id="${it.id}" style="border-left:5px solid ${color}">
      <div class="habCama">${escapeHtml(it.habitacion)}${it.cama ? ' · Cama ' + escapeHtml(it.cama) : ''}</div>
      <div class="nombre">${escapeHtml(it.paciente)}</div>
      ${it.diagnostico ? `<div class="meta">${escapeHtml(it.diagnostico)}</div>` : ''}
      <div class="dias">${escapeHtml(it.fecha)}</div>
    </div>`;
  }

  function renderResumen(){
    const cirugias = pacientes.filter(p => pacienteCondicion(p) === 'programado');
    const internadosActivos = activeInternaciones();
    const interconsultasPend = items.filter(it => it.estado === 'pendiente');

    const sanatoriosSet = new Set();
    cirugias.forEach(p => p.sanatorio && sanatoriosSet.add(p.sanatorio));
    internadosActivos.forEach(i => i.sanatorio && sanatoriosSet.add(i.sanatorio));
    interconsultasPend.forEach(it => it.sanatorio && sanatoriosSet.add(it.sanatorio));

    const total = cirugias.length + internadosActivos.length + interconsultasPend.length;
    resumenCount.textContent = `${total} elemento(s)`;
    resumenEmpty.style.display = total === 0 ? 'block' : 'none';

    const nombres = Array.from(sanatoriosSet).sort((a,b) => a.localeCompare(b));

    resumenContainer.innerHTML = nombres.map(nombre => {
      const color = sanatorioColor(nombre) || '#64748b';
      const cGroup = cirugias.filter(p => p.sanatorio === nombre)
        .sort((a,b) => (a.fecha_qx || '').localeCompare(b.fecha_qx || ''));
      const iGroup = internadosActivos.filter(i => i.sanatorio === nombre)
        .sort((a,b) => {
          const sa = a.sector || '', sb = b.sector || '';
          if(sa !== sb) return sa.localeCompare(sb);
          const ha = a.habitacion || '', hb = b.habitacion || '';
          if(ha !== hb) return ha.localeCompare(hb);
          return camaNumeric(a) - camaNumeric(b);
        });
      const icGroup = interconsultasPend.filter(it => it.sanatorio === nombre);

      return `
        <div class="internadosGroup">
          <div class="internadosGroupHead" style="border-left:6px solid ${color}">
            <span class="sanatorioDot" style="background:${color}; width:12px; height:12px"></span>
            <span class="internadosGroupTitle">${escapeHtml(nombre)}</span>
            <span class="internadosGroupCount">${cGroup.length + iGroup.length + icGroup.length}</span>
          </div>
          ${cGroup.length ? `
            <div class="resumenSubhead">Cirugías programadas (${cGroup.length})</div>
            <div class="internadosCards">${cGroup.map(p => resumenCirugiaCardHtml(p, color)).join('')}</div>
          ` : ''}
          ${iGroup.length ? `
            <div class="resumenSubhead">Internados (${iGroup.length})</div>
            <div class="internadosCards">${iGroup.map(i => internadoCardHtml(i, color)).join('')}</div>
          ` : ''}
          ${icGroup.length ? `
            <div class="resumenSubhead">Interconsultas (${icGroup.length})</div>
            <div class="internadosCards">${icGroup.map(it => resumenInterconsultaCardHtml(it, color)).join('')}</div>
          ` : ''}
        </div>
      `;
    }).join('');
  }

  resumenContainer.addEventListener('click', (e) => {
    const cirugiaCard = e.target.closest('[data-paciente-id]');
    if(cirugiaCard){ openPacienteFromAgenda(cirugiaCard.dataset.pacienteId); return; }
    const icCard = e.target.closest('[data-ic-id]');
    if(icCard){ document.querySelector('.navtab[data-view="viewInterconsultas"]').click(); return; }
    const internadoCard = e.target.closest('.internadoCard[data-id]');
    if(internadoCard){ openEvolucion(internadoCard.dataset.id); return; }
  });

  // ==================== CONSULTORIO ====================
  let consultas = [];
  let preciosConsulta = [];
  const consultasGrid = $('#consultasGrid');
  const consEmpty = $('#consEmpty');
  const consCount = $('#consCount');
  const consFilterSanatorio = $('#consFilterSanatorio');
  const consFilterOs = $('#consFilterOs');
  const consFilterDesde = $('#consFilterDesde');
  const consFilterHasta = $('#consFilterHasta');

  function getFilteredConsultas(){
    const san = consFilterSanatorio.value;
    const os = consFilterOs.value;
    const desde = consFilterDesde.value;
    const hasta = consFilterHasta.value;
    return consultas.filter(c => {
      if(san && c.sanatorio !== san) return false;
      if(os && c.os !== os) return false;
      if(desde && c.fecha < desde) return false;
      if(hasta && c.fecha > hasta) return false;
      return true;
    });
  }

  function updateConsultorioFilters(){
    const sanSet = Array.from(new Set(
      consultas.map(c => c.sanatorio).concat(preciosConsulta.map(p => p.sanatorio)).filter(Boolean)
    )).sort();
    const currentSan = consFilterSanatorio.value;
    consFilterSanatorio.innerHTML = '<option value="">Todos los sanatorios</option>' +
      sanSet.map(s => `<option value="${escapeHtml(s)}">${escapeHtml(s)}</option>`).join('');
    if(sanSet.includes(currentSan)) consFilterSanatorio.value = currentSan;
  }

  function consultaRowHtml(c){
    const OS_OPTS = ['PAMI','OSDE','Swiss Medical','Medife','Samisalud','IOMA','Particular'];
    return `<tr data-id="${c.id}">
      <td>${escapeHtml(c.fecha)}</td>
      <td contenteditable="true" data-id="${c.id}" data-key="paciente">${escapeHtml(c.paciente)}</td>
      <td>
        <select class="consOsSelect" data-id="${c.id}">
          <option value="" ${!c.os ? 'selected' : ''}>Sin definir</option>
          ${OS_OPTS.map(os => `<option value="${os}" ${c.os === os ? 'selected' : ''}>${os}</option>`).join('')}
        </select>
      </td>
      <td contenteditable="true" data-id="${c.id}" data-key="valor">${c.valor != null ? escapeHtml(c.valor) : ''}</td>
      <td><span class="del" data-id="${c.id}" data-action="deleteConsulta" title="Borrar">✕</span></td>
    </tr>`;
  }

  function renderConsultas(){
    updateConsultorioFilters();
    const list = getFilteredConsultas();
    const total = list.reduce((s, c) => s + (parseFloat(c.valor) || 0), 0);
    consCount.textContent = `${list.length} consulta(s) · total $${total.toFixed(2)}`;
    consEmpty.style.display = consultas.length === 0 ? 'block' : 'none';

    const groups = {};
    list.forEach(c => {
      const key = c.sanatorio || 'Sin sanatorio';
      (groups[key] = groups[key] || []).push(c);
    });
    const nombres = Object.keys(groups).sort((a,b) => a.localeCompare(b));

    consultasGrid.innerHTML = nombres.map(nombre => {
      const rows = groups[nombre].slice().sort((a,b) => (a.fecha||'').localeCompare(b.fecha||''));
      const subtotal = rows.reduce((s, c) => s + (parseFloat(c.valor) || 0), 0);
      const color = sanatorioColor(nombre === 'Sin sanatorio' ? '' : nombre) || '#64748b';
      return `
        <div class="internadosGroup">
          <div class="internadosGroupHead" style="border-left:6px solid ${color}">
            <span class="sanatorioDot" style="background:${color}; width:12px; height:12px"></span>
            <span class="internadosGroupTitle">${escapeHtml(nombre)}</span>
            <span class="internadosGroupCount">${rows.length}</span>
          </div>
          <div class="panel" style="padding:0; overflow-x:auto">
            <table>
              <thead><tr><th>Fecha</th><th>Paciente</th><th>OS</th><th>Valor</th><th></th></tr></thead>
              <tbody>${rows.map(consultaRowHtml).join('')}</tbody>
            </table>
          </div>
          <div class="msg" style="text-align:right; margin-top:4px; font-weight:700">Subtotal: $${subtotal.toFixed(2)}</div>
        </div>
      `;
    }).join('');
  }

  consFilterSanatorio.addEventListener('change', renderConsultas);
  consFilterOs.addEventListener('change', renderConsultas);
  consFilterDesde.addEventListener('change', renderConsultas);
  consFilterHasta.addEventListener('change', renderConsultas);

  function lookupPrecioConsulta(sanatorio, os){
    // Un precio "único" para el sanatorio tiene prioridad sobre cualquier precio por OS específica.
    const unico = preciosConsulta.find(x => normalize(x.sanatorio) === normalize(sanatorio) && x.os === 'unico');
    if(unico) return unico.valor;
    if(!os) return null;
    const p = preciosConsulta.find(x => normalize(x.sanatorio) === normalize(sanatorio) && x.os === os);
    return p ? p.valor : null;
  }

  function maybeAutofillValor(){
    const sanatorio = $('#consSanatorio').value.trim();
    const os = $('#consOs').value;
    if(!sanatorio || $('#consValor').value) return;
    const precio = lookupPrecioConsulta(sanatorio, os);
    if(precio != null) $('#consValor').value = precio;
  }
  $('#consSanatorio').addEventListener('blur', maybeAutofillValor);
  $('#consOs').addEventListener('change', maybeAutofillValor);

  $('#btnAddConsulta').addEventListener('click', async () => {
    const fecha = $('#consFecha').value || toISODate(new Date());
    const sanatorio = $('#consSanatorio').value.trim();
    const paciente = $('#consPaciente').value.trim();
    const os = $('#consOs').value;
    const valorRaw = $('#consValor').value;
    if(!paciente){ flashIn($('#consMsg'), 'Ingresá el nombre del paciente.', true); return; }
    const row = {
      medico_id: currentUser.id,
      fecha,
      sanatorio: sanatorio || null,
      paciente,
      os: os || null,
      valor: valorRaw ? parseFloat(valorRaw) : null
    };
    const { data, error } = await sb.from('consultas').insert(row).select().single();
    if(error){ flashIn($('#consMsg'), 'Error al guardar: ' + error.message, true); return; }
    consultas.push(data);
    if(sanatorio) await ensureSanatorioRef(sanatorio);
    $('#consSanatorio').value = ''; $('#consPaciente').value = ''; $('#consOs').value = ''; $('#consValor').value = '';
    $('#consFecha').value = toISODate(new Date());
    renderConsultas();
    render();
  });

  consultasGrid.addEventListener('blur', async (e) => {
    const el = e.target;
    if(el.tagName !== 'TD' || !el.dataset.key) return;
    const c = consultas.find(x => x.id === el.dataset.id);
    if(!c) return;
    const value = el.textContent.trim();
    const newValue = el.dataset.key === 'valor' ? (value ? parseFloat(value) : null) : (value || null);
    if((c[el.dataset.key] || null) === newValue) return;
    c[el.dataset.key] = newValue;
    const { error } = await sb.from('consultas').update({ [el.dataset.key]: newValue }).eq('id', c.id);
    if(error) flashIn($('#consMsg'), 'Error al guardar: ' + error.message, true);
    renderConsultas();
  }, true);

  consultasGrid.addEventListener('change', async (e) => {
    const sel = e.target.closest('.consOsSelect');
    if(!sel) return;
    const c = consultas.find(x => x.id === sel.dataset.id);
    if(!c) return;
    const value = sel.value || null;
    c.os = value;
    const { error } = await sb.from('consultas').update({ os: value }).eq('id', c.id);
    if(error) flashIn($('#consMsg'), 'Error al guardar: ' + error.message, true);
  });

  consultasGrid.addEventListener('click', async (e) => {
    const del = e.target.closest('[data-action="deleteConsulta"]');
    if(del){
      if(!confirm('¿Borrar este registro de consulta? Esta acción no se puede deshacer.')) return;
      const { error } = await sb.from('consultas').delete().eq('id', del.dataset.id);
      if(error){ flashIn($('#consMsg'), 'Error al borrar: ' + error.message, true); return; }
      consultas = consultas.filter(c => c.id !== del.dataset.id);
      renderConsultas();
    }
  });

  $('#btnExportConsultas').addEventListener('click', () => {
    const filtered = getFilteredConsultas();
    const rows = [['Fecha','Sanatorio','Paciente','OS','Valor']];
    filtered.forEach(c => rows.push([c.fecha, c.sanatorio, c.paciente, c.os, c.valor]));
    const csv = rows.map(r => r.map(v => '"' + String(v || '').replace(/"/g,'""') + '"').join(',')).join('\n');
    const blob = new Blob(['﻿' + csv], { type: 'text/csv;charset=utf-8;' });
    const a = document.createElement('a');
    a.href = URL.createObjectURL(blob);
    a.download = 'consultorio.csv';
    a.click();
  });

  const icFacturablesGrid = $('#icFacturablesGrid');

  function icFacturableRowHtml(c){
    const tipoLabel = c.tipo === 'programada' ? 'Programada (Qx)' : 'Contestada';
    return `<tr data-id="${c.id}">
      <td>${escapeHtml(c.fecha)}</td>
      <td>${escapeHtml(c.paciente || '')}</td>
      <td>${tipoLabel}</td>
      <td>${c.valor != null ? escapeHtml(c.valor) : ''}</td>
      <td><span class="del" data-id="${c.id}" data-action="deleteIcFacturable" title="Borrar">✕</span></td>
    </tr>`;
  }

  function renderIcFacturables(){
    const list = interconsultasFacturables;
    const total = list.reduce((s, c) => s + (parseFloat(c.valor) || 0), 0);
    $('#icFactCount').textContent = `${list.length} registro(s) · total $${total.toFixed(2)}`;
    $('#icFacturablesEmpty').style.display = list.length === 0 ? 'block' : 'none';

    const groups = {};
    list.forEach(c => {
      const key = c.sanatorio || 'Sin sanatorio';
      (groups[key] = groups[key] || []).push(c);
    });
    const nombres = Object.keys(groups).sort((a,b) => a.localeCompare(b));

    icFacturablesGrid.innerHTML = nombres.map(nombre => {
      const rows = groups[nombre].slice().sort((a,b) => (a.fecha||'').localeCompare(b.fecha||''));
      const subtotal = rows.reduce((s, c) => s + (parseFloat(c.valor) || 0), 0);
      const color = sanatorioColor(nombre === 'Sin sanatorio' ? '' : nombre) || '#64748b';
      return `
        <div class="internadosGroup">
          <div class="internadosGroupHead" style="border-left:6px solid ${color}">
            <span class="sanatorioDot" style="background:${color}; width:12px; height:12px"></span>
            <span class="internadosGroupTitle">${escapeHtml(nombre)}</span>
            <span class="internadosGroupCount">${rows.length}</span>
          </div>
          <div class="panel" style="padding:0; overflow-x:auto">
            <table>
              <thead><tr><th>Fecha</th><th>Paciente</th><th>Tipo</th><th>Valor</th><th></th></tr></thead>
              <tbody>${rows.map(icFacturableRowHtml).join('')}</tbody>
            </table>
          </div>
          <div class="msg" style="text-align:right; margin-top:4px; font-weight:700">Subtotal: $${subtotal.toFixed(2)}</div>
        </div>
      `;
    }).join('');
  }

  icFacturablesGrid.addEventListener('click', async (e) => {
    const del = e.target.closest('[data-action="deleteIcFacturable"]');
    if(del){
      if(!confirm('¿Borrar este registro? Esta acción no se puede deshacer.')) return;
      const { error } = await sb.from('interconsultas_facturables').delete().eq('id', del.dataset.id);
      if(error){ flash('Error al borrar: ' + error.message, true); return; }
      interconsultasFacturables = interconsultasFacturables.filter(c => c.id !== del.dataset.id);
      renderIcFacturables();
    }
  });

  $('#btnExportIcFacturables').addEventListener('click', () => {
    const rows = [['Fecha','Sanatorio','Paciente','Tipo','Valor']];
    interconsultasFacturables.forEach(c => rows.push([c.fecha, c.sanatorio, c.paciente, c.tipo === 'programada' ? 'Programada (Qx)' : 'Contestada', c.valor]));
    const csv = rows.map(r => r.map(v => '"' + String(v || '').replace(/"/g,'""') + '"').join(',')).join('\n');
    const blob = new Blob(['﻿' + csv], { type: 'text/csv;charset=utf-8;' });
    const a = document.createElement('a');
    a.href = URL.createObjectURL(blob);
    a.download = 'interconsultas_facturables.csv';
    a.click();
  });

  function renderPreciosConsulta(){
    $('#preciosList').innerHTML = preciosConsulta.length === 0
      ? '<li style="color:var(--muted); justify-content:center">Sin precios cargados todavía.</li>'
      : preciosConsulta.slice().sort((a,b) => (a.sanatorio+a.os).localeCompare(b.sanatorio+b.os)).map(p => `
        <li data-id="${p.id}">
          <span>${escapeHtml(p.sanatorio)}</span>
          <span class="arrow">→</span>
          <span class="sanat">${p.os === 'unico' ? 'Todas las OS' : escapeHtml(p.os)}: $${Number(p.valor).toFixed(2)}</span>
          <span class="del" data-action="deletePrecio" data-id="${p.id}" title="Quitar">✕</span>
        </li>
      `).join('');
  }

  $('#btnAddPrecio').addEventListener('click', async () => {
    const sanatorio = $('#precioSanatorio').value.trim();
    const os = $('#precioOs').value;
    const valor = parseFloat($('#precioValor').value);
    if(!sanatorio || !os || !valor){ flashIn($('#consMsg'), 'Completá sanatorio, OS y valor.', true); return; }
    const { data, error } = await sb.from('precios_consulta')
      .upsert({ medico_id: currentUser.id, sanatorio, os, valor }, { onConflict: 'medico_id,sanatorio,os' })
      .select().single();
    if(error){ flashIn($('#consMsg'), 'Error al vincular: ' + error.message, true); return; }
    preciosConsulta = preciosConsulta.filter(p => !(normalize(p.sanatorio) === normalize(sanatorio) && p.os === os));
    preciosConsulta.push(data);
    if(sanatorio) await ensureSanatorioRef(sanatorio);
    $('#precioSanatorio').value = ''; $('#precioOs').value = ''; $('#precioValor').value = '';
    renderPreciosConsulta();
    render();
  });

  $('#preciosList').addEventListener('click', async (e) => {
    const del = e.target.closest('[data-action="deletePrecio"]');
    if(del){
      const { error } = await sb.from('precios_consulta').delete().eq('id', del.dataset.id);
      if(error){ flashIn($('#consMsg'), 'Error al borrar: ' + error.message, true); return; }
      preciosConsulta = preciosConsulta.filter(p => p.id !== del.dataset.id);
      renderPreciosConsulta();
    }
  });
})();
</script>
</body>
</html>

```

### 4.2 `invite-medico/index.ts` -- invita a un medico/residente por email

```typescript
// Invita a otro médico por email usando la Admin API de Supabase Auth.
// Solo puede llamarse con un JWT válido (verify_jwt=true en el deploy), es decir
// solo un médico ya logueado en la app puede invitar a otro. Claude nunca ve ni
// maneja contraseñas: el invitado recibe un email de Supabase y la define él mismo.

const SUPABASE_URL = Deno.env.get("SB_URL")!;
const SUPABASE_SECRET_KEY = Deno.env.get("SB_SECRET_KEY")!;
const APP_URL = Deno.env.get("APP_URL")!;

const CORS_HEADERS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") {
    return new Response(null, { headers: CORS_HEADERS });
  }
  if (req.method !== "POST") {
    return new Response(JSON.stringify({ error: "method not allowed" }), {
      status: 405,
      headers: { ...CORS_HEADERS, "Content-Type": "application/json" },
    });
  }

  let payload: any = {};
  try {
    payload = await req.json();
  } catch (_e) {
    return new Response(JSON.stringify({ error: "invalid JSON" }), {
      status: 400,
      headers: { ...CORS_HEADERS, "Content-Type": "application/json" },
    });
  }

  const email = String(payload.email || "").trim().toLowerCase();
  const nombre = String(payload.nombre || "").trim();
  const especialidad = String(payload.especialidad || "").trim();
  const rol = payload.rol === "residente" ? "residente" : "medico";
  // "todos" (o directamente nada) = sin restricción de sanatorio (null).
  // Un array de nombres de sanatorio = restringido a esos.
  const sanatorios: string[] | null =
    Array.isArray(payload.sanatorios) && payload.sanatorios.length > 0
      ? payload.sanatorios.map((s: unknown) => String(s)).filter(Boolean)
      : null;

  if (!email || !email.includes("@")) {
    return new Response(JSON.stringify({ error: "email inválido" }), {
      status: 400,
      headers: { ...CORS_HEADERS, "Content-Type": "application/json" },
    });
  }

  // Solo un médico (no un residente) puede invitar a otros — se valida server-side,
  // no solo ocultando el botón en la UI.
  const authHeader = req.headers.get("Authorization") || "";
  const jwt = authHeader.replace(/^Bearer\s+/i, "");
  const jwtPayload = jwt.split(".")[1];
  let callerId = "";
  try {
    callerId = JSON.parse(atob(jwtPayload.replace(/-/g, "+").replace(/_/g, "/"))).sub || "";
  } catch (_e) {
    // sigue sin callerId, se rechaza abajo si no se puede confirmar el rol
  }
  const callerRes = await fetch(
    `${SUPABASE_URL}/rest/v1/medicos?id=eq.${callerId}&select=rol`,
    { headers: { apikey: SUPABASE_SECRET_KEY, Authorization: `Bearer ${SUPABASE_SECRET_KEY}` } }
  );
  const callerRows = await callerRes.json().catch(() => []);
  const callerRol = Array.isArray(callerRows) && callerRows[0] ? callerRows[0].rol : null;
  if (callerRol !== "medico") {
    return new Response(JSON.stringify({ error: "no tenés permiso para invitar médicos" }), {
      status: 403,
      headers: { ...CORS_HEADERS, "Content-Type": "application/json" },
    });
  }

  // El rol (y, si es residente, el supervisor = quien invita) viaja en el
  // user_metadata de la invitación — el frontend lo lee al completar el
  // perfil y lo incluye recién ahí en el insert de "medicos" (la fila todavía
  // no existe en este punto, así que no hay nada que pre-crear acá).
  const inviteRes = await fetch(
    `${SUPABASE_URL}/auth/v1/invite?redirect_to=${encodeURIComponent(APP_URL)}`,
    {
      method: "POST",
      headers: {
        apikey: SUPABASE_SECRET_KEY,
        Authorization: `Bearer ${SUPABASE_SECRET_KEY}`,
        "Content-Type": "application/json",
      },
      body: JSON.stringify({
        email,
        data: {
          nombre,
          especialidad,
          rol,
          supervisor_id: rol === "residente" ? callerId : null,
          sanatorios_permitidos: rol === "residente" ? sanatorios : null,
        },
      }),
    }
  );

  const result = await inviteRes.json().catch(() => ({}));

  if (!inviteRes.ok) {
    return new Response(JSON.stringify({ error: result.msg || result.message || "no se pudo invitar" }), {
      status: inviteRes.status,
      headers: { ...CORS_HEADERS, "Content-Type": "application/json" },
    });
  }

  return new Response(JSON.stringify({ ok: true }), {
    headers: { ...CORS_HEADERS, "Content-Type": "application/json" },
  });
});

```

### 4.3 `delete-medico/index.ts` -- borra un integrante del equipo

```typescript
// Borra a un integrante del equipo (médico o residente): su fila en "medicos"
// y su usuario de Supabase Auth. La fila de medicos tiene columnas con
// ON DELETE CASCADE desde pacientes/internaciones/consultas/precios_*/etc,
// así que borrar a un médico con pacientes propios borra también todos esos
// registros — el frontend ya le muestra a quien confirma cuántos pacientes/
// internaciones/consultas tiene esa persona ANTES de llamar a esta función,
// así que acá no se vuelve a preguntar ni se valida ese conteo de nuevo.
// Solo puede llamarlo un médico (no un residente), y nadie puede borrarse a
// sí mismo por acá.

const SUPABASE_URL = Deno.env.get("SB_URL")!;
const SUPABASE_SECRET_KEY = Deno.env.get("SB_SECRET_KEY")!;

const CORS_HEADERS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

function jsonResponse(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...CORS_HEADERS, "Content-Type": "application/json" },
  });
}

function getUserIdFromJwt(authHeader: string | null): string {
  if (!authHeader) return "";
  const jwt = authHeader.replace(/^Bearer\s+/i, "");
  const jwtPayload = jwt.split(".")[1];
  if (!jwtPayload) return "";
  try {
    return JSON.parse(atob(jwtPayload.replace(/-/g, "+").replace(/_/g, "/"))).sub || "";
  } catch (_e) {
    return "";
  }
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response(null, { headers: CORS_HEADERS });
  if (req.method !== "POST") return jsonResponse({ error: "method not allowed" }, 405);

  let payload: any = {};
  try {
    payload = await req.json();
  } catch (_e) {
    return jsonResponse({ error: "invalid JSON" }, 400);
  }

  const targetId = String(payload.medico_id || "");
  if (!targetId) return jsonResponse({ error: "medico_id requerido" }, 400);

  const callerId = getUserIdFromJwt(req.headers.get("Authorization"));
  if (!callerId) return jsonResponse({ error: "no autorizado" }, 401);
  if (callerId === targetId) return jsonResponse({ error: "no podés borrarte a vos mismo" }, 400);

  const callerRes = await fetch(
    `${SUPABASE_URL}/rest/v1/medicos?id=eq.${callerId}&select=rol`,
    { headers: { apikey: SUPABASE_SECRET_KEY, Authorization: `Bearer ${SUPABASE_SECRET_KEY}` } }
  );
  const callerRows = await callerRes.json().catch(() => []);
  const callerRol = Array.isArray(callerRows) && callerRows[0] ? callerRows[0].rol : null;
  if (callerRol !== "medico") {
    return jsonResponse({ error: "no tenés permiso para borrar médicos" }, 403);
  }

  const delRowRes = await fetch(`${SUPABASE_URL}/rest/v1/medicos?id=eq.${targetId}`, {
    method: "DELETE",
    headers: { apikey: SUPABASE_SECRET_KEY, Authorization: `Bearer ${SUPABASE_SECRET_KEY}` },
  });
  if (!delRowRes.ok) {
    const errBody = await delRowRes.json().catch(() => ({}));
    return jsonResponse({ error: errBody.message || "no se pudo borrar el registro" }, 500);
  }

  const delUserRes = await fetch(`${SUPABASE_URL}/auth/v1/admin/users/${targetId}`, {
    method: "DELETE",
    headers: { apikey: SUPABASE_SECRET_KEY, Authorization: `Bearer ${SUPABASE_SECRET_KEY}` },
  });
  if (!delUserRes.ok) {
    const errBody = await delUserRes.json().catch(() => ({}));
    return jsonResponse({
      ok: true,
      warning: "Se borró el perfil y sus datos, pero no el usuario de acceso: " + (errBody.msg || errBody.message || ""),
    });
  }

  return jsonResponse({ ok: true });
});

```

### 4.4 `sync-calendar-event/index.ts` -- sincroniza cirugias con Google Calendar

```typescript
// Sincroniza la fecha quirúrgica de un paciente con el Google Calendar de
// TODOS los médicos que ya conectaron el suyo (no solo quien cargó el turno).
// Requiere sesión de un médico logueado (verify_jwt=true) para poder invocarse,
// pero usa la secret key internamente para leer/escribir a través de médicos.

const SUPABASE_URL = Deno.env.get("SB_URL")!;
const SUPABASE_SECRET_KEY = Deno.env.get("SB_SECRET_KEY")!;
const GOOGLE_CLIENT_ID = Deno.env.get("GOOGLE_CLIENT_ID")!;
const GOOGLE_CLIENT_SECRET = Deno.env.get("GOOGLE_CLIENT_SECRET")!;

const CORS_HEADERS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

function jsonResponse(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...CORS_HEADERS, "Content-Type": "application/json" },
  });
}

function addOneDay(isoDate: string): string {
  const d = new Date(isoDate + "T00:00:00Z");
  d.setUTCDate(d.getUTCDate() + 1);
  return d.toISOString().slice(0, 10);
}

// Suma minutos a una fecha+hora "naive" (sin zona horaria) usando aritmética de
// calendario simple, evitando cualquier ambigüedad de husos horarios reales.
function addMinutes(fecha: string, hora: string, minutes: number): { fecha: string; hora: string } {
  const [y, m, d] = fecha.split("-").map(Number);
  const [hh, mm] = hora.split(":").map(Number);
  const dt = new Date(Date.UTC(y, m - 1, d, hh, mm));
  dt.setUTCMinutes(dt.getUTCMinutes() + minutes);
  const pad = (n: number) => String(n).padStart(2, "0");
  return {
    fecha: `${dt.getUTCFullYear()}-${pad(dt.getUTCMonth() + 1)}-${pad(dt.getUTCDate())}`,
    hora: `${pad(dt.getUTCHours())}:${pad(dt.getUTCMinutes())}`,
  };
}

async function sbFetch(path: string, init: RequestInit = {}) {
  return fetch(`${SUPABASE_URL}/rest/v1/${path}`, {
    ...init,
    headers: {
      apikey: SUPABASE_SECRET_KEY,
      Authorization: `Bearer ${SUPABASE_SECRET_KEY}`,
      "Content-Type": "application/json",
      ...(init.headers || {}),
    },
  });
}

async function getAccessToken(refreshToken: string): Promise<string | null> {
  const res = await fetch("https://oauth2.googleapis.com/token", {
    method: "POST",
    headers: { "Content-Type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams({
      refresh_token: refreshToken,
      client_id: GOOGLE_CLIENT_ID,
      client_secret: GOOGLE_CLIENT_SECRET,
      grant_type: "refresh_token",
    }),
  });
  const data = await res.json().catch(() => ({}));
  return res.ok ? data.access_token : null;
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response(null, { headers: CORS_HEADERS });
  if (req.method !== "POST") return jsonResponse({ error: "method not allowed" }, 405);

  let payload: any = {};
  try {
    payload = await req.json();
  } catch (_e) {
    return jsonResponse({ error: "invalid JSON" }, 400);
  }
  const pacienteId = payload.paciente_id;
  if (!pacienteId) return jsonResponse({ error: "paciente_id requerido" }, 400);

  const pacRes = await sbFetch(
    `pacientes?id=eq.${pacienteId}&select=id,nombre,sanatorio,operacion,fecha_qx,hora_qx,google_calendar_event_ids`
  );
  const pacRows = await pacRes.json().catch(() => []);
  if (!Array.isArray(pacRows) || pacRows.length === 0) return jsonResponse({ error: "paciente no encontrado" }, 404);
  const paciente = pacRows[0];
  const eventIds: Record<string, string> = paciente.google_calendar_event_ids || {};

  // Solo se sincroniza con médicos de rol "medico" — un residente que conecte
  // su Google Calendar no debería empezar a recibir todas las cirugías del equipo.
  const tokensRes = await sbFetch(
    `medico_calendar_tokens?select=medico_id,refresh_token,medicos!inner(rol)&medicos.rol=eq.medico`
  );
  const tokenRows: { medico_id: string; refresh_token: string }[] = await tokensRes.json().catch(() => []);

  if (!paciente.fecha_qx) {
    // Sin fecha: borra los eventos existentes en cada calendario conectado.
    for (const row of tokenRows) {
      const existing = eventIds[row.medico_id];
      if (!existing) continue;
      const accessToken = await getAccessToken(row.refresh_token);
      if (!accessToken) continue;
      await fetch(`https://www.googleapis.com/calendar/v3/calendars/primary/events/${existing}`, {
        method: "DELETE",
        headers: { Authorization: `Bearer ${accessToken}` },
      }).catch(() => {});
    }
    await sbFetch(`pacientes?id=eq.${pacienteId}`, {
      method: "PATCH",
      body: JSON.stringify({ google_calendar_event_ids: {} }),
    });
    return jsonResponse({ ok: true, synced: 0, deleted: true });
  }

  let direccion = "";
  if (paciente.sanatorio) {
    const sanRes = await sbFetch(
      `sanatorios?nombre=eq.${encodeURIComponent(paciente.sanatorio)}&select=direccion`
    );
    const sanRows = await sanRes.json().catch(() => []);
    if (Array.isArray(sanRows) && sanRows[0]?.direccion) direccion = sanRows[0].direccion;
  }

  const summary = paciente.operacion ? `${paciente.nombre} — ${paciente.operacion}` : paciente.nombre;
  const description = paciente.sanatorio ? `Sanatorio: ${paciente.sanatorio}` : "";
  const TZ = "America/Argentina/Buenos_Aires";

  let start: Record<string, string>;
  let end: Record<string, string>;
  if (paciente.hora_qx) {
    const horaInicio = String(paciente.hora_qx).slice(0, 5);
    const fin = addMinutes(paciente.fecha_qx, horaInicio, 60);
    start = { dateTime: `${paciente.fecha_qx}T${horaInicio}:00-03:00`, timeZone: TZ };
    end = { dateTime: `${fin.fecha}T${fin.hora}:00-03:00`, timeZone: TZ };
  } else {
    start = { date: paciente.fecha_qx };
    end = { date: addOneDay(paciente.fecha_qx) };
  }

  // colorId "5" = amarillo ("Banana" en la API/UI de Google Calendar en
  // inglés; no existe un nombre oficial "Girasol" pero es el color amarillo
  // que Pablo pidió para toda cirugía agendada).
  const eventBody: Record<string, unknown> = { summary, description, start, end, colorId: "5" };
  if (direccion) eventBody.location = direccion;

  const newEventIds: Record<string, string> = { ...eventIds };
  let synced = 0;

  for (const row of tokenRows) {
    const accessToken = await getAccessToken(row.refresh_token);
    if (!accessToken) continue;
    const existing = eventIds[row.medico_id];

    if (existing) {
      const patchRes = await fetch(
        `https://www.googleapis.com/calendar/v3/calendars/primary/events/${existing}`,
        {
          method: "PATCH",
          headers: { Authorization: `Bearer ${accessToken}`, "Content-Type": "application/json" },
          body: JSON.stringify(eventBody),
        }
      );
      if (patchRes.ok) {
        synced++;
        continue;
      }
      // El evento pudo haber sido borrado a mano del lado de Google: reintenta como insert.
    }

    const insertRes = await fetch(`https://www.googleapis.com/calendar/v3/calendars/primary/events`, {
      method: "POST",
      headers: { Authorization: `Bearer ${accessToken}`, "Content-Type": "application/json" },
      body: JSON.stringify(eventBody),
    });
    const insertData = await insertRes.json().catch(() => ({}));
    if (insertRes.ok && insertData.id) {
      newEventIds[row.medico_id] = insertData.id;
      synced++;
    }
  }

  await sbFetch(`pacientes?id=eq.${pacienteId}`, {
    method: "PATCH",
    body: JSON.stringify({ google_calendar_event_ids: newEventIds }),
  });

  return jsonResponse({ ok: true, synced });
});

```

### 4.5 `google-oauth-callback/index.ts` -- callback de OAuth de Google

```typescript
// Recibe el redirect de Google después de que un médico autoriza el acceso a su
// Google Calendar. Intercambia el code por un refresh_token y lo guarda en
// medico_calendar_tokens, scoped a ese médico (identificado por `state`).
// Función pública (verify_jwt=false): Google la llama directamente desde el
// navegador del médico, sin Authorization header de Supabase.

const SUPABASE_URL = Deno.env.get("SB_URL")!;
const SUPABASE_SECRET_KEY = Deno.env.get("SB_SECRET_KEY")!;
const GOOGLE_CLIENT_ID = Deno.env.get("GOOGLE_CLIENT_ID")!;
const GOOGLE_CLIENT_SECRET = Deno.env.get("GOOGLE_CLIENT_SECRET")!;
const APP_URL = Deno.env.get("APP_URL")!;
const REDIRECT_URI = `${SUPABASE_URL}/functions/v1/google-oauth-callback`;

Deno.serve(async (req) => {
  const url = new URL(req.url);
  const code = url.searchParams.get("code");
  const state = url.searchParams.get("state");
  const error = url.searchParams.get("error");

  function redirectToApp(status: string) {
    return new Response(null, {
      status: 302,
      headers: { Location: `${APP_URL}/?calendar=${status}` },
    });
  }

  if (error || !code || !state) {
    return redirectToApp("error");
  }

  // Confirma que state corresponde a un médico real antes de guardar nada.
  const medicoRes = await fetch(`${SUPABASE_URL}/rest/v1/medicos?id=eq.${state}&select=id`, {
    headers: { apikey: SUPABASE_SECRET_KEY, Authorization: `Bearer ${SUPABASE_SECRET_KEY}` },
  });
  const medicoRows = await medicoRes.json().catch(() => []);
  if (!Array.isArray(medicoRows) || medicoRows.length === 0) {
    return redirectToApp("error");
  }

  const tokenRes = await fetch("https://oauth2.googleapis.com/token", {
    method: "POST",
    headers: { "Content-Type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams({
      code,
      client_id: GOOGLE_CLIENT_ID,
      client_secret: GOOGLE_CLIENT_SECRET,
      redirect_uri: REDIRECT_URI,
      grant_type: "authorization_code",
    }),
  });
  const tokenData = await tokenRes.json().catch(() => ({}));

  if (!tokenRes.ok || !tokenData.refresh_token) {
    // Si el médico ya había conectado antes, Google puede no reenviar refresh_token
    // salvo que se fuerce prompt=consent (ya lo forzamos desde el front), así que
    // esto normalmente solo pasa ante un error real.
    return redirectToApp("error");
  }

  const upsertRes = await fetch(`${SUPABASE_URL}/rest/v1/medico_calendar_tokens`, {
    method: "POST",
    headers: {
      apikey: SUPABASE_SECRET_KEY,
      Authorization: `Bearer ${SUPABASE_SECRET_KEY}`,
      "Content-Type": "application/json",
      Prefer: "resolution=merge-duplicates",
    },
    body: JSON.stringify({
      medico_id: state,
      refresh_token: tokenData.refresh_token,
      connected_at: new Date().toISOString(),
    }),
  });

  if (!upsertRes.ok) {
    return redirectToApp("error");
  }

  return redirectToApp("connected");
});

```

### 4.6 `notify-new-ic/index.ts` -- push notifications de interconsultas nuevas

```typescript
import webpush from "npm:web-push@3.6.7";

const VAPID_PUBLIC_KEY = Deno.env.get("VAPID_PUBLIC_KEY")!;
const VAPID_PRIVATE_KEY = Deno.env.get("VAPID_PRIVATE_KEY")!;
const SUPABASE_URL = Deno.env.get("SB_URL")!;
const SUPABASE_SECRET_KEY = Deno.env.get("SB_SECRET_KEY")!;
const INTERNAL_SECRET = Deno.env.get("INTERNAL_FUNCTION_SECRET")!;

webpush.setVapidDetails("mailto:pablomaynard.pm@gmail.com", VAPID_PUBLIC_KEY, VAPID_PRIVATE_KEY);

Deno.serve(async (req) => {
  if (req.headers.get("x-internal-secret") !== INTERNAL_SECRET) {
    return new Response("forbidden", { status: 403 });
  }

  let payload: any = {};
  try {
    payload = await req.json();
  } catch (_e) {
    payload = {};
  }

  const countRes = await fetch(
    `${SUPABASE_URL}/rest/v1/interconsultas?select=id&estado=eq.pendiente`,
    {
      headers: {
        apikey: SUPABASE_SECRET_KEY,
        Authorization: `Bearer ${SUPABASE_SECRET_KEY}`,
        Prefer: "count=exact",
      },
    }
  );
  const contentRange = countRes.headers.get("content-range");
  const total = contentRange ? parseInt(contentRange.split("/")[1] || "0", 10) : 0;

  const subsRes = await fetch(`${SUPABASE_URL}/rest/v1/push_subscriptions?select=*`, {
    headers: {
      apikey: SUPABASE_SECRET_KEY,
      Authorization: `Bearer ${SUPABASE_SECRET_KEY}`,
    },
  });
  const subs = await subsRes.json();

  const title = "Nueva interconsulta";
  const bodyText = [payload.paciente, payload.sanatorio].filter(Boolean).join(" - ") || "Se cargó una interconsulta nueva";
  const notifPayload = JSON.stringify({ title, body: bodyText, badge: total });

  let sent = 0;
  await Promise.all(
    (subs || []).map(async (s: any) => {
      try {
        await webpush.sendNotification(
          { endpoint: s.endpoint, keys: { p256dh: s.p256dh, auth: s.auth } },
          notifPayload
        );
        sent++;
      } catch (e: any) {
        if (e.statusCode === 410 || e.statusCode === 404) {
          await fetch(`${SUPABASE_URL}/rest/v1/push_subscriptions?id=eq.${s.id}`, {
            method: "DELETE",
            headers: {
              apikey: SUPABASE_SECRET_KEY,
              Authorization: `Bearer ${SUPABASE_SECRET_KEY}`,
            },
          });
        }
      }
    })
  );

  return new Response(JSON.stringify({ ok: true, sent, total }), {
    headers: { "Content-Type": "application/json" },
  });
});

```

### 4.7 `manifest.json`

```json
{
  "name": "Gestión Médica",
  "short_name": "Gestión Médica",
  "start_url": "/",
  "scope": "/",
  "display": "standalone",
  "background_color": "#f4f6f8",
  "theme_color": "#2563eb",
  "icons": [
    { "src": "/icon-192.png", "sizes": "192x192", "type": "image/png", "purpose": "any" },
    { "src": "/icon-192.png", "sizes": "192x192", "type": "image/png", "purpose": "maskable" },
    { "src": "/icon-512.png", "sizes": "512x512", "type": "image/png", "purpose": "any" },
    { "src": "/icon-512.png", "sizes": "512x512", "type": "image/png", "purpose": "maskable" }
  ]
}

```

### 4.8 `sw.js` -- service worker

```javascript
self.addEventListener('install', () => self.skipWaiting());
self.addEventListener('activate', () => self.clients.claim());
self.addEventListener('fetch', (e) => {
  e.respondWith(fetch(e.request).catch(() => caches.match(e.request)));
});

self.addEventListener('push', (event) => {
  let data = {};
  try { data = event.data ? event.data.json() : {}; } catch (e) {}
  const title = data.title || 'Interconsultas';
  const body = data.body || 'Se cargó una interconsulta nueva';

  event.waitUntil((async () => {
    await self.registration.showNotification(title, {
      body,
      icon: '/icon-192.png',
      badge: '/icon-192.png',
      data: { url: '/' }
    });
    if (typeof data.badge === 'number' && self.navigator.setAppBadge) {
      try {
        if (data.badge > 0) await self.navigator.setAppBadge(data.badge);
        else await self.navigator.clearAppBadge();
      } catch (e) {}
    }
  })());
});

self.addEventListener('notificationclick', (event) => {
  event.notification.close();
  event.waitUntil(
    self.clients.matchAll({ type: 'window' }).then((clientsArr) => {
      const existing = clientsArr.find((c) => c.url.includes(self.location.origin));
      if (existing) return existing.focus();
      return self.clients.openWindow('/');
    })
  );
});

```

---

## 5. Estado actual y pendientes

### 5.1 Completamente operativo en producción

- **Interconsultas**: parser de texto de WhatsApp exportado, parser de mensajes sueltos, dedupe automático, agrupado por sanatorio, zona de facturación, subida de capturas de pantalla (procesadas por una rutina programada externa con visión, no en tiempo real — ver 5.3), carga manual vía modal (nombre, sanatorio, diagnóstico, fecha, piso, cama), exportación CSV, borrado automático a los 4 meses de exportada una resuelta, ledger de interconsultas facturables por sanatorio configurado.
- **Fichas de paciente**: ~30 campos (datos generales, antecedentes, operación, prequirúrgico completo, protocolo quirúrgico/anatomía patológica), calculadoras de riesgo de nódulo pulmonar (**Brock/PanCan** como modelo primario, **Herder** como complemento automático si hay captación PET — ambos verificados contra fuentes publicadas y un calculador de referencia en línea, no solo "recordados"), subida de imágenes TC/PET a Storage privado por médico, links clickeables normalizados, WhatsApp directo (con intent de Android para forzar WhatsApp Business), historial de cirugías (reoperaciones).
- **Flujo quirúrgico**: Materiales bloquea Fecha Qx hasta que están listos ("No requiere" o "En quirófano"), condición calculada (Pendiente/Programar/Programado/Operado — puramente derivada, no es una columna), botones Reprogramar/Cancelar cirugía, sincronización automática y bidireccional con Google Calendar de todos los médicos conectados (color amarillo fijo, evento con o sin horario según corresponda, ubicación autocompletada desde la dirección del sanatorio), **al poner Fecha Qx el paciente pasa a "internado" automáticamente** (agregado 2026-08-27).
- **Internados**: episodios de internación independientes de la ficha (para soportar múltiples admisiones a lo largo del tiempo), evoluciones jsonb append-only, alta, agrupado por sanatorio y ordenado por piso/habitación/cama.
- **Agenda**: vista calendario (día/semana/mes) 100% derivada de `fecha_qx`, sin tabla ni fetch propios.
- **Consultorio**: ledger de facturación de consultas (fecha/paciente/OS/valor), precios por sanatorio × OS (o precio único sin importar OS), subtotales y total, exportación CSV.
- **Resumen**: dashboard agregando cirugías programadas + internados + interconsultas pendientes, agrupado por sanatorio, sin fetch propio.
- **Multi-doctor + roles**: médicos y residentes, un residente ve solo los pacientes/internaciones de su supervisor (opcionalmente restringido a ciertos sanatorios, seleccionables con checkboxes), invitación con rol/sanatorios pre-seteados desde el link, todo reforzado con RLS real (no solo ocultamiento en la UI) — verificado con tokens reales de usuarios de prueba, no solo revisando el código.
- **Tier admin** (`es_admin`, hoy solo Pablo): panel único de gestión de sanatorios (dirección + zona de facturación + contactos vinculados, todo junto), pensado como el primero de una serie de paneles admin-only futuros.
- **Notificaciones**: push notifications reales (Web Push/VAPID) en cada interconsulta nueva vía trigger de Postgres + `pg_net`, badge del ícono de la PWA con el conteo de pendientes.
- **Ingesta automática desde Telegram**: bot dedicado + rutina programada en la nube (fuera de este repo, gestionada por Claude aparte) que revisa el bot cada 2 horas, extrae interconsultas de capturas por visión, y también procesa la cola de capturas subidas desde la app.

### 5.2 Bugs reales encontrados y corregidos en este proyecto (vale la pena conocerlos si algo "raro" vuelve a pasar)

- **Race condition de Google Calendar**: guardar Fecha Qx y Hora Qx en sucesión rápida disparaba dos llamadas concurrentes a la Edge Function de sync, creando un evento duplicado (uno con horario, uno sin) y dejando uno de los dos "huérfano" (sin ID trackeado). Solucionado encolando toda llamada a `syncCalendarEvent()` a través de una única promesa global (`calendarSyncQueue`), no en el backend.
- **Bug de residentes escribiendo bajo su propio ID en vez del de su supervisor** — apareció y se corrigió varias veces en distintos puntos de creación de pacientes/internaciones (Internados "Nuevo ingreso", `programarCxDesdeInterconsulta`). Cualquier `insert` nuevo sobre `pacientes`/`internaciones` **debe** usar `efectivoMedicoId()`, nunca `currentUser.id` directo, o un residente no podrá crear el registro (la RLS lo rechaza porque exige que `medico_id` sea el del supervisor).
- **Links de invitación consumidos solos por escáneres de seguridad de email** (Gmail u otros) antes de que el invitado real llegue a clickear — el token de invitación de Supabase es de un solo uso, y un escaneo automático del link (para chequear phishing) lo quema. La solución práctica no es reenviar el mismo tipo de link, sino que la persona intente entrar por la pantalla de login normal (Supabase probablemente ya la dejó autenticada) o generarle una contraseña directa vía la API admin.
- **`sb.functions.invoke()` de supabase-js v2 no expone el cuerpo de error real de una Edge Function** en una respuesta no-2xx — solo un mensaje genérico. El proyecto usa un helper `mensajeErrorFuncion(error)` en los 3 call-sites que invocan funciones, que extrae el JSON real desde `error.context`.
- **Rate limit de emails de Supabase Auth** (2/hora en el plan gratuito, sin SMTP propio configurado) — puede hacer fallar una invitación real si hubo pruebas recientes. Recomendado, no hecho todavía: configurar SMTP propio (ej. Resend) en Supabase Auth → Emails.

### 5.3 Explícitamente NO construido / diferido a pedido de Pablo

- **Facturación y Mensajería como módulos separados** — deprioritizados desde el principio; Interconsultas/Consultorio ya cubren buena parte de esa necesidad.
- **"Mensajes" — encuesta automática de WhatsApp a los 7 días post-operatorio** — idea guardada explícitamente para más adelante. Requiere infraestructura nueva de verdad: una cuenta de Meta Business + WhatsApp Cloud API (no la app de WhatsApp Business normal que usa Pablo hoy) + plantillas de mensaje pre-aprobadas por Meta, porque el envío es automático/fuera de una ventana de 24hs iniciada por el paciente.
- **SMTP propio para Supabase Auth** (ver 5.2) — recomendado pero no configurado; requiere que Pablo cree una cuenta en un proveedor (Resend u otro) y entregue las credenciales.
- **Multi-supervisor para un mismo residente** — hoy un residente tiene un único `supervisor_id`; si el equipo crece a varios médicos supervisando al mismo residente, hace falta rediseñar esa relación (hoy es 1:1, no N:N).
- **Selector de sanatorio hard-limitado para residentes restringidos** — el campo de sanatorio en el alta rápida de Pacientes/Internados sigue siendo texto libre incluso para un residente restringido a ciertos sanatorios; recién se entera de que un sanatorio no está permitido cuando la base rechaza el insert por RLS, no antes.
- **Lightbox/zoom para imágenes de TC/PET** — hoy solo hay thumbnails a tamaño nativo vía signed URL; sin problema con imágenes de prueba chicas, revisar si Pablo sube estudios reales grandes.
- **Ordenamiento de columnas configurable** en Pacientes/Agenda (sí existe en Interconsultas) — quedó con orden fijo (alfabético / fecha ascendente) como simplificación de alcance.
- Un colored-status-icon-row estilo "Geclisa" para Internados — evaluado y descartado por ahora, Pablo no estaba seguro de quererlo.

### 5.4 Deuda técnica y puntos de fricción conocidos, no bloqueantes

- **Sin control de versiones.** Ningún cambio de código tiene historial real más allá de los deploys de Vercel (que sí se pueden hacer rollback vía su dashboard/API) y las notas de esta memoria de proyecto. Migrar a un repo Git (aunque sea privado, sin CI) sería la mejora de mayor impacto para la mantenibilidad a futuro.
- **19 archivos de migración SQL incrementales, no consolidados** — documentan bien el historial pero no son la forma correcta de recrear el esquema desde cero (usar la Sección 2 de este documento para eso).
- **Bucket de Storage `interconsultas` marcado `public:true`** cuya finalidad no está clara/documentada en el historial del proyecto — antes de reutilizarlo para algo nuevo, confirmar qué lo está usando hoy (podría ser un residuo sin uso real).
- **Tabla `debug_log`** sin RLS habilitada — no forma parte del modelo de datos "oficial"; revisar si tiene datos sensibles antes de exponerla a alguien más, o directamente eliminarla si ya no se usa.
- **Heurística de "¿es un nódulo pulmonar?"** para mostrar la calculadora de riesgo es un simple substring-match sobre el texto de diagnóstico ("nodulo" + "pulmon") — funciona para el uso real actual pero es frágil ante variantes de redacción no probadas.
- **Sin tests automatizados.** Todo el testing de este proyecto se hizo manualmente (con cuentas de prueba desechables o la cuenta demo permanente) durante el desarrollo — no hay una suite que corra sola para detectar regresiones futuras.

