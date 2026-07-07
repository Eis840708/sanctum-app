# Flutter wrapper
-keep class io.flutter.app.** { *; }
-keep class io.flutter.plugin.** { *; }
-keep class io.flutter.util.** { *; }
-keep class io.flutter.view.** { *; }
-keep class io.flutter.** { *; }
-keep class io.flutter.plugins.** { *; }

# Keep Flutter engine
-keep class io.flutter.embedding.** { *; }

# Hive
-keep class com.hivedb.** { *; }
-keep @com.hivedb.annotations.HiveType class * { *; }

# Keep generated Hive adapters
-keep class **$HiveAdapter { *; }
-keep class **TypeAdapter { *; }

# Kotlin
-keep class kotlin.** { *; }
-keep class kotlin.Metadata { *; }
-dontwarn kotlin.**
-keepclassmembers class **$WhenMappings {
    <fields>;
}

# Google ML Kit (required by mobile_scanner)
-keep class com.google.mlkit.** { *; }
-keep class com.google.mlkit.common.** { *; }
-keep class com.google.mlkit.vision.** { *; }
-keep class com.google.mlkit.common.internal.CommonComponentRegistrar { *; }
-keep class com.google.mlkit.vision.barcode.internal.BarcodeRegistrar { *; }
-keep class com.google.mlkit.vision.common.internal.VisionCommonRegistrar { *; }
-keep class * implements com.google.android.gms.common.internal.safeparcel.SafeParcelable { *; }

# Google Play Services
-keep class com.google.android.gms.** { *; }
-dontwarn com.google.android.gms.**

# Suppress warnings
-dontwarn io.flutter.**
-dontwarn com.google.**
