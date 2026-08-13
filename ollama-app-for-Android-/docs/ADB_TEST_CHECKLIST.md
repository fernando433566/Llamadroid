# Checklist ADB — Ollama Android

Dispositivo de referencia: AVD `Pixel_9`, Android API 35 o superior. Paquete: `com.freakurl.apps.ollama`.

## Compilación e instalación

- [x] `flutter test` termina sin fallos. (61 superadas; 1 omitida por no proporcionar el modelo Whisper.)
- [x] `flutter analyze lib` no contiene errores de compilación. (Solo advertencias no bloqueantes ya registradas.)
- [x] El APK arm64 release compila con `minSdkVersion` y `targetSdkVersion` 35. (versionCode 2007.)
- [x] El APK se instala o actualiza mediante ADB y la actividad principal abre sin cierre inesperado.

## Manifiesto e integración Android

- [x] El APK solicita Internet, micrófono, contactos, teléfono, alarmas, notificaciones, Wake Lock y foreground service.
- [x] `OllamaServerService` y `RpcServerService` aparecen en el manifiesto fusionado.
- [x] `OllamaVoiceInteractionService` aparece como servicio exportado con `BIND_VOICE_INTERACTION` y metadatos `android.voice_interaction`.
- [x] Android muestra Ollama entre los asistentes compatibles y permite establecer su componente por ADB.

## Interfaz de ajustes

- [x] El selector Material 3 muestra `Local`, `Servidor` y `Cloud`.
- [x] Local muestra `127.0.0.1:11434` y no depende de Google Play Services.
- [x] Servidor permite escribir, comprobar y guardar una URL externa.
- [x] Cloud muestra la URL oficial y permite guardar de forma segura una clave API.
- [x] `Advanced options` aparece al final de Ajustes y puede expandirse.
- [x] Advanced options contiene LAN, GGUF, Embedded audio, límite de modelos, motor de cálculo, Synergy y clustering RPC.
- [x] `Enable GGUF Models` habilita la acción `Importar modelo GGUF` al añadir un modelo local.

## Comportamiento en ejecución

- [x] En modo local se inicia el foreground service de Ollama.
- [x] `GET http://127.0.0.1:11434/` devuelve `Ollama is running`.
- [x] El servidor local responde en `/api/tags` sin `Request fail`.
- [x] El modo Servidor conserva su host al cambiar de pantalla o reiniciar la aplicación.
- [x] El modo Cloud no envía su clave al servidor local o externo. (Cubierto por pruebas unitarias.)
- [x] No hay excepciones fatales ni `FATAL EXCEPTION` nuevas en Logcat durante las comprobaciones.

## Asistente

- [x] El panel de Assistant abre y su acceso a Ajustes del asistente no falla.
- [x] El servicio puede seleccionarse como asistente predeterminado.
- [x] Una invocación del asistente no produce `No host specified in URI`.
- [x] Parar/cerrar el panel funciona y no bloquea los toques fuera de su región.
- [x] Una continuación hablada o escrita conserva el contexto hasta cerrar la sesión o expirar los 10 segundos. (Cubierto por pruebas de contexto; sin inferencia real por no haber modelos en el AVD.)

## Pruebas que requieren recursos externos

- [ ] Descargar y eliminar un modelo local pequeño en un dispositivo físico arm64.
- [ ] Generar una respuesta con GPU Adreno/Tensor y comprobar fallback adaptable.
- [ ] Descargar un modelo en un servidor externo con permisos para `/api/pull`.
- [ ] Seleccionar o escribir un modelo de Ollama Cloud con una clave válida.
- [ ] Probar llamadas, contactos, STT y TTS tras conceder permisos en un dispositivo físico.
