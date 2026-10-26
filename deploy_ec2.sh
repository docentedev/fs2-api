#!/bin/bash
set -euo pipefail

# ============================================
# CONFIGURACIÓN - MODIFICA ESTOS VALORES
# ============================================
SERVER_PORT=8080
INSTANCE_EC2_ID='i-034c79128b1fa7373'
PEM_KEY='mi-llave-privada.pem'
LOCAL_ENV_FILE='.env'
PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REMOTE_USER='ec2-user'
REMOTE_DIR='/home/ec2-user'
JAR_NAME='cursos-0.0.1-SNAPSHOT.jar'

# Colores para output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

log_info()    { echo -e "${BLUE}[INFO]${NC} $*"; }
log_success() { echo -e "${GREEN}[OK]${NC} $*"; }
log_warn()    { echo -e "${YELLOW}[WARN]${NC} $*"; }
log_error()   { echo -e "${RED}[ERROR]${NC} $*"; }

# ============================================
# FUNCIONES AUXILIARES
# ============================================

get_instance_ip() {
    aws ec2 describe-instances \
        --instance-ids "$INSTANCE_EC2_ID" \
        --query "Reservations[0].Instances[0].PublicIpAddress" \
        --output text 2>/dev/null
}

check_pem_key() {
    if [[ ! -f "$PEM_KEY" ]]; then
        log_error "No se encuentra la llave PEM: $PEM_KEY"
        exit 1
    fi
    chmod 400 "$PEM_KEY"
}

check_local_env() {
    if [[ ! -f "$LOCAL_ENV_FILE" ]]; then
        log_error "No se encuentra archivo .env local: $LOCAL_ENV_FILE"
        exit 1
    fi
}

load_env_to_vars() {
    log_info "Cargando variables desde $LOCAL_ENV_FILE..."
    # Exportar todas las variables del .env (ignorando comentarios y líneas vacías)
    set -a
    source "$LOCAL_ENV_FILE"
    set +a
    log_success "Variables de entorno cargadas ($(grep -c '^[A-Z_][A-Z0-9_]*=' "$LOCAL_ENV_FILE" || echo 0) variables)"
}

check_java_local() {
    log_info "Verificando Java 21 en local..."
    if command -v java &>/dev/null; then
        JAVA_VERSION=$(java -version 2>&1 | head -n1 | awk -F '"' '{print $2}' | cut -d'.' -f1)
        if [[ "$JAVA_VERSION" -ge 21 ]]; then
            log_success "Java $JAVA_VERSION encontrado localmente"
        else
            log_warn "Java $JAVA_VERSION < 21, se necesitará Java 21 para compilar"
        fi
    else
        log_warn "Java no encontrado en local"
    fi
}

wait_for_port_free() {
    local ip="$1"
    local port="$2"
    local timeout=60
    local elapsed=0
    
    log_info "Esperando que puerto $port se libere en $ip..."
    while ssh -i "$PEM_KEY" -o ConnectTimeout=5 -o StrictHostKeyChecking=no "$REMOTE_USER@$ip" "ss -tlnp | grep :$port" &>/dev/null; do
        if [[ $elapsed -ge $timeout ]]; then
            log_warn "Timeout: Puerto $port no se liberó limpiamente, forzando con SO_REUSEADDR..."
            # Intentar matar más agresivamente y esperar un poco más
            ssh -i "$PEM_KEY" -o ConnectTimeout=5 -o StrictHostKeyChecking=no "$REMOTE_USER@$ip" "
                sudo fuser -k ${port}/tcp 2>/dev/null || true
                pkill -9 java 2>/dev/null || true
                sleep 2
            " || true
            return 0  # Continuar anyway, Java permite SO_REUSEADDR
        fi
        sleep 2
        elapsed=$((elapsed + 2))
    done
    log_success "Puerto $port libre"
}

wait_for_health() {
    local ip="$1"
    local port="$2"
    local timeout=60
    local elapsed=0
    
    log_info "Esperando health check en http://$ip:$port/api/health..."
    while ! curl -sf "http://$ip:$port/api/health" &>/dev/null; do
        if [[ $elapsed -ge $timeout ]]; then
            log_error "Timeout: Health check no respondió OK después de ${timeout}s"
            return 1
        fi
        sleep 3
        elapsed=$((elapsed + 3))
        echo -n "."
    done
    echo ""
    log_success "Health check OK!"
}

# ============================================
# MAIN
# ============================================

