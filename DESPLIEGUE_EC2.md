# Guía de Despliegue en EC2 - Cursos API

## Resumen del Problema Original
La API devolvía **401 Unauthorized** con header `WWW-Authenticate: Bearer` en endpoints públicos (`/api/auth/login`, `/api/health`) debido a que Spring Security's **OAuth2 Resource Server** se auto-configuraba y protegía TODOS los endpoints con validación JWT.

---

## Cambios en Código (Commit necesarios)

### 1. `build.gradle` - Agregar dependencia OAuth2 Resource Server
```groovy
dependencies {
    implementation 'org.springframework.boot:spring-boot-starter-oauth2-resource-server'
    // ... otras deps
}
```

### 2. `src/main/java/com/duoc/cursos/config/SecurityConfig.java`
```java
import org.springframework.security.config.annotation.web.configurers.oauth2.server.resource.OAuth2ResourceServerConfigurer;

@Bean
public SecurityFilterChain filterChain(HttpSecurity http) throws Exception {
    http
        .csrf(AbstractHttpConfigurer::disable)
        .cors(cors -> cors.configurationSource(corsConfigurationSource()))
        .authorizeHttpRequests(authz -> authz
            .requestMatchers("/api/auth/**", "/api/health", "/api/notificar", "/api/notificar/**").permitAll()
            .anyRequest().authenticated()
        )
        .oauth2ResourceServer(oauth2 -> oauth2.jwt(jwt -> {}))  // ← NUEVO: Config explícita JWT
        .formLogin(AbstractHttpConfigurer::disable)
        .httpBasic(AbstractHttpConfigurer::disable);

    return http.build();
}
```

### 3. `src/main/resources/application.yml` - Pool Hikari pequeño para Supabase
```yaml
spring:
  datasource:
    url: ${DATABASE_URL}
    username: ${DATABASE_USER}
    password: ${DATABASE_PASSWORD}
    driver-class-name: org.postgresql.Driver
    hikari:
      maximum-pool-size: 3          # ← Crítico: Supabase pooler límite 15
      minimum-idle: 1
      connection-timeout: 30000
      idle-timeout: 300000
      max-lifetime: 1200000
```

### 4. `src/main/java/com/duoc/cursos/CursosApplication.java` - Cargar issuer-uri
```java
// En loadDotenv(), después de cargar variables:
if (dotenv.entries().stream().anyMatch(e -> "SPRING_SECURITY_OAUTH2_RESOURCESERVER_JWT_ISSUER_URI".equals(e.getKey()))) {
    String val = dotenv.get("SPRING_SECURITY_OAUTH2_RESOURCESERVER_JWT_ISSUER_URI");
    System.setProperty("spring.security.oauth2.resourceserver.jwt.issuer-uri", val);
}
```

---

## Variables de Entorno Requeridas (`.env` en EC2)

```properties
# Perfil Spring
SPRING_PROFILES_ACTIVE=prod

# Base de datos - Puerto 6543 = Transaction Mode (sin límite 15 conexiones)
DATABASE_URL=jdbc:postgresql://aws-0-us-east-2.pooler.supabase.com:6543/postgres?sslmode=require
DATABASE_USER=postgres.xxxxxxxxxxxx
DATABASE_PASSWORD=xxxxxxxxxxxxxxxx

# AWS Cognito
AWS_REGION=us-east-2
AWS_COGNITO_USER_POOL_ID=us-east-2_xxxxxxxxx
AWS_COGNITO_CLIENT_ID=xxxxxxxxxxxxxxxxxxxxxxxxxx
AWS_COGNITO_CLIENT_SECRET=xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx

# OAuth2 Resource Server - CRÍTICO: Sin esto no arranca JwtDecoder
SPRING_SECURITY_OAUTH2_RESOURCESERVER_JWT_ISSUER_URI=https://cognito-idp.us-east-2.amazonaws.com/us-east-2_xxxxxxxxx

# CORS
CORS_ENABLED=true
CORS_ALLOWED_ORIGINS=*
CORS_ALLOWED_METHODS=GET,POST,PUT,PATCH,DELETE,OPTIONS
CORS_ALLOWED_HEADERS=*
CORS_EXPOSED_HEADERS=Authorization,Content-Type
CORS_ALLOW_CREDENTIALS=false
CORS_MAX_AGE=3600

# App
SERVER_PORT=8080
LOG_LEVEL=DEBUG
```

