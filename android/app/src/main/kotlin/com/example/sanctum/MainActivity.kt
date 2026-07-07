package com.example.sanctum

import android.os.Bundle
import android.view.WindowManager
import io.flutter.embedding.android.FlutterActivity

class MainActivity: FlutterActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        // Prevent screenshots and screen recordings of vault contents
        window.addFlags(WindowManager.LayoutParams.FLAG_SECURE)
    }
}