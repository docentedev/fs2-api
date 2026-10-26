# ============================================================
# deploy_ec2.ps1 - Version Windows (PowerShell) de deploy_ec2.sh
# Uso:
#   powershell -ExecutionPolicy Bypass -File .\deploy_ec2.ps1
# Requisitos locales:
#   - AWS CLI (aws) configurado y con permisos EC2
#   - Java 21 JDK (para compilar con Gradle)
#   - OpenSSH client (ssh/scp) y curl.exe (incluidos en Win10/11)
# ============================================================

# Nota: se usa el ErrorActionPreference por defecto porque con 'Stop' los
# avisos de stderr de comandos nativos (aws/ssh) en Windows PowerShell 5.1
# interrumpen el script. Los errores se manejan con $LASTEXITCODE explicito.

# ============================================
# CONFIGURACION - MODIFICA ESTOS VALORES
# ============================================
$SERVER_PORT      = 8080
$INSTANCE_EC2_ID  = 'i-034c79128b1fa7373'
$PEM_KEY          = 'mi-llave-privada.pem'
$LOCAL_ENV_FILE   = '.env'
$PROJECT_DIR      = Split-Path -Parent $MyInvocation.MyCommand.Path
$REMOTE_USER      = 'ec2-user'
$REMOTE_DIR       = '/home/ec2-user'
$JAR_NAME         = 'cursos-0.0.1-SNAPSHOT.jar'

# ============================================
# FUNCIONES AUXILIARES
# ============================================
function Log-Info    { param($m) Write-Host "[INFO] $m" -ForegroundColor Cyan }
function Log-Ok      { param($m) Write-Host "[OK] $m"   -ForegroundColor Green }
function Log-Warn    { param($m) Write-Host "[WARN] $m" -ForegroundColor Yellow }
function Log-Error   { param($m) Write-Host "[ERROR] $m" -ForegroundColor Red }

function Get-InstanceIp {
    Log-Info "Obteniendo IP publica de la instancia..."
    $ip = aws ec2 describe-instances `
        --instance-ids $INSTANCE_EC2_ID `
        --query "Reservations[0].Instances[0].PublicIpAddress" `
        --output text
    $ip = "$ip".Trim()
    if (-not $ip -or $ip -eq 'None' -or $ip -eq '') {
        Log-Error "No se pudo obtener IP para la instancia $INSTANCE_EC2_ID (revisa credenciales/region de aws cli)"
        exit 1
    }
    return $ip
}

function Assert-PemKey {
    if (-not (Test-Path $PEM_KEY)) {
        Log-Error "No se encuentra la llave PEM: $PEM_KEY (ejecuta desde la carpeta del proyecto)"
        exit 1
    }
    # En Windows, ssh exige que la llave no sea accesible por otros usuarios.
    # chmod 400 no existe: se ajustan las ACLs.
    try {
        icacls $PEM_KEY /inheritance:r /grant:r "${env:USERNAME}:R" | Out-Null
        Log-Ok "Permisos de la llave ajustados (solo tu usuario)"
    } catch {
        Log-Warn "No se pudieron ajustar las ACLs de la llave. Si ssh falla con 'permissions too open', ejecuta:"
        Log-Warn "icacls $PEM_KEY /inheritance:r /grant:r `"${env:USERNAME}:R`""
    }
}

function Import-DotEnv {
    Log-Info "Cargando variables desde $LOCAL_ENV_FILE..."
    if (-not (Test-Path $LOCAL_ENV_FILE)) {
        Log-Error "No se encuentra archivo .env local: $LOCAL_ENV_FILE"
        exit 1
    }
    $count = 0
    Get-Content $LOCAL_ENV_FILE | ForEach-Object {
        $line = $_.Trim()
        if ($line -and -not $line.StartsWith('#')) {
            $parts = $line -split '=', 2
            if ($parts.Count -eq 2) {
                $key = $parts[0].Trim()
                $val = $parts[1].Trim().Trim('"').Trim("'")
                Set-Item -Path "env:$key" -Value $val
                $count++
            }
        }
    }
    Log-Ok "Variables de entorno cargadas ($count)"
}

function Test-JavaLocal {
    Log-Info "Verificando Java 21 en local..."
    try {
        $out = (& java -version 2>&1 | Select-Object -First 1) -join ' '
        $match = [regex]::Match($out, '"(\d+)')
        if ($match.Success) {
            $major = [int]$match.Groups[1].Value
            if ($major -ge 21) {
                Log-Ok "Java $major encontrado localmente"
            } else {
                Log-Warn "Java $major < 21, se necesita Java 21 para compilar"
            }
        } else {
            Log-Warn "No se pudo determinar la version de Java: $out"
        }
    } catch {
        Log-Warn "Java no encontrado en local (JAVA_HOME apunta a un JDK 21?)"
    }
}

