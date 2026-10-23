package com.duoc.cursos.notification.config;

import org.springframework.boot.context.properties.ConfigurationProperties;
import org.springframework.stereotype.Component;

@Component
@ConfigurationProperties(prefix = "app.notification")
public class NotificationProperties {

    /**
     * URL base del servidor ntfy (ej: https://ntfy.sh)
     */
    private String baseUrl = "https://ntfy.sh";

    /**
     * Prefijo para los tópicos (evita colisiones en servidor público)
     */
    private String topicPrefix = "app_vibe_";

    /**
     * Longitud del hash a usar en el tópico (max 64 para SHA-256)
     */
    private int topicHashLength = 20;

    /**
     * Timeout de conexión en segundos
     */
    private int connectTimeout = 10;

    /**
     * Timeout de lectura en segundos
     */
    private int readTimeout = 30;

    // Getters y Setters
    public String getBaseUrl() {
        return baseUrl;
    }

    public void setBaseUrl(String baseUrl) {
        this.baseUrl = baseUrl;
    }

    public String getTopicPrefix() {
        return topicPrefix;
    }

    public void setTopicPrefix(String topicPrefix) {
        this.topicPrefix = topicPrefix;
    }

    public int getTopicHashLength() {
        return topicHashLength;
    }

    public void setTopicHashLength(int topicHashLength) {
        this.topicHashLength = topicHashLength;
    }

    public int getConnectTimeout() {
        return connectTimeout;
    }

    public void setConnectTimeout(int connectTimeout) {
        this.connectTimeout = connectTimeout;
    }

    public int getReadTimeout() {
        return readTimeout;
    }

    public void setReadTimeout(int readTimeout) {
        this.readTimeout = readTimeout;
    }
}