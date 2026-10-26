# Solución de problemas (Troubleshooting)

> Bitácora de problemas reales encontrados durante el desarrollo/despliegue del
> ecosistema Cursos (front React + backend Spring Boot + AWS Cognito + Supabase
> + API Gateway + Vercel). Cada sección describe: **síntoma → causa raíz → solución**.
>
> Última actualización: 2026-10-26

## Arquitectura de referencia

```
┌─────────────┐   HTTPS    ┌──────────────────┐   HTTP     ┌─────────────────┐
│  Front React │ ────────▶ │  API Gateway      │ ────────▶  │  Backend Spring │
│  (Vercel)    │           │  (HTTP API, JWT   │            │  Boot (EC2)     │
│  wouter SPA  │           │   authorizer)     │            │  :8080          │
└─────────────┘            └──────────────────┘            └───────┬─────────┘
                                                                    │
                                              ┌─────────────────────┼─────────────┐
                                              ▼                     ▼             ▼
                                        ┌──────────┐        ┌────────────┐  ┌──────────┐
                                        │ Cognito  │        │  Supabase  │  │  ntfy    │
                                        │ (usuarios│        │ (PostgreSQL│  │ (notif.) │
                                        │ y roles) │        │  pooler)   │  └──────────┘
                                        └──────────┘        └────────────┘
```

- **Front:** React 19 + wouter + Tailwind v4. Repo: `fs2-web` → desplegado en Vercel.
- **Back:** Spring Boot 3 (Java 21) en EC2, deploys con `deploy_ec2.sh`.
- **Auth:** Cognito User Pool. Los roles son **grupos de Cognito**: `administrador`,
  `colaborador`, `cliente`.
- **BD:** PostgreSQL en Supabase, accedido vía pooler.

---

## 1. El registro era público (debe ser solo ADMIN con sesión)

**Síntoma:** cualquiera podía crear cuentas en `/register` sin iniciar sesión.

**Causa:** la ruta `/register` en `src/App.tsx` estaba invertida: mostraba el
formulario a usuarios NO autenticados y redirigía al dashboard a los autenticados.

**Solución (front):**

```tsx
<Route path="/register">
  {!isAuthenticated || !user ? (
    <Redirect to="/login" />
  ) : !isAdmin ? (
    <Redirect to="/dashboard" />
  ) : (
    <DashboardLayout ...>
      <RegisterForm ... />
    </DashboardLayout>
  )}
</Route>
```

- Sin sesión → `/login`. Con sesión pero sin rol admin → `/dashboard`.
- El backend además protege `POST /api/auth/registro` con `@PreAuthorize("hasRole('ADMIN')...")`.
- El enlace "Regístrate" del login se eliminó: el único acceso es el botón
  "Registrar usuario" del panel admin.
- **Importante:** el guard del front es solo UX. La validación real debe estar
  siempre en el backend.

---

## 2. Enlace roto: `Link` importado desde `lucide-react`

**Síntoma:** el enlace del formulario de registro no funcionaba.

**Causa:** `import { Link } from "lucide-react"` importa el **ícono** de cadena
(`Link` icon), no el componente `Link` de wouter. El `to="/login"` se ignoraba.

**Solución:** `import { Link } from "wouter";`

Lección: `lucide-react` e `wouter` exportan el mismo nombre. Revisa los imports
cuando autocomplete sugiera el primero.

---

## 3. Cognito: `The attribute phoneNumbers is required`

**Síntoma:** `400` al registrar:
```
Attributes did not conform to the schema: phoneNumbers: The attribute
phoneNumbers is required (Service: CognitoIdentityProvider...)
```

**Causa:** el User Pool de Cognito tiene `phone_number` como atributo
**obligatorio**, y el backend no lo enviaba en el `SignUp`.

**Solución:**
1. Front: campo `telefono` obligatorio con formato E.164
   (`pattern="\+[0-9]{8,15}"`, ej. `+56932270562`). Cognito **exige** el
   código de país.