function Wait-PortFree {
    param([string]$ip, [int]$port)
    $timeout = 60; $elapsed = 0
    Log-Info "Esperando que puerto $port se libere en $ip..."
    while ($true) {
        ssh -i $PEM_KEY -o ConnectTimeout=5 -o StrictHostKeyChecking=no `
            "$REMOTE_USER@$ip" "ss -tlnp | grep :$port" | Out-Null
        if ($LASTEXITCODE -ne 0) { break }   # grep sin coincidencias = libre
        if ($elapsed -ge $timeout) {
            Log-Warn "Timeout: forzando liberacion del puerto $port..."
            ssh -i $PEM_KEY -o ConnectTimeout=5 -o StrictHostKeyChecking=no `
                "$REMOTE_USER@$ip" "sudo fuser -k $port/tcp 2>/dev/null || true; sudo pkill -9 java 2>/dev/null || true; sleep 2" | Out-Null
            break
        }
        Start-Sleep -Seconds 2
        $elapsed += 2
    }
    Log-Ok "Puerto $port libre"
}

function Wait-Health {
    param([string]$ip, [int]$port)
    $timeout = 60; $elapsed = 0
    Log-Info "Esperando health check en http://${ip}:${port}/api/health..."
    while ($true) {
        curl.exe -sf --max-time 5 "http://${ip}:${port}/api/health" 2>$null | Out-Null
        if ($LASTEXITCODE -eq 0) { break }
        if ($elapsed -ge $timeout) {
            Log-Error "Timeout: health check no respondio OK despues de ${timeout}s"
            return $false
        }
        Start-Sleep -Seconds 3
        $elapsed += 3
        Write-Host -NoNewline "."
    }
    Write-Host ""
    Log-Ok "Health check OK!"
    return $true
}

# ============================================
# MAIN
# ============================================

Log-Info "=== INICIANDO DEPLOY A EC2 ==="
Log-Info "Instance ID: $INSTANCE_EC2_ID | Puerto: $SERVER_PORT | Key: $PEM_KEY"

Set-Location $PROJECT_DIR
Assert-PemKey
Import-DotEnv
Test-JavaLocal

# 1. IP de la instancia
$INSTANCE_IP = Get-InstanceIp
Log-Ok "Instance IP: $INSTANCE_IP"

# 2. Verificar puerto en remoto ANTES de compilar
Log-Info "Verificando puerto $SERVER_PORT en instancia remota..."
ssh -i $PEM_KEY -o ConnectTimeout=10 -o StrictHostKeyChecking=no `
    "$REMOTE_USER@$INSTANCE_IP" "ss -tlnp | grep :$SERVER_PORT" | Out-Null
if ($LASTEXITCODE -eq 0) {
    Log-Warn "Puerto $SERVER_PORT ocupado en remoto, se liberara despues"
} else {
    Log-Ok "Puerto $SERVER_PORT libre en remoto"
}

# 3. Build local con Gradle
Log-Info "Compilando proyecto con Gradle (clean bootJar)..."
& (Join-Path $PROJECT_DIR 'gradlew.bat') clean bootJar --no-daemon
if ($LASTEXITCODE -ne 0) {
    Log-Error "Fallo la compilacion"
    exit 1
}
Log-Ok "Build exitoso"

$JAR_PATH = Join-Path $PROJECT_DIR "build\libs\$JAR_NAME"
if (-not (Test-Path $JAR_PATH)) {
    Log-Error "No se encontro JAR en $JAR_PATH"
    exit 1
}
$jarSize = "{0:N1}" -f ((Get-Item $JAR_PATH).Length / 1MB)
Log-Ok "JAR generado: $JAR_NAME ($jarSize MB)"

# 4. Subir .env y JAR
Log-Info "Subiendo .env a la instancia..."
scp -i $PEM_KEY -o StrictHostKeyChecking=no $LOCAL_ENV_FILE "$REMOTE_USER@$INSTANCE_IP:$REMOTE_DIR/.env" | Out-Null
Log-Ok ".env subido a $REMOTE_DIR/.env"

Log-Info "Subiendo JAR a la instancia..."
scp -i $PEM_KEY -o StrictHostKeyChecking=no $JAR_PATH "$REMOTE_USER@$INSTANCE_IP:$REMOTE_DIR/$JAR_NAME" | Out-Null
Log-Ok "JAR subido a $REMOTE_DIR/$JAR_NAME"

# 5. Matar procesos en el puerto (script remoto sin expansion local: usar [.] y comillas simples)
Log-Info "Matando procesos en puerto $SERVER_PORT en remoto..."
$killScript = @'
sudo systemctl stop cloud-usuarios-bff 2>/dev/null || true
sudo systemctl disable cloud-usuarios-bff 2>/dev/null || true
sudo fuser -k PORT/tcp 2>/dev/null || true
sudo pkill -9 java 2>/dev/null || true
for pid in $(sudo ss -tlnp | grep :PORT | grep -oP "pid=\K[0-9]+" | sort -u); do
  sudo kill -9 $pid 2>/dev/null || true
done
for pid in $(sudo lsof -ti :PORT 2>/dev/null | sort -u); do
  sudo kill -9 $pid 2>/dev/null || true
done
sleep 5
'@.Replace('PORT', "$SERVER_PORT")

ssh -i $PEM_KEY -o ConnectTimeout=10 -o StrictHostKeyChecking=no `
    "$REMOTE_USER@$INSTANCE_IP" $killScript
