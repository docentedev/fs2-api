package com.duoc.cursos.auth.dto;

import lombok.Data;

@Data
public class LoginResponse {
    private String accessToken;
    private String idToken;
    private String refreshToken;
    private Integer expiresIn;
}