package com.duoc.cursos.health.controller;

import com.duoc.cursos.common.dto.ApiResponse;
import lombok.Builder;
import lombok.Data;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RestController;

import java.time.Instant;

@RestController
@RequestMapping("/api")
public class HealthController {

    @GetMapping("/health")
    public ApiResponse<HealthResponse> health() {
        return ApiResponse.ok(HealthResponse.builder()
                .status("UP")
                .timestamp(Instant.now().toString())
                .service("cursos-api")
                .build());
    }

    @Data
    @Builder
    public static class HealthResponse {
        private String status;
        private String timestamp;
        private String service;
    }
}