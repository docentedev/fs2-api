package com.duoc.cursos.notification.dto;

import jakarta.validation.constraints.Email;
import jakarta.validation.constraints.NotBlank;
import jakarta.validation.constraints.Size;
import lombok.Data;

@Data
public class NotificationRequest {
    @NotBlank @Email
    private String email;

    @NotBlank @Size(max = 5000)
    private String message;

    private String title;
    private String tags;
    private Integer priority; // 1-5 (min, low, default, high, urgent)
}