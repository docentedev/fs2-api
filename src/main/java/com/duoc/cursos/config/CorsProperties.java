package com.duoc.cursos.config;

import lombok.Getter;
import lombok.Setter;
import org.springframework.boot.context.properties.ConfigurationProperties;
import org.springframework.stereotype.Component;

@Setter
@Getter
@Component
@ConfigurationProperties(prefix = "app.cors")
public class CorsProperties {

    // Getters y Setters
    /**
     * Habilita o deshabilita CORS completamente.
     * Cuando pasa por API Gateway, se puede deshabilitar poniendo este valor en false.
     */
    private boolean enabled = true;

    /**
     * Orígenes permitidos. Usa "*" para permitir todos.
     * Ejemplo: "<a href="https://app.midominio.com,https://otro.dominio.com">...</a>"
     */
    private String allowedOrigins = "*";

    /**
     * Métodos HTTP permitidos
     */
    private String allowedMethods = "GET,POST,PUT,PATCH,DELETE,OPTIONS";

    /**
     * Headers permitidos
     */
    private String allowedHeaders = "*";

    /**
     * Headers expuestos al cliente
     */
    private String exposedHeaders = "Authorization,Content-Type";

    /**
     * Permitir credenciales (cookies, authorization headers)
     * Nota: Si allowedOrigins es "*", esto debe ser false por seguridad
     */
    private boolean allowCredentials = false;

    /**
     * Tiempo máximo de cache para preflight requests (en segundos)
     */
    private long maxAge = 3600;

}