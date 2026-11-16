# Flutter & native app keep rules
-keep class com.sideassistant.side_assistant.** { *; }
-keepattributes *Annotation*,Signature,InnerClasses,EnclosingMethod

# Guava / JSR305 / ErrorProne optional compile-time annotations
-dontwarn javax.annotation.**
-dontwarn org.codehaus.mojo.animal_sniffer.**
-dontwarn com.google.errorprone.annotations.**
-dontwarn org.checkerframework.**
-dontwarn com.google.j2objc.annotations.**
