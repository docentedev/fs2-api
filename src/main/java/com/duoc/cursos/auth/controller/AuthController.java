package com.duoc.cursos.auth.controller;

import com.duoc.cursos.auth.dto.*;
import com.duoc.cursos.auth.service.AuthService;
import com.duoc.cursos.common.dto.ApiResponse;

import jakarta.validation.Valid;
import lombok.RequiredArgsConstructor;

import org.springframework.http.ResponseEntity;
import org.springframework.security.access.prepost.PreAuthorize;
import org.springframework.web.bind.annotation.*;

import software.amazon.awssdk.services.cognitoidentityprovider.model.AuthenticationResultType;

@RestController
@RequestMapping("/api/auth")
@RequiredArgsConstructor
public class AuthController {

    private final AuthService authService;

    @PostMapping("/registro")
    @PreAuthorize("hasRole('ADMIN') or hasAuthority('ADMIN')")
    public ResponseEntity<ApiResponse<UsuarioResponse>> registrar(@Valid @RequestBody RegistroRequest req) {
        UsuarioResponse usuario = authService.registrar(req.getEmail(), req.getPassword(), req.getNombre(), req.getRoles(), req.getTelefono());
        return ResponseEntity.ok(ApiResponse.ok(usuario, "Usuario registrado exitosamente"));
    }

    @PostMapping("/login")
    public ResponseEntity<ApiResponse<LoginResponse>> login(@Valid @RequestBody LoginRequest req) {
        AuthenticationResultType result = authService.login(req.getEmail(), req.getPassword());

        LoginResponse response = new LoginResponse();
        response.setAccessToken(result.accessToken());
        response.setIdToken(result.idToken());
        response.setRefreshToken(result.refreshToken());
        response.setExpiresIn(result.expiresIn());

        return ResponseEntity.ok(ApiResponse.ok(response, "Login exitoso"));
    }

    @PostMapping("/logout")
    public ResponseEntity<ApiResponse<Void>> logout(@RequestHeader(value = "Authorization", required = false) String bearerToken) {
        if (bearerToken == null || !bearerToken.startsWith("Bearer ")) {
            return ResponseEntity.badRequest().body(ApiResponse.error("Token de autorización requerido"));
        }
        String accessToken = bearerToken.substring(7);
        authService.logout(accessToken);
        return ResponseEntity.ok(ApiResponse.ok(null, "Logout exitoso"));
    }

    @PostMapping("/olvide-contrasena/solicitar")
    public ResponseEntity<ApiResponse<Void>> solicitarPassword(@Valid @RequestBody SolicitudPasswordRequest req) {
        authService.solicitarRecuperacionContrasena(req.getEmail());
        return ResponseEntity.ok(ApiResponse.ok(null, "Código de recuperación enviado al email"));
    }

    @PostMapping("/olvide-contrasena/confirmar")
    public ResponseEntity<ApiResponse<Void>> confirmarPassword(@Valid @RequestBody ConfirmarPasswordRequest req) {
        authService.confirmarRecuperacionContrasena(req.getEmail(), req.getCodigo(), req.getNuevaContrasena());
        return ResponseEntity.ok(ApiResponse.ok(null, "Contraseña actualizada exitosamente"));
    }
}