2. Back: mapear el campo al atributo de Cognito (`AuthService.registrar`):
   ```java
   AttributeType.builder().name("phone_number").value(phoneNumber).build()
   ```
3. **Desplegar el backend** — los cambios solo en local no sirven de nada
   (nos pasó: el JAR en EC2 estaba desactualizado y el error persistía).

Nota: el front envía el campo como `telefono` (no `phone_number`); el backend
hace la traducción.

---

## 4. `Group not found` al registrar

**Síntoma:** `400`:
```
Group not found. (Service: CognitoIdentityProvider, Status Code: 400)
```

**Causa:** el backend asigna roles con `AdminAddUserToGroup`, pero el front
enviaba roles que no existen como grupos en el pool (`ADMIN`, `DOCENTE`,
`ESTUDIANTE`). Los grupos reales del pool están en español.

**Ver los grupos reales:**
```bash
aws cognito-idp list-groups --user-pool-id "$AWS_COGNITO_USER_POOL_ID" \
  --region "$AWS_REGION" --query 'Groups[].GroupName' --output text
# → administrador   colaborador   cliente
```

**Solución:** alinear los `<option>` del front con los grupos reales:
`administrador`, `colaborador`, `cliente`.

Lección: los roles del front/back deben ser **exactamente** los nombres de los
grupos de Cognito. Verificar siempre con `list-groups` antes de inventar nombres.

---

## 5. Usuarios huérfanos (`UNCONFIRMED`) tras fallos parciales del registro

**Síntoma:** al reintentar un registro con el mismo email, falla; y en Cognito
quedan usuarios `UNCONFIRMED` que ocupan el email.

**Causa:** `registrar()` hace varias llamadas a Cognito en secuencia
(`signUp` → `adminAddUserToGroup` → confirmación → guardar en BD). Si algo
falla a la mitad, el usuario ya existe en Cognito pero la operación se abortó.

**Solución:**
1. Auto-confirmar después de crear el usuario (el registro lo hace un ADMIN,
   no debe requerir verificación por email):
   ```java
   cognitoClient.adminConfirmSignUp(AdminConfirmSignUpRequest.builder()
           .userPoolId(userPoolId).username(email).build());
   ```
2. Limpiar huérfanos manualmente:
   ```bash
   aws cognito-idp list-users --user-pool-id "$AWS_COGNITO_USER_POOL_ID" \
     --region "$AWS_REGION" --query 'Users[].[Attributes[?Name==`email`].Value | [0], UserStatus]' --output table
   aws cognito-idp admin-delete-user --user-pool-id "$AWS_COGNITO_USER_POOL_ID" \
     --region "$AWS_REGION" --username "email@viejo.com"
   ```

---

## 6. BD local con esquema viejo: `bad SQL grammar` al registrar

**Síntoma:**
```
Error interno del servidor: Hibernate transaction: Unable to rollback against
JDBC Connection; bad SQL grammar []
```

**Causa:** la tabla `usuarios` en Supabase era de una versión anterior del
proyecto (columnas `estado`, `rol` con CHECK, `creado_en`… todas `NOT NULL`
sin default). El nuevo código hace `INSERT (id, email, nombre)` → violación de
esquema. `spring.jpa.hibernate.ddl-auto: update` **nunca borra columnas ni
relaja constraints**, solo agrega.

**Solución:** verificar contenido y recrear:
```sql
SELECT count(*) FROM usuarios;            -- si está vacía, seguro borrar
DROP TABLE usuario_roles;
DROP TABLE usuarios;
```
Al reiniciar la app, Hibernate recrea las tablas con el esquema actual.

---

## 7. `ADD COLUMN ... NOT NULL` falla si la tabla tiene filas

