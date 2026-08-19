# Flutter's own rules are injected by the Flutter Gradle plugin; these cover
# the native-bridge packages R8 can't see into.
-keep class com.alexmercerind.** { *; }
-keep class media.kit.** { *; }
-keep class dev.flutter.** { *; }
# speech_to_text reflection
-keep class com.csdcorp.speech_to_text.** { *; }