Wait-PortFree -ip $INSTANCE_IP -port $SERVER_PORT

# 6. Verificar/instalar Java 21 en remoto
Log-Info "Verificando Java 21 en instancia remota..."
$javaCheck = @'
if command -v java >/dev/null 2>&1; then
  JAVA_VER=$(java -version 2>&1 | head -n1 | awk -F '"' '{print $2}' | cut -d. -f1)
  if [ "$JAVA_VER" -ge 21 ]; then
    echo "Java 21+ ya instalado: $(java -version 2>&1 | head -n1)"
    exit 0
  fi
fi
echo "Instalando Java 21..."
if command -v dnf >/dev/null 2>&1; then
  sudo dnf install -y java-21-amazon-corretto-devel
elif command -v apt >/dev/null 2>&1; then
  sudo apt update && sudo apt install -y openjdk-21-jdk
elif command -v yum >/dev/null 2>&1; then
  sudo yum install -y java-21-amazon-corretto-devel
else
  echo "No se pudo determinar package manager"; exit 1
fi
java -version
'@
ssh -i $PEM_KEY -o ConnectTimeout=10 -o StrictHostKeyChecking=no `
    "$REMOTE_USER@$INSTANCE_IP" $javaCheck
if ($LASTEXITCODE -ne 0) {
    Log-Error "Fallo la verificacion/instalacion de Java 21 en remoto"
    exit 1
}
Log-Ok "Java 21 verificado/instalado en remoto"

# 7. Arrancar aplicacion en remoto
Log-Info "Arrancando aplicacion en puerto $SERVER_PORT..."
$startScript = @"
cd $REMOTE_DIR
nohup java -Dserver.port=$SERVER_PORT -Dspring.socket.reuseAddress=true -jar $JAR_NAME > app.log 2>&1 < /dev/null &
echo `$! > app.pid
echo "PID: `$(cat app.pid)"
"@
ssh -i $PEM_KEY -o ConnectTimeout=10 -o StrictHostKeyChecking=no `
    "$REMOTE_USER@$INSTANCE_IP" $startScript
Log-Ok "Aplicacion iniciada en background"

Start-Sleep -Seconds 3

# 8. Health check
$ok = Wait-Health -ip $INSTANCE_IP -port $SERVER_PORT
if (-not $ok) {
    Log-Warn "Revisa los logs remotos: ssh -i $PEM_KEY $REMOTE_USER@$INSTANCE_IP 'tail -f $REMOTE_DIR/app.log'"
    exit 1
}

# 9. Respuesta final de health
Log-Info "Respuesta completa de /api/health:"
$health = (curl.exe -s "http://${INSTANCE_IP}:${SERVER_PORT}/api/health") -join "`n"
try {
    ($health | ConvertFrom-Json) | ConvertTo-Json -Depth 5
} catch {
    Write-Host $health
}

Log-Ok "=== DEPLOY COMPLETADO EXITOSAMENTE ==="
Log-Info "App corriendo en: http://$INSTANCE_IP`:$SERVER_PORT"
Log-Info "Health: http://$INSTANCE_IP`:$SERVER_PORT/api/health"
Log-Info "Logs remotos: ssh -i $PEM_KEY $REMOTE_USER@$INSTANCE_IP 'tail -f $REMOTE_DIR/app.log'"