**Síntoma (en el log de arranque):**
```
Error executing DDL "alter table if exists usuarios add column activo
boolean not null" via JDBC
[ERROR: column "activo" of relation "usuarios" contains null values]
```
Hibernate lo deja pasar con un WARN y la columna **nunca se crea**. Después,
cualquier query que la use falla con `bad SQL grammar`.

**Causa:** PostgreSQL no puede agregar una columna `NOT NULL` sin `DEFAULT`
a una tabla que ya tiene filas (nos pasó porque un registro exitoso insertó
una fila entre el arranque anterior y el nuevo deploy).

**Solución:**
```sql
ALTER TABLE public.usuarios ADD COLUMN activo boolean NOT NULL DEFAULT true;
```
Lección: los cambios de esquema en `ddl-auto: update` se aplican solo al
arrancar y **fallan silenciosamente** (WARN en el log). Revisar el log de
arranque tras cada deploy.

---

## 8. APIs admin de Cognito: `Unable to load credentials from any of the providers`

**Síntoma:** `login` y `signUp` funcionan, pero las llamadas `Admin*`
(`adminAddUserToGroup`, `adminDisableUser`, `adminDeleteUser`…) fallan con:
```
Unable to load credentials from any of the providers in the chain
AwsCredentialsProviderChain(...)
```

**Causa:** las operaciones `Admin*` requieren **credenciales AWS firmadas**.
La EC2 **no tiene rol IAM** (`IamInstanceProfile: null` → IMDS imposible) y el
`.env` solo tenía la configuración de Cognito (pool id, client id), no
credenciales. Además `loadDotenv()` expone variables como **system properties**
de Spring (`AWS_ACCESS_KEY_ID`), pero el SDK busca env vars reales o las
properties `aws.accessKeyId`.

**Solución (3 capas):**
1. `.env` del back: agregar `AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY`.
2. `application.yml` mapearlas a las propiedades que ya esperaba
   `CognitoConfig`:
   ```yaml
   aws:
     access-key-id: ${AWS_ACCESS_KEY_ID:}
     secret-access-key: ${AWS_SECRET_ACCESS_KEY:}
   ```
3. En `CursosApplication.loadDotenv()` exponer además con los nombres del SDK:
   ```java
   System.setProperty("aws.accessKeyId", awsAk);
   System.setProperty("aws.secretAccessKey", awsSk);
   ```

Lección: `signUp`/`initiateAuth` son operaciones **públicas** (no necesitan
credenciales); todo lo que empieza con `Admin*` sí. Una EC2 sin IAM role
necesita credenciales estáticas.

---

## 9. API Gateway: 401 `{"message":"Unauthorized"}` con token válido

**Síntoma:** `GET /api/usuarios` vía API Gateway responde 401 aunque el token
funciona contra la EC2 directamente.

**Causa:** el **JWT authorizer** del API Gateway apuntaba a un **pool viejo**
(`us-east-2_ZhTULhf5B` / client `4fm8oratn2rgup09trhbrdk3gd`), distinto del que
usa la app (`us-east-2_KDduqjQdn` / `61ippihjk24nt2gvva9mk7mpu2`). El Gateway
rechaza el token sin reenviarlo al backend.

**Diagnóstico:**
```bash
aws apigatewayv2 get-authorizers --api-id yxpnxitdnh --region us-east-2
grep AWS_COGNITO .env   # pool/client reales de la app
```

**Solución:**
```bash
aws apigatewayv2 update-authorizer --api-id yxpnxitdnh --region us-east-2 \
  --authorizer-id jalye3 \
  --identity-source '$request.header.Authorization' \
  --jwt-configuration '{ "Audience": ["61ippihjk24nt2gvva9mk7mpu2"],
    "Issuer": "https://cognito-idp.us-east-2.amazonaws.com/us-east-2_KDduqjQdn" }'
```

Otro 401 distinto: los **access tokens de Cognito duran 1 hora**. Si pruebas
con un token viejo (de localStorage o copiado hace rato), expiró → 401 legítimo.
Vuelve a iniciar sesión.