> **Nota**: El puerto **6543** usa **Transaction Mode** en Supabase PgBouncer (vs 5432 = Session Mode con límite 15 conexiones).

---

## Despliegue Paso a Paso

### 1. Compilar JAR local
```bash
./gradlew clean bootJar
```

### 2. Copiar JAR a EC2
```bash
scp -i /ruta/mi-llave-privada.pem \
  build/libs/cursos-0.0.1-SNAPSHOT.jar \
  ec2-user@77.113.69.25:/home/ec2-user/
```

### 3. Crear/actualizar `.env` en EC2
```bash
ssh -i /ruta/mi-llave-privada.pem ec2-user@77.113.69.25 "
cat > /home/ec2-user/.env << 'EOF'
# Pegar aquí todo el contenido de .env (ver arriba)
EOF
"
```

### 4. Matar procesos previos y liberar puerto 8080
```bash
ssh -i /ruta/mi-llave-privada.pem ec2-user@77.113.69.25 "
sudo fuser -k 8080/tcp
pkill -9 java
sleep 3
"
```

### 5. Iniciar aplicación
```bash
ssh -i /ruta/mi-llave-privada.pem ec2-user@77.113.69.25 "
cd /home/ec2-user
nohup java -jar cursos-0.0.1-SNAPSHOT.jar > app.log 2>&1 &
echo \$!
sleep 15
cat app.log
"
```

### 6. Verificar salud
```bash
curl http://77.113.69.25:8080/api/health
# Debe retornar: {"success":true,"data":{"service":"cursos-api","status":"UP",...}}

curl -X POST http://77.113.69.25:8080/api/auth/login \
  -H "Content-Type: application/json" \
  -d '{"email":"docente.dev@gmail.com","password":"Visual.02"}'
# Debe retornar 200 con accessToken, idToken, refreshToken
```

---

## Troubleshooting Común

| Error | Causa | Solución |
|-------|-------|----------|
| `401 WWW-Authenticate: Bearer` | OAuth2 Resource Server sin JwtDecoder | Verificar `SPRING_SECURITY_OAUTH2_RESOURCESERVER_JWT_ISSUER_URI` en `.env` |
| `FATAL: (EMAXCONNSESSION) max clients reached` | Supabase pooler límite 15 conexiones | Usar puerto **6543** (Transaction mode) + Hikari `maximum-pool-size: 3` |
| `Port 8080 already in use` | Proceso Java zombie | `sudo fuser -k 8080/tcp && pkill -9 java` |
| `No qualifying bean of type JwtDecoder` | Falta issuer-uri o Cognito no accesible | Verificar variable de entorno y conectividad a `https://cognito-idp.<region>.amazonaws.com/<userPoolId>` |
| App arranca pero BD no conecta | Credenciales wrong o SSL | Verificar `DATABASE_URL` incluye `?sslmode=require` y credenciales correctas |

---

## URLs de Referencia

- **API Base**: `http://77.113.69.25:8080`
- **Health**: `http://77.113.69.25:8080/api/health`
- **Login**: `POST http://77.113.69.25:8080/api/auth/login`
- **OAuth2 Metadata**: `http://77.113.69.25:8080/.well-known/oauth-protected-resource`
- **Cognito JWKS**: `https://cognito-idp.us-east-2.amazonaws.com/us-east-2_KDduqjQdn/.well-known/jwks.json`
- **Supabase Dashboard**: https://supabase.com/dashboard/project/<project-id>/settings/database

---

## Logs Útiles

```bash
# Ver logs en vivo
ssh -i /ruta/mi-llave-privada.pem ec2-user@77.113.69.25 "tail -f /home/ec2-user/app.log"

# Ver últimos 100 líneas
ssh -i /ruta/mi-llave-privada.pem ec2-user@77.113.69.25 "tail -100 /home/ec2-user/app.log"
```

---

## Checklist Pre-Deploy

- [ ] `./gradlew clean bootJar` exitoso
- [ ] Tests pasan: `./gradlew test`
- [ ] `.env` actualizado en EC2 con todas las variables
- [ ] Puerto Supabase en **6543** (Transaction mode)
- [ ] `SPRING_SECURITY_OAUTH2_RESOURCESERVER_JWT_ISSUER_URI` presente
- [ ] Puerto 8080 libre en EC2
- [ ] Health check responde 200
- [ ] Login responde 200 con tokens JWT válidos