package com.duoc.cursos.auth.dto;

import lombok.Builder;
import lombok.Data;
import java.util.Set;

@Data
@Builder
public class UsuarioResponse {
    private String id;
    private String email;
    private String nombre;
    private Set<String> roles;
    private Boolean activo;
}