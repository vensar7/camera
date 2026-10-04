Camera → Yandex.Disk (Flutter)

flutter run

Приложение камеры на Flutter, которое делает фото и видео и загружает их на Yandex.Disk через OAuth.

Что сделано
- UI с предпросмотром камеры, кнопками Фото/Видео
- OAuth-аутентификация через Yandex (flutter_web_auth, implicit flow)
- Загрузка файла на Yandex.Disk через REST API (получение upload href + PUT)
- Хранение access_token в secure storage

Как настроить и запустить

1) Замените client_id и redirect URI
- Откройте файл lib/main.dart
- Замените константу YANDEX_CLIENT_ID на ваш client_id от приложения Yandex OAuth
- REDIRECT_URI должен совпадать с тем, что вы зарегистрируете в настройках приложения Yandex. Пример: com.example.cameraapp://oauth

2) Зарегистрируйте приложение в Yandex OAuth
- Перейдите: https://oauth.yandex.com/
- Создайте новое приложение, укажите Platform: "Native application" или аналогичное
- Укажите Redirect URI с вашим custom scheme (например com.example.cameraapp://oauth)
- Для implicit flow client_secret не обязателен; используется только client_id

Примечание о verification_code flow:
- Если вы указали redirect URI как https://oauth.yandex.com/verification_code, Yandex покажет "verification code" в браузере. В этом режиме приложение откроет страницу авторизации в браузере, пользователь скопирует код и вставит его в приложение. После вставки приложение выполнит обмен кода на access_token.
- Для обмена кода может потребоваться client_secret в зависимости от настроек приложения; приложение запросит client_secret у пользователя в момент обмена.

3) Настройте Android и iOS (обязательное для callback)

Android (android/app/src/main/AndroidManifest.xml)
Добавьте intent-filter в <activity> чтобы ловить callback схемы. Пример:

<intent-filter>
  <action android:name="android.intent.action.VIEW" />
  <category android:name="android.intent.category.DEFAULT" />
  <category android:name="android.intent.category.BROWSABLE" />
  <data android:scheme="com.example.cameraapp" android:host="oauth" />
</intent-filter>

Замените android:scheme на вашу схему (часть до :// в REDIRECT_URI).

iOS (ios/Runner/Info.plist)
Добавьте URL type с идентификатором схемы:

<key>CFBundleURLTypes</key>
<array>
  <dict>
    <key>CFBundleTypeRole</key>
    <string>Editor</string>
    <key>CFBundleURLSchemes</key>
    <array>
      <string>com.example.cameraapp</string>
    </array>
  </dict>
</array>

4) Установите зависимости и запустите
- В корне проекта выполните:
  flutter pub get
- Запустите на устройстве/эмуляторе:
  flutter run

Ограничения и замечания
- Текущая реализация использует implicit flow (response_type=token). Это удобно для мобильных приложений, но обратите внимание на срок жизни токена и права доступа. При необходимости можно реализовать обмен code->token (authorization code) с PKCE или с client_secret на сервере.
- Видео больших размеров загружаются целиком в память в примере (readAsBytes). Для продакшна стоит сделать потоковую загрузку.
- Redirect URI и настройка схемы должны совпадать между Yandex и приложением, иначе callback не сработает.

Если хотите, могу:
- Сделать потоковую (chunked) загрузку больших файлов
- Добавить просмотр загруженных файлов с Yandex.Disk API
- Сделать обмен по authorization code + PKCE (если нужно более защищённое решение)

