package com.duoc.cursos.notification.controller;

import com.duoc.cursos.common.dto.ApiResponse;
import com.duoc.cursos.notification.dto.NotificationRequest;
import com.duoc.cursos.notification.dto.NotificationResponse;
import com.duoc.cursos.notification.service.NotificationService;
import jakarta.validation.Valid;
import lombok.RequiredArgsConstructor;
import org.springframework.http.ResponseEntity;
import org.springframework.web.bind.annotation.*;

@RestController
@RequestMapping("/api/notificar")
@RequiredArgsConstructor
public class NotificationController {

    private final NotificationService notificationService;

    @PostMapping
    public ResponseEntity<ApiResponse<NotificationResponse>> enviarNotificacion(@Valid @RequestBody NotificationRequest request) {
        NotificationResponse response = notificationService.sendNotification(request);
        
        if (response.isSuccess()) {
            return ResponseEntity.ok(ApiResponse.ok(response, "Notificación enviada exitosamente"));
        } else {
            return ResponseEntity.badRequest().body(ApiResponse.error(response.getMessage()));
        }
    }

    @GetMapping("/topic/{email}")
    public ResponseEntity<ApiResponse<String>> obtenerTopico(@PathVariable String email) {
        String topic = notificationService.generateTopic(email);
        return ResponseEntity.ok(ApiResponse.ok(topic, "Tópico generado para el email"));
    }
}