package com.duoc.cursos.auth.controller;

import com.duoc.cursos.auth.dto.UsuarioResponse;
import com.duoc.cursos.auth.service.AuthService;
import com.duoc.cursos.common.dto.ApiResponse;
import lombok.RequiredArgsConstructor;
import org.springframework.http.ResponseEntity;
import org.springframework.security.access.prepost.PreAuthorize;
import org.springframework.web.bind.annotation.*;

import java.util.List;

@RestController
@RequestMapping("/api/usuarios")
@RequiredArgsConstructor
public class UsuarioController {

    private final AuthService authService;

    @GetMapping
    @PreAuthorize("hasRole('ADMIN') or hasAuthority('ADMIN')")
    public ResponseEntity<ApiResponse<List<UsuarioResponse>>> listarUsuarios() {
        List<UsuarioResponse> usuarios = authService.listarUsuarios();
        return ResponseEntity.ok(ApiResponse.ok(usuarios, "Usuarios obtenidos exitosamente"));
    }

    @DeleteMapping("/{id}")
    @PreAuthorize("hasRole('ADMIN') or hasAuthority('ADMIN')")
    public ResponseEntity<ApiResponse<Void>> eliminarUsuario(@PathVariable String id) {
        authService.eliminarUsuario(id);
        return ResponseEntity.ok(ApiResponse.ok(null, "Usuario eliminado exitosamente"));
    }

    @PatchMapping("/{id}/baja")
    @PreAuthorize("hasRole('ADMIN') or hasAuthority('ADMIN')")
    public ResponseEntity<ApiResponse<UsuarioResponse>> darDeBaja(@PathVariable String id) {
        UsuarioResponse usuario = authService.cambiarEstadoUsuario(id, false);
        return ResponseEntity.ok(ApiResponse.ok(usuario, "Usuario dado de baja exitosamente"));
    }

    @PatchMapping("/{id}/alta")
    @PreAuthorize("hasRole('ADMIN') or hasAuthority('ADMIN')")
    public ResponseEntity<ApiResponse<UsuarioResponse>> reactivarUsuario(@PathVariable String id) {
        UsuarioResponse usuario = authService.cambiarEstadoUsuario(id, true);
        return ResponseEntity.ok(ApiResponse.ok(usuario, "Usuario reactivado exitosamente"));
    }
}