package com.duoc.cursos.auth.service;

import com.duoc.cursos.auth.dto.UsuarioResponse;
import com.duoc.cursos.auth.model.Usuario;
import com.duoc.cursos.auth.repository.UsuarioRepository;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;
import software.amazon.awssdk.services.cognitoidentityprovider.CognitoIdentityProviderClient;
import software.amazon.awssdk.services.cognitoidentityprovider.model.*;

import java.nio.charset.StandardCharsets;
import java.util.HashMap;
import java.util.Map;
import java.util.Set;

@Service
public class AuthService {

    private final CognitoIdentityProviderClient cognitoClient;
    private final UsuarioRepository usuarioRepository;

    @Value("${aws.cognito.client-id}")
    private String clientId;

    @Value("${aws.cognito.user-pool-id}")
    private String userPoolId;

    @Value("${aws.cognito.client-secret:}")
    private String clientSecret;

    public AuthService(CognitoIdentityProviderClient cognitoClient, UsuarioRepository usuarioRepository) {
        this.cognitoClient = cognitoClient;
        this.usuarioRepository = usuarioRepository;
    }

    /**
     * FLUJO: REGISTRO Y COPIA LOCAL CON MÚLTIPLES ROLES
     */
    @Transactional
    public UsuarioResponse registrar(String email, String password, String nombre, Set<String> roles) {
        // 1. Registro en Cognito
        SignUpRequest.Builder signUpBuilder = SignUpRequest.builder()
                .clientId(clientId)
                .username(email)
                .password(password)
                .userAttributes(
                        AttributeType.builder().name("email").value(email).build(),
                        AttributeType.builder().name("name").value(nombre).build()
                );

        // Agregar SECRET_HASH si hay client secret
        if (clientSecret != null && !clientSecret.isBlank()) {
            signUpBuilder.secretHash(generateSecretHash(email));
        }

        SignUpResponse signUpResponse = cognitoClient.signUp(signUpBuilder.build());
        String cognitoSub = signUpResponse.userSub();

        // 2. Asignación a Grupos en Cognito (Roles)
        for (String rol : roles) {
            AdminAddUserToGroupRequest groupRequest = AdminAddUserToGroupRequest.builder()
                    .userPoolId(userPoolId)
                    .username(email)
                    .groupName(rol)
                    .build();
            cognitoClient.adminAddUserToGroup(groupRequest);
        }

        // 3. Persistencia en Base de Datos Local
        Usuario usuarioLocal = new Usuario();
        usuarioLocal.setId(cognitoSub);
        usuarioLocal.setEmail(email);
        usuarioLocal.setNombre(nombre);
        usuarioLocal.setRoles(roles);

        Usuario saved = usuarioRepository.save(usuarioLocal);
        
        return UsuarioResponse.builder()
                .id(saved.getId())
                .email(saved.getEmail())
                .nombre(saved.getNombre())
                .roles(saved.getRoles())
                .build();
    }

    /**
     * FLUJO: INICIO DE SESIÓN (LOGIN) PROXY
     */
    public AuthenticationResultType login(String email, String password) {
        Map<String, String> authParameters = new HashMap<>();
        authParameters.put("USERNAME", email);
        authParameters.put("PASSWORD", password);
        if (clientSecret != null && !clientSecret.isBlank()) {
            authParameters.put("SECRET_HASH", generateSecretHash(email));
        }

        InitiateAuthRequest authRequest = InitiateAuthRequest.builder()
                .authFlow(AuthFlowType.USER_PASSWORD_AUTH)
                .clientId(clientId)
                .authParameters(authParameters)
                .build();

        InitiateAuthResponse authResponse = cognitoClient.initiateAuth(authRequest);
        return authResponse.authenticationResult();
    }

    /**
     * FLUJO: CIERRE DE SESIÓN GLOBAL (LOGOUT)
     */
    public void logout(String accessToken) {
        GlobalSignOutRequest signOutRequest = GlobalSignOutRequest.builder()
                .accessToken(accessToken)
                .build();
        cognitoClient.globalSignOut(signOutRequest);
    }

    /**
     * FLUJO: OLVIDÉ MI CONTRASEÑA - PASO 1 (SOLICITUD)
     */
    public void solicitarRecuperacionContrasena(String email) {
        ForgotPasswordRequest.Builder requestBuilder = ForgotPasswordRequest.builder()
                .clientId(clientId)
                .username(email);

        if (clientSecret != null && !clientSecret.isBlank()) {
            requestBuilder.secretHash(generateSecretHash(email));
        }

        cognitoClient.forgotPassword(requestBuilder.build());
    }

    /**
     * FLUJO: OLVIDÉ MI CONTRASEÑA - PASO 2 (CONFIRMACIÓN)
     */
    public void confirmarRecuperacionContrasena(String email, String codigoOtp, String nuevaContrasena) {
        ConfirmForgotPasswordRequest.Builder requestBuilder = ConfirmForgotPasswordRequest.builder()
                .clientId(clientId)
                .username(email)
                .confirmationCode(codigoOtp)
                .password(nuevaContrasena);

        if (clientSecret != null && !clientSecret.isBlank()) {
            requestBuilder.secretHash(generateSecretHash(email));
        }

        cognitoClient.confirmForgotPassword(requestBuilder.build());
    }

    /**
     * Genera SECRET_HASH usando HMAC-SHA256 (username + clientId + clientSecret)
     * Requerido cuando el App Client tiene "Generate client secret" activado
     */
    private String generateSecretHash(String username) {
        try {
            javax.crypto.Mac mac = javax.crypto.Mac.getInstance("HmacSHA256");
            javax.crypto.spec.SecretKeySpec secretKeySpec =
                new javax.crypto.spec.SecretKeySpec(clientSecret.getBytes(StandardCharsets.UTF_8), "HmacSHA256");
            mac.init(secretKeySpec);
            byte[] hash = mac.doFinal((username + clientId).getBytes(StandardCharsets.UTF_8));
            return java.util.Base64.getEncoder().encodeToString(hash);
        } catch (Exception e) {
            throw new RuntimeException("Error generando SECRET_HASH", e);
        }
    }
}