main() {
    log_info "=== INICIANDO DEPLOY A EC2 ==="
    log_info "Instance ID: $INSTANCE_EC2_ID"
    log_info "Puerto: $SERVER_PORT"
    log_info "Key: $PEM_KEY"

    # 1. Validaciones previas
    check_pem_key
    check_local_env
    load_env_to_vars
    check_java_local

    # 2. Obtener IP de la instancia
    log_info "Obteniendo IP pública de la instancia..."
    INSTANCE_IP=$(get_instance_ip)
    if [[ -z "$INSTANCE_IP" || "$INSTANCE_IP" == "None" ]]; then
        log_error "No se pudo obtener IP para instance $INSTANCE_EC2_ID"
        exit 1
    fi
    log_success "Instance IP: $INSTANCE_IP"

    # 3. Verificar puerto en remoto ANTES de compilar
    log_info "Verificando puerto $SERVER_PORT en instancia remota..."
    if ssh -i "$PEM_KEY" -o ConnectTimeout=10 -o StrictHostKeyChecking=no "$REMOTE_USER@$INSTANCE_IP" "ss -tlnp | grep :$SERVER_PORT" &>/dev/null; then
        log_warn "Puerto $SERVER_PORT ocupado en remoto, se matará proceso después"
    else
        log_success "Puerto $SERVER_PORT libre en remoto"
    fi

    # 4. Build local con Gradle
    log_info "Compilando proyecto con Gradle (clean bootJar)..."
    cd "$PROJECT_DIR"
    if ./gradlew clean bootJar --no-daemon; then
        log_success "Build exitoso"
    else
        log_error "Falló la compilación"
        exit 1
    fi

    # Verificar que existe el JAR
    JAR_PATH="$PROJECT_DIR/build/libs/$JAR_NAME"
    if [[ ! -f "$JAR_PATH" ]]; then
        log_error "No se encontró JAR en $JAR_PATH"
        exit 1
    fi
    log_success "JAR generado: $JAR_PATH ($(du -h "$JAR_PATH" | cut -f1))"

    # 5. Subir .env a la instancia (primero para que la app lo lea al arrancar)
    log_info "Subiendo .env a instancia..."
    scp -i "$PEM_KEY" -o StrictHostKeyChecking=no "$LOCAL_ENV_FILE" "$REMOTE_USER@$INSTANCE_IP:$REMOTE_DIR/.env"
    log_success ".env subido a $REMOTE_DIR/.env"

    # 6. Subir JAR a la instancia
    log_info "Subiendo JAR a instancia..."
    scp -i "$PEM_KEY" -o StrictHostKeyChecking=no "$JAR_PATH" "$REMOTE_USER@$INSTANCE_IP:$REMOTE_DIR/$JAR_NAME"
    log_success "JAR subido a $REMOTE_DIR/$JAR_NAME"

    # 7. Matar procesos en el puerto en remoto
    log_info "Matando procesos en puerto $SERVER_PORT en remoto..."
    ssh -i "$PEM_KEY" -o ConnectTimeout=10 -o StrictHostKeyChecking=no "$REMOTE_USER@$INSTANCE_IP" "
        # Detener servicio systemd que use el puerto (ej: cloud-usuarios-bff)
        sudo systemctl stop cloud-usuarios-bff 2>/dev/null || true
        sudo systemctl disable cloud-usuarios-bff 2>/dev/null || true
        
        # Matar TODOS los procesos que usen el puerto (requiere sudo)
        sudo fuser -k ${SERVER_PORT}/tcp 2>/dev/null || true
        sudo pkill -9 java 2>/dev/null || true
        
        # Buscar y matar específicamente por puerto usando ss
        for pid in \$(sudo ss -tlnp | grep :${SERVER_PORT} | grep -oP 'pid=\\K[0-9]+' | sort -u); do
            sudo kill -9 \$pid 2>/dev/null || true
        done
        
        # Verificar con lsof también
        for pid in \$(sudo lsof -ti :${SERVER_PORT} 2>/dev/null | sort -u); do
            sudo kill -9 \$pid 2>/dev/null || true
        done
        
        sleep 5
    "
    wait_for_port_free "$INSTANCE_IP" "$SERVER_PORT"

    # 8. Verificar/instalar Java 21 en remoto
    log_info "Verificando Java 21 en instancia remota..."
    ssh -i "$PEM_KEY" -o ConnectTimeout=10 -o StrictHostKeyChecking=no "$REMOTE_USER@$INSTANCE_IP" "
        if command -v java &>/dev/null; then
            JAVA_VER=\$(java -version 2>&1 | head -n1 | awk -F '\"' '{print \$2}' | cut -d'.' -f1)
            if [[ \$JAVA_VER -ge 21 ]]; then
                echo 'Java 21+ ya instalado: '\$(java -version 2>&1 | head -n1)
                exit 0
            fi
        fi
        echo 'Instalando Java 21...'
        if command -v dnf &>/dev/null; then
            sudo dnf install -y java-21-amazon-corretto-devel
        elif command -v apt &>/dev/null; then
            sudo apt update && sudo apt install -y openjdk-21-jdk
        elif command -v yum &>/dev/null; then
            sudo yum install -y java-21-amazon-corretto-devel
        else
            echo 'No se pudo determinar package manager'
            exit 1
        fi
        java -version
    "
    log_success "Java 21 verificado/instalado en remoto"

    # 9. Arrancar aplicación en remoto
    log_info "Arrancando aplicación en puerto $SERVER_PORT..."
    ssh -i "$PEM_KEY" -o ConnectTimeout=10 -o StrictHostKeyChecking=no "$REMOTE_USER@$INSTANCE_IP" "
        cd $REMOTE_DIR
        nohup java -Dserver.port=$SERVER_PORT -Dspring.socket.reuseAddress=true -jar $JAR_NAME > app.log 2>&1 &
        echo \$! > app.pid
        echo 'PID: '\$(cat app.pid)
    "
    log_success "Aplicación iniciada en background"
    
    # Pequeña pausa para que el socket bindee
    sleep 3

    # 10. Esperar health check
    wait_for_health "$INSTANCE_IP" "$SERVER_PORT"

    # 11. Mostrar respuesta final de health
    log_info "Respuesta completa de /api/health:"
    curl -s "http://$INSTANCE_IP:$SERVER_PORT/api/health" | jq . 2>/dev/null || curl -s "http://$INSTANCE_IP:$SERVER_PORT/api/health"

    log_success "=== DEPLOY COMPLETADO EXITOSAMENTE ==="
    log_info "App corriendo en: http://$INSTANCE_IP:$SERVER_PORT"
    log_info "Health: http://$INSTANCE_IP:$SERVER_PORT/api/health"
    log_info "Login:  http://$INSTANCE_IP:$SERVER_PORT/api/auth/login"
    log_info "Logs remotos: ssh -i $PEM_KEY $REMOTE_USER@$INSTANCE_IP 'tail -f $REMOTE_DIR/app.log'"
}

# Ejecutar main
main "$@"