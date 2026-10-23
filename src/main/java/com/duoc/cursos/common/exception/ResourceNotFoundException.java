package com.duoc.cursos.common.exception;

public class ResourceNotFoundException extends BusinessException {
    public ResourceNotFoundException(String resourceName, String field, Object value) {
        super("RESOURCE_NOT_FOUND", 
            String.format("%s no encontrado con %s: %s", resourceName, field, value));
    }
}