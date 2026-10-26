package com.duoc.cursos;

import io.github.cdimascio.dotenv.Dotenv;
import org.springframework.boot.SpringApplication;
import org.springframework.boot.autoconfigure.SpringBootApplication;
import org.springframework.core.env.ConfigurableEnvironment;
import org.springframework.core.env.MapPropertySource;

import java.util.HashMap;
import java.util.Map;

@SpringBootApplication
public class CursosApplication {

	public static void main(String[] args) {
		// Cargar .env ANTES de inicializar Spring (necesario para DataSource, etc.)
		loadDotenv();

		SpringApplication.run(CursosApplication.class, args);
	}

	private static void loadDotenv() {
		String userDir = System.getProperty("user.dir");
		Dotenv dotenv = Dotenv.configure()
			.directory(userDir)
			.ignoreIfMissing()
			.load();

		if (!dotenv.entries().isEmpty()) {
			Map<String, Object> envMap = new HashMap<>();
			for (var entry : dotenv.entries()) {
				envMap.put(entry.getKey(), entry.getValue());
			}
			// Las variables se leerán via Spring Boot's EnvironmentPostProcessor mechanism
			// pero para que funcione antes de DataSource, las seteamos como system properties
			envMap.forEach((k, v) -> {
				if (System.getProperty(k) == null && System.getenv(k) == null) {
					System.setProperty(k, v.toString());
				}
			});
			// Also set the Spring security oauth2 property using the correct Spring property name
			if (dotenv.entries().stream().anyMatch(e -> "SPRING_SECURITY_OAUTH2_RESOURCESERVER_JWT_ISSUER_URI".equals(e.getKey()))) {
				String val = dotenv.get("SPRING_SECURITY_OAUTH2_RESOURCESERVER_JWT_ISSUER_URI");
				System.setProperty("spring.security.oauth2.resourceserver.jwt.issuer-uri", val);
			}
			// Exponer credenciales AWS con los nombres que espera el AWS SDK
			// (SystemPropertyCredentialsProvider), p.ej. para APIs admin de Cognito
			String awsAk = dotenv.get("AWS_ACCESS_KEY_ID");
			String awsSk = dotenv.get("AWS_SECRET_ACCESS_KEY");
			if (awsAk != null && !awsAk.isBlank() && System.getProperty("aws.accessKeyId") == null) {
				System.setProperty("aws.accessKeyId", awsAk);
				System.setProperty("aws.secretAccessKey", awsSk != null ? awsSk : "");
			}
			System.out.println("✅ Dotenv cargado: " + envMap.size() + " variables desde " + userDir + "/.env");
		} else {
			System.out.println("⚠️  No se encontró .env en " + userDir);
		}
	}
}
