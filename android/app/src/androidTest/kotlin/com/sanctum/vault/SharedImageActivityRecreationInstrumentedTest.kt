package com.sanctum.vault

import android.content.Intent
import android.net.Uri
import androidx.test.core.app.ActivityScenario
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit

@RunWith(AndroidJUnit4::class)
class SharedImageActivityRecreationInstrumentedTest {
    private val targetContext = InstrumentationRegistry.getInstrumentation().targetContext
    private val providerAuthority =
        InstrumentationRegistry.getInstrumentation().context.packageName + ".hostile"
    private lateinit var cacheManager: SharedImageCacheManager

    @Before
    fun setUp() {
        cacheManager = SharedImageCacheManager(targetContext.cacheDir)
        clearOwnedCache()
        providerControl("reset")
    }

    @After
    fun tearDown() {
        clearOwnedCache()
    }

    @Test
    fun committedUnconsumedSuccessSurvivesRecreationWithoutDuplicateImport() {
        val uri = Uri.parse("content://$providerAuthority/valid-png")
        val intent = Intent(targetContext, MainActivity::class.java).apply {
            action = Intent.ACTION_SEND
            type = "image/png"
            putExtra(Intent.EXTRA_STREAM, uri)
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_GRANT_READ_URI_PERMISSION)
        }

        ActivityScenario.launch<MainActivity>(intent).use { scenario ->
            assertTrue(
                "share was not committed before recreation",
                awaitCondition(10, TimeUnit.SECONDS) {
                    providerOpenCount("valid-png") == 1 &&
                        cacheManager.countOwnedFiles(".img") == 1
                },
            )

            scenario.recreate()

            assertFalse(
                "recreated Activity imported the same Intent twice",
                awaitCondition(2, TimeUnit.SECONDS) {
                    providerOpenCount("valid-png") >= 2
                },
            )
            assertEquals(1, providerOpenCount("valid-png"))
            assertEquals(0, cacheManager.countOwnedFiles(".partial"))
            assertTrue(cacheManager.countOwnedFiles(".img") <= 1)
        }
    }

    private fun awaitCondition(
        timeout: Long,
        unit: TimeUnit,
        condition: () -> Boolean,
    ): Boolean {
        val completed = CountDownLatch(1)
        val executor = Executors.newSingleThreadScheduledExecutor()
        val task = executor.scheduleAtFixedRate(
            { if (condition()) completed.countDown() },
            0,
            20,
            TimeUnit.MILLISECONDS,
        )
        return try {
            completed.await(timeout, unit)
        } finally {
            task.cancel(true)
            executor.shutdownNow()
        }
    }

    private fun providerControl(method: String) {
        val result = targetContext.contentResolver.call(
            Uri.parse("content://$providerAuthority/control"),
            method,
            null,
            null,
        )
        assertTrue(result?.getBoolean("ok") == true)
    }

    private fun providerOpenCount(path: String): Int =
        targetContext.contentResolver.call(
            Uri.parse("content://$providerAuthority/control"),
            "open-count",
            path,
            null,
        )?.getInt("count") ?: 0

    private fun clearOwnedCache() {
        cacheManager.sharedDirectory.listFiles()?.forEach { file ->
            if (file.name.endsWith(".partial") || file.name.endsWith(".img")) file.delete()
        }
    }
}
