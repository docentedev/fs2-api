package com.duoc.cursos.notification.dto;

import lombok.Builder;
import lombok.Data;

@Data
@Builder
public class NotificationResponse {
    private boolean success;
    private String topic;
    private String message;
    private String ntfyResponse;
}