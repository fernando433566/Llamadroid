// ignore: unused_import
import 'package:intl/intl.dart' as intl;
import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for Spanish Castilian (`es`).
class AppLocalizationsEs extends AppLocalizations {
  AppLocalizationsEs([String locale = 'es']) : super(locale);

  @override
  String get appTitle => 'Ollama';

  @override
  String get optionNewChat => 'Nuevo chat';

  @override
  String get optionSettings => 'Ajustes';

  @override
  String get optionNoChatFound => 'No se encontraron chats';

  @override
  String get tipPrefix => 'Consejo: ';

  @override
  String get tip0 => 'Edita los mensajes manteniéndolos pulsados';

  @override
  String get tip1 => 'Elimina mensajes pulsándolos dos veces';

  @override
  String get tip2 => 'Puedes cambiar el tema en los ajustes';

  @override
  String get tip3 => 'Selecciona un modelo multimodal para añadir imágenes';

  @override
  String get tip4 => 'Los chats se guardan automáticamente';

  @override
  String get takeImage => 'Hacer foto';

  @override
  String get uploadImage => 'Subir imagen';

  @override
  String get notAValidImage => 'La imagen no es válida';

  @override
  String get imageOnlyConversation => 'Conversación solo con imágenes';

  @override
  String get messageInputPlaceholder => 'Mensaje';

  @override
  String get noModelSelected => 'No se ha seleccionado ningún modelo';

  @override
  String get noHostSelected =>
      'No se ha seleccionado un servidor; abre Ajustes para configurarlo';

  @override
  String get noSelectedModel => '<seleccionar>';

  @override
  String get newChatTitle => 'Chat sin nombre';

  @override
  String get modelDialogAddModel => 'Añadir';

  @override
  String get modelDialogAddSteps =>
      'No se pueden añadir modelos desde aquí. Añádelos en el servidor.';

  @override
  String get deleteDialogTitle => 'Eliminar chat';

  @override
  String get deleteDialogDescription =>
      '¿Quieres continuar? Se borrará la memoria de este chat y no se puede deshacer.\nPuedes desactivar este diálogo en Ajustes.';

  @override
  String get deleteDialogDelete => 'Eliminar';

  @override
  String get deleteDialogCancel => 'Cancelar';

  @override
  String get dialogEnterNewTitle => 'Introduce el nuevo título';

  @override
  String get dialogEditMessageTitle => 'Editar mensaje';

  @override
  String get settingsTitleBehavior => 'Comportamiento';

  @override
  String get settingsTitleInterface => 'Interfaz';

  @override
  String get settingsTitleExport => 'Exportar';

  @override
  String get settingsTitleContact => 'Contacto';

  @override
  String get settingsHost => 'Servidor';

  @override
  String get settingsHostValid => 'Servidor válido';

  @override
  String get settingsHostChecking => 'Comprobando servidor';

  @override
  String settingsHostInvalid(String type) {
    String _temp0 = intl.Intl.selectLogic(
      type,
      {
        'url': 'URL no válida',
        'host': 'Servidor no válido',
        'timeout': 'La solicitud falló por problemas del servidor',
        'other': 'La solicitud falló',
      },
    );
    return 'Problema: $_temp0';
  }

  @override
  String get settingsHostHeaderTitle => 'Configurar cabecera del servidor';

  @override
  String get settingsHostHeaderInvalid =>
      'El texto no es un objeto JSON de cabeceras válido';

  @override
  String settingsHostInvalidDetailed(String type) {
    String _temp0 = intl.Intl.selectLogic(
      type,
      {
        'url': 'La URL introducida no tiene un formato estándar válido.',
        'other':
            'No se puede acceder al servidor introducido. Comprueba la dirección e inténtalo de nuevo.',
      },
    );
    return '$_temp0';
  }

  @override
  String get settingsSystemMessage => 'Mensaje del sistema';

  @override
  String get settingsDisableMarkdown => 'Desactivar Markdown';

  @override
  String get settingsBehaviorNotUpdatedForOlderChats =>
      'Los cambios de comportamiento no se aplican a chats antiguos. Inicia uno nuevo para utilizarlos.';

  @override
  String get settingsGenerateTitles => 'Generar títulos';

  @override
  String get settingsAskBeforeDelete => 'Preguntar antes de eliminar';

  @override
  String get settingsResetOnModelChange => 'Reiniciar al cambiar de modelo';

  @override
  String get settingsEnableEditing => 'Permitir editar mensajes';

  @override
  String get settingsShowTips => 'Mostrar consejos';

  @override
  String get settingsShowModelTags => 'Mostrar etiquetas de modelos';

  @override
  String get settingsBrightnessSystem => 'Sistema';

  @override
  String get settingsBrightnessLight => 'Claro';

  @override
  String get settingsBrightnessDark => 'Oscuro';

  @override
  String get settingsBrightnessRestartTitle => 'Es necesario reiniciar';

  @override
  String get settingsBrightnessRestartDescription =>
      'Cambiar el tema requiere reiniciar.\n¿Quieres reiniciar ahora o cancelar?';

  @override
  String get settingsBrightnessRestartRestart => 'Reiniciar';

  @override
  String get settingsBrightnessRestartCancel => 'Cancelar';

  @override
  String get settingsExportChats => 'Exportar chats';

  @override
  String get settingsImportChats => 'Importar chats';

  @override
  String get settingsImportChatsTitle => 'Importar';

  @override
  String get settingsImportChatsDescription =>
      'Se importarán los chats del archivo seleccionado y se sobrescribirán los chats actuales.\n¿Quieres continuar?';

  @override
  String get settingsImportChatsImport => 'Importar y borrar';

  @override
  String get settingsImportChatsCancel => 'Cancelar';

  @override
  String get settingsImportChatsSuccess => 'Chats importados correctamente';

  @override
  String get settingsUpdateCheck => 'Buscar actualizaciones';

  @override
  String get settingsUpdateChecking => 'Buscando actualizaciones…';

  @override
  String get settingsUpdateLatest => 'Estás usando la versión más reciente';

  @override
  String settingsUpdateAvailable(String version) {
    return 'Actualización disponible (v$version)';
  }

  @override
  String get settingsUpdateRateLimit =>
      'No se puede comprobar: se alcanzó el límite de la API';

  @override
  String get settingsUpdateIssue => 'Se produjo un problema';

  @override
  String get settingsUpdateDialogTitle => 'Nueva versión disponible';

  @override
  String get settingsUpdateDialogDescription =>
      'Hay una nueva versión de Ollama. ¿Quieres descargarla e instalarla?';

  @override
  String get settingsUpdateChangeLog => 'Registro de cambios';

  @override
  String get settingsUpdateDialogUpdate => 'Actualizar';

  @override
  String get settingsUpdateDialogCancel => 'Cancelar';

  @override
  String get settingsCheckForUpdates =>
      'Buscar actualizaciones al abrir Ajustes';

  @override
  String get settingsGithub => 'GitHub';

  @override
  String get settingsReportIssue => 'Informar de un problema';

  @override
  String get settingsMainDeveloper => 'Desarrollador principal';
}
