package com.duoc.cursos.auth.repository;

import com.duoc.cursos.auth.model.Usuario;
import org.springframework.data.jpa.repository.JpaRepository;
import org.springframework.stereotype.Repository;

@Repository
public interface UsuarioRepository extends JpaRepository<Usuario, String> {
    
    boolean existsByEmail(String email);
}