---

## 10. API Gateway: 503 `Service Unavailable` en rutas protegidas

**Síntoma:** `health` y `login` funcionan vía API Gateway, pero el resto da 503.

**Causa:** había **dos integraciones distintas**: la de `health`/`login` apuntaba
a la EC2 actual (`http://77.113.69.25:8080/...`) y la integración `{proxy+}`
(usada por todas las demás rutas) apuntaba a la **IP de una instancia vieja** y
sin puerto (`http://3.138.140.224/api/{proxy}`).

**Diagnóstico:**
```bash
aws apigatewayv2 get-integrations --api-id yxpnxitdnh --region us-east-2
```

**Solución:**
```bash
aws apigatewayv2 update-integration --api-id yxpnxitdnh --region us-east-2 \
  --integration-id b3rmwkh \
  --integration-uri 'http://77.113.69.25:8080/api/{proxy}'
```

**Prevención:** la IP pública de la EC2 es **efímera** (cambia en cada
stop/start). Asignar una **Elastic IP** o apuntar la integración a un DNS
estable; si no, cada cambio de IP rompe el Gateway.

---

## 11. CORS del API Gateway bloquea los dominios de Vercel

**Síntoma:** el front en Vercel no puede llamar al API (el preflight OPTIONS
falla o no devuelve headers).

**Causa:** `CorsConfiguration` del Gateway tenía orígenes fijos
(`localhost:5173`, un CloudFront, un dominio Vercel específico). Los **preview
deployments de Vercel generan dominios nuevos en cada deploy** → no coinciden.

**Solución:** origen abierto (el backend ya usa `CORS_ALLOWED_ORIGINS=*`):
```bash
aws apigatewayv2 update-api --api-id yxpnxitdnh --region us-east-2 --cors-configuration '{
  "AllowHeaders": ["content-type","authorization"],
  "AllowMethods": ["GET","POST","OPTIONS","PATCH","PUT","DELETE"],
  "AllowOrigins": ["*"], "MaxAge": 300 }'
```

**Verificar:**
```bash
curl -s -i -X OPTIONS https://yxpnxitdnh.execute-api.us-east-2.amazonaws.com/api/usuarios \
  -H 'Origin: https://mi-preview.vercel.app' \
  -H 'Access-Control-Request-Method: PATCH' \
  -H 'Access-Control-Request-Headers: authorization,content-type'
# Debe responder 204 + access-control-allow-origin
```

---

## 12. Supabase Pooler: `prepared statement "S_3" already exists`

**Síntoma:** errores **intermitentes** (funciona a ratos) tipo:
```
JDBC exception executing SQL [ERROR: current transaction is aborted...]
Unable to commit against JDBC Connection; bad SQL grammar []
Failed to release JPA EntityManager
[ERROR: prepared statement "S_3" already exists]
```

**Causa:** el `DATABASE_URL` apuntaba al **pooler de Supabase en el puerto
6543 = PgBouncer en modo TRANSACTION**. Hibernate usa prepared statements con
nombres fijos (`S_1`, `S_2`…); en transaction pooling la conexión de servidor
se comparte entre clientes y los nombres colisionan.

**Solución:** usar el **puerto 5432 (session pooler)**, donde cada cliente
conserva su conexión de servidor:
```
jdbc:postgresql://aws-0-us-east-2.pooler.supabase.com:5432/postgres?sslmode=require
```
Alternativa: deshabilitar prepared statements del driver con
`&prepareThreshold=0` en la URL.

Lección: *transaction pooling* no es compatible 100% con Hibernate. Si ves
errores de prepared statements o transacciones abortadas intermitentes, el
puerto del pooler es el primer sospechoso.

---

## 13. Vercel: 404 al recargar rutas de la SPA

**Síntoma:** `https://<app>.vercel.app/dashboard` carga si llegas desde el login
(navegación SPA), pero **al recargar** (F5) o entrar directo:
```
This page doesn't exist — 404 NOT_FOUND
```

**Causa:** wouter maneja las rutas en el navegador. Al recargar, se le pide a
Vercel el archivo físico `/dashboard`, que no existe.

**Solución:** `vercel.json` en la raíz del front:
```json
{
  "rewrites": [{ "source": "/(.*)", "destination": "/index.html" }]
}
```
Commit + push → Vercel redeploya solo (~30 s).

**Además:** Vite hornea `VITE_API_URL` **en build time**. Si se cambia la API
(en Vercel → Settings → Environment Variables), hay que redeployar.

---

## 14. Mixed content: front HTTPS no puede llamar a backend HTTP

**Síntoma:** el front en Vercel (HTTPS) no puede llamar a
`http://77.113.69.25:8080` (HTTP) — el navegador lo bloquea.

**Solución:** siempre usar el **API Gateway (HTTPS)** como `VITE_API_URL` en
producción. La URL directa de la EC2 solo para desarrollo local.

---

## Tips de operación

**Deploy del backend (rebuild + upload + restart):**
```bash
cd /Users/.../cursos && ./deploy_ec2.sh
```
Revisa SIEMPRE el log de arranque en busca de WARNs de DDL:
```bash
ssh -i mi-llave-privada.pem ec2-user@77.113.69.25 "grep -i 'error\|warn' app.log | tail"
```

**Reiniciar sin rebuild** (solo cambió `.env`):
```bash
ssh -i mi-llave-privada.pem ec2-user@77.113.69.25 \
  "pkill -f 'cursos-0[.]0[.]1-SNAPSHOT' || true; sleep 3"
# En OTRO comando (pkill puede matar la sesión ssh si el patrón coincide con
# la línea de comando propia — usar [.] para evitarlo):
ssh -i mi-llave-privada.pem ec2-user@77.113.69.25 \
  "cd /home/ec2-user && nohup java -Dserver.port=8080 -jar cursos-0.0.1-SNAPSHOT.jar > app.log 2>&1 < /dev/null &"
```

**Prueba end-to-end del registro/listado sin navegador:**
```bash
API=https://yxpnxitdnh.execute-api.us-east-2.amazonaws.com/api
TOKEN=$(curl -sf -X POST "$API/auth/login" -H 'Content-Type: application/json' \
  -d '{"email":"admin@test.com","password":"..."}' | python3 -c "import sys,json; print(json.load(sys.stdin)['data']['accessToken'])")
curl -sf "$API/usuarios" -H "Authorization: Bearer $TOKEN"
```

**Estado de la BD** ( Supabase → psql):
```bash
psql "postgresql://${DATABASE_USER}:${DATABASE_PASSWORD}@aws-0-us-east-2.pooler.supabase.com:5432/postgres?sslmode=require" -c '\d public.usuarios'
```
(NOTA: la URL del `.env` es formato JDBC — para psql hay que quitarle el
prefijo `jdbc:postgresql://` y pasar usuario/password aparte.)

## Deuda técnica pendiente

- [ ] Revisar el mapeo de grupos JWT → roles en `SecurityConfig`: un usuario con
      solo el grupo `colaborador` pudo llamar endpoints `@PreAuthorize ADMIN`.
- [ ] Commitear los cambios del backend ( AuthService/UsuarioController/CognitoConfig).
- [ ] Elastic IP para la EC2 o DNS estable para las integraciones del API Gateway.
- [ ] Considerar rol IAM en la EC2 en lugar de credenciales estáticas.
- [ ] `AdminUserGlobalSignOut` al dar de baja un usuario (que su sesión activa
      muera de inmediato, no solo al expirar el token).
- [ ] Limpiar código muerto en `cursos-front/src/clients/` (`register`, `login`,
      `health` duplican clientes que ya existen en `services/api.ts`).
