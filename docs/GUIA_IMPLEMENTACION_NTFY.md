# Documento de Integración Local: Notificaciones Push con ntfy (Spring Boot + Android)

Este documento detalla la implementación de un entorno de pruebas **100% libre de Firebase** para enviar notificaciones push a dispositivos específicos, utilizando **Spring Boot** como backend y una aplicación **Android** como receptora, comunicados a través del servidor público y gratuito de `ntfy.sh`.

---

## 1. Arquitectura de Identificación Única (Usuarios Específicos)
Para enviar una notificación a un usuario específico sin usar bases de datos ni seguridad en esta fase, utilizaremos el **Email del usuario transformado en un Hash SHA-256**. Esto creará un "Tópico Secreto" único en `ntfy.sh` que solo el backend y el dispositivo de ese usuario conocerán.

* **Ejemplo:** `usuario@email.com` -> Hash: `9b2d5d...` -> Tópico ntfy: `app_vibe_9b2d5d...`

---

## 2. Implementación en el Backend (Spring Boot)

No necesitas dependencias externas pesadas. Usaremos `RestClient` (disponible desde Spring Boot 3.x) o `RestTemplate` para realizar una petición HTTP POST directa a ntfy.

### Controlador REST y Servicio Integrado

```java
package com.example.notificaciones.controller;

import org.springframework.http.ResponseEntity;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.RequestParam;
import org.springframework.web.bind.annotation.RestController;
import org.springframework.web.client.RestClient;
import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.security.NoSuchAlgorithmException;

@RestController
public class NotificationController {

    private final RestClient restClient = RestClient.create();

    @GetMapping("/api/notificar")
    public ResponseEntity<String> enviarNotificacion(
            @RequestParam String email,
            @RequestParam String message) {
        try {
            // 1. Generar el tópico único basado en el email
            String topic = generarTopicoUnico(email);
            String ntfyUrl = "https://ntfy.sh/" + topic;

            // 2. Enviar la petición POST a ntfy.sh
            String response = restClient.post()
                    .uri(ntfyUrl)
                    .body(message) // El cuerpo del POST es directamente el texto de la notificación
                    .retrieve()
                    .body(String.class);

            return ResponseEntity.ok("Notificación enviada con éxito al tópico: " + topic);
        } catch (Exception e) {
            return ResponseEntity.status(500).body("Error al enviar notificación: " + e.getMessage());
        }
    }

    private String generarTopicoUnico(String email) throws NoSuchAlgorithmException {
        MessageDigest digest = MessageDigest.getInstance("SHA-256");
        byte[] hash = digest.digest(email.trim().toLowerCase().getBytes(StandardCharsets.UTF_8));
        StringBuilder hexString = new StringBuilder();
        for (byte b : hash) {
            String hex = Integer.toHexString(0xff & b);
            if (hex.length() == 1) hexString.append('0');
            hexString.append(hex);
        }
        // Prefijo para evitar colisiones con otros usuarios globales de ntfy
        return "app_vibe_" + hexString.toString().substring(0, 20); 
    }
}
```

### URL de Prueba Local:
```text
GET http://localhost:8080/api/notificar?email=test@example.com&message=Hola desde Spring Boot!
```

---

## 3. Implementación en Mobile (Android)

Dado que no usamos Firebase, la aplicación de Android debe mantener una conexión persistente en segundo plano mediante un **Android Service** usando **Server-Sent Events (SSE)** o **WebSockets**. Aquí usaremos SSE con `OkHttpClient`.

### Paso 1: Agregar Dependencias (`build.gradle.kts`)
```kotlin
dependencies {
    implementation("com.squareup.okhttp3:okhttp:4.12.0")
    // Opcional para facilitar el manejo de JSON en el futuro
}
```

### Paso 2: Configurar Permisos (`AndroidManifest.xml`)
Asegúrate de tener los permisos de internet y de servicio en primer plano para que Android no mate la conexión.

```xml
<manifest xmlns:android="http://schemas.android.com/apk/res/android">
    
    <uses-permission android:name="android.permission.INTERNET" />
    <uses-permission android:name="android.permission.FOREGROUND_SERVICE" />
    <uses-permission android:name="android.permission.POST_NOTIFICATIONS" /> <!-- Requerido en Android 13+ -->

    <application ...>
        
        <service
            android:name=".NotificationService"
            android:enabled="true"
            android:exported="false" />
            
    </application>
</manifest>
```

### Paso 3: Crear el Servicio de Escucha Persistente (`NotificationService.java`)

Este servicio correrá en segundo plano y se conectará al mismo tópico generado por el email del usuario.

