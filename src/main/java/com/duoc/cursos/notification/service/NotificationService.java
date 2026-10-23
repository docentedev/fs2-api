package com.duoc.cursos.notification.service;

import com.duoc.cursos.notification.config.NotificationProperties;
import com.duoc.cursos.notification.dto.NotificationRequest;
import com.duoc.cursos.notification.dto.NotificationResponse;
import lombok.RequiredArgsConstructor;
import org.springframework.http.HttpHeaders;
import org.springframework.http.MediaType;
import org.springframework.stereotype.Service;
import org.springframework.web.client.RestClient;

import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.security.NoSuchAlgorithmException;

@Service
@RequiredArgsConstructor
public class NotificationService {

    private final NotificationProperties properties;
    private final RestClient restClient = RestClient.builder()
            .defaultHeader(HttpHeaders.CONTENT_TYPE, MediaType.TEXT_PLAIN_VALUE)
            .build();

    public NotificationResponse sendNotification(NotificationRequest request) {
        try {
            // 1. Generar el tópico único basado en el email
            String topic = generateTopic(request.getEmail());
            String ntfyUrl = properties.getBaseUrl() + "/" + topic;

            // 2. Construir body con información adicional si se proporciona
            String body = buildBody(request);

            // 3. Enviar la petición POST a ntfy.sh
            String ntfyResponse = restClient.post()
                    .uri(ntfyUrl)
                    .headers(headers -> {
                        if (request.getTitle() != null && !request.getTitle().isBlank()) {
                            headers.set("Title", request.getTitle());
                        }
                        if (request.getTags() != null && !request.getTags().isBlank()) {
                            headers.set("Tags", request.getTags());
                        }
                        if (request.getPriority() != null) {
                            headers.set("Priority", String.valueOf(request.getPriority()));
                        }
                    })
                    .body(body)
                    .retrieve()
                    .body(String.class);

            return NotificationResponse.builder()
                    .success(true)
                    .topic(topic)
                    .message("Notificación enviada con éxito")
                    .ntfyResponse(ntfyResponse)
                    .build();

        } catch (Exception e) {
            return NotificationResponse.builder()
                    .success(false)
                    .topic(generateTopic(request.getEmail()))
                    .message("Error al enviar notificación: " + e.getMessage())
                    .build();
        }
    }

    public String generateTopic(String email) {
        try {
            MessageDigest digest = MessageDigest.getInstance("SHA-256");
            byte[] hash = digest.digest(email.trim().toLowerCase().getBytes(StandardCharsets.UTF_8));
            StringBuilder hexString = new StringBuilder();
            for (byte b : hash) {
                String hex = Integer.toHexString(0xff & b);
                if (hex.length() == 1) hexString.append('0');
                hexString.append(hex);
            }
            return properties.getTopicPrefix() + hexString.toString().substring(0, properties.getTopicHashLength());
        } catch (NoSuchAlgorithmException e) {
            throw new IllegalStateException("SHA-256 no disponible", e);
        }
    }

    private String buildBody(NotificationRequest request) {
        StringBuilder body = new StringBuilder();
        body.append(request.getMessage());
        return body.toString();
    }
}