```java
package com.example.notificaciones;

import android.app.NotificationChannel;
import android.app.NotificationManager;
import android.app.Service;
import android.content.Intent;
import android.os.Build;
import android.os.IBinder;
import androidx.core.app.NotificationCompat;
import java.io.BufferedReader;
import java.io.InputStreamReader;
import java.net.HttpURLConnection;
import java.net.URL;
import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;

public class NotificationService extends Service {
    private static final String CHANNEL_ID = "PushNotifications";
    private Thread listenThread;
    private boolean isRunning = true;

    @Override
    public int onStartCommand(Intent intent, int flags, int startId) {
        String email = intent.getStringExtra("USER_EMAIL");
        if (email != null) {
            createNotificationChannel();
            startListening(email);
        }
        return START_STICKY;
    }

    private void startListening(String email) {
        String topic = generarTopicoUnico(email);
        String sseUrl = "https://ntfy.sh/" + topic + "/sse";

        listenThread = new Thread(() -> {
            while (isRunning) {
                try {
                    URL url = new URL(sseUrl);
                    HttpURLConnection connection = (HttpURLConnection) url.openConnection();
                    connection.setRequestMethod("GET");
                    connection.setRequestProperty("Accept", "text/event-stream");
                    connection.setReadTimeout(0); // Mantener conexión abierta indefinidamente

                    BufferedReader reader = new BufferedReader(new InputStreamReader(connection.getInputStream()));
                    String line;
                    while (isRunning && (line = reader.readLine()) != null) {
                        if (line.startsWith("data:")) {
                            String eventData = line.substring(5).trim();
                            // El JSON de ntfy contiene el campo "message"
                            if (eventData.contains("\"message\"")) {
                                String msg = extraerMensaje(eventData);
                                mostrarNotificacionPantalla(msg);
                            }
                        }
                    }
                } catch (Exception e) {
                    // Esperar 5 segundos antes de reintentar si se cae la conexión en local
                    try { Thread.sleep(5000); } catch (InterruptedException ignored) {}
                }
            }
        });
        listenThread.start();
    }

    private void mostrarNotificacionPantalla(String mensaje) {
        NotificationManager manager = (NotificationManager) getSystemService(NOTIFICATION_SERVICE);
        NotificationCompat.Builder builder = new NotificationCompat.Builder(this, CHANNEL_ID)
                .setSmallIcon(android.R.drawable.ic_dialog_info)
                .setContentTitle("Nueva Alerta de React/Back")
                .setContentText(mensaje)
                .setPriority(NotificationCompat.PRIORITY_HIGH)
                .setAutoCancel(true);

        manager.notify((int) System.currentTimeMillis(), builder.build());
    }

    private String generarTopicoUnico(String email) {
        try {
            MessageDigest digest = MessageDigest.getInstance("SHA-256");
            byte[] hash = digest.digest(email.trim().toLowerCase().getBytes(StandardCharsets.UTF_8));
            StringBuilder hexString = new StringBuilder();
            for (byte b : hash) {
                String hex = Integer.toHexString(0xff & b);
                if (hex.length() == 1) hexString.append('0');
                hexString.append(hex);
            }
            return "app_vibe_" + hexString.toString().substring(0, 20);
        } catch (Exception e) {
            return "default_topic";
        }
    }

    private String extraerMensaje(String json) {
        // Parseo rústico para pruebas rápidas sin librerías pesadas como Gson/Jackson en el service
        try {
            int start = json.indexOf("\"message\":\"") + 11;
            int end = json.indexOf("\"", start);
            return json.substring(start, end);
        } catch (Exception e) {
            return "Nuevo mensaje recibido";
        }
    }

    private void createNotificationChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            NotificationChannel channel = new NotificationChannel(
                    CHANNEL_ID, "Push Alerts", NotificationManager.IMPORTANCE_HIGH);
            NotificationManager manager = getSystemService(NotificationManager.class);
            if (manager != null) manager.createNotificationChannel(channel);
        }
    }

    @Override
    public void onDestroy() {
        isRunning = false;
        if (listenThread != null) listenThread.interrupt();
        super.onDestroy();
    }

    @Override
    public IBinder onBind(Intent intent) { return null; }
}
```

### Paso 4: Iniciar el Servicio desde tu MainActivity (Al hacer Login)
Cuando simules el login exitoso (o captures el email):

```java
Intent serviceIntent = new Intent(this, NotificationService.class);
serviceIntent.putExtra("USER_EMAIL", "test@example.com");
if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
    startService(serviceIntent);
}
```

---

## 4. Estrategia de Crecimiento (Futuro con React y Seguridad)

Cuando integres tu app de **React (Web/Native)** y desees blindar el sistema:

1. **Desde React:** Para enviar la notificación, el cliente React hará un `POST` seguro a tu endpoint de Spring Boot (`/api/notificar`), autenticado con su token JWT correspondiente.
2. **Seguridad en ntfy:** Cuando instales tu propio servidor ntfy (vía Docker), cerrarás los tópicos para que **solo** tu backend (usando un token de ntfy con permisos de escritura) pueda publicar (`POST`), y los clientes móviles solo tengan permisos de lectura (`GET`) autenticándose con credenciales distribuidas por tu API.
