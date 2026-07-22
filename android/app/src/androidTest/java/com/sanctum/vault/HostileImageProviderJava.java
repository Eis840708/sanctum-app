package com.sanctum.vault;

import android.content.ContentProvider;
import android.content.ContentValues;
import android.database.Cursor;
import android.database.MatrixCursor;
import android.graphics.Bitmap;
import android.net.Uri;
import android.os.Bundle;
import android.os.ParcelFileDescriptor;
import android.provider.OpenableColumns;

import java.io.ByteArrayOutputStream;
import java.io.DataOutputStream;
import java.io.FileNotFoundException;
import java.io.FileOutputStream;
import java.io.IOException;
import java.io.OutputStream;
import java.util.concurrent.ConcurrentHashMap;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.atomic.AtomicInteger;
import java.util.concurrent.atomic.AtomicReference;
import java.util.zip.CRC32;

public final class HostileImageProviderJava extends ContentProvider {
    private static final long TEST_BYTE_CAP = 10L * 1024L * 1024L;
    private static final byte[] VALID_PNG = encode(Bitmap.CompressFormat.PNG);
    private static final byte[] VALID_JPEG = encode(Bitmap.CompressFormat.JPEG);
    private static final ConcurrentHashMap<String, AtomicInteger> OPEN_COUNTS =
            new ConcurrentHashMap<>();
    private static final AtomicReference<CountDownLatch> NEVER_GATE =
            new AtomicReference<>(new CountDownLatch(1));

    @Override
    public boolean onCreate() {
        return true;
    }

    @Override
    public String getType(Uri uri) {
        return "mime-camouflage".equals(uri.getLastPathSegment())
                ? "text/html"
                : "image/png";
    }

    @Override
    public Cursor query(
            Uri uri,
            String[] projection,
            String selection,
            String[] selectionArgs,
            String sortOrder
    ) {
        MatrixCursor cursor = new MatrixCursor(new String[]{OpenableColumns.SIZE});
        String path = uri.getLastPathSegment();
        Object size;
        if ("oversize".equals(path) || "lying-size".equals(path)) {
            size = 1L;
        } else if ("exact-limit".equals(path)) {
            size = TEST_BYTE_CAP;
        } else if ("unknown-size".equals(path)) {
            size = null;
        } else {
            size = (long) content(uri).length;
        }
        cursor.addRow(new Object[]{size});
        return cursor;
    }

    @Override
    public ParcelFileDescriptor openFile(Uri uri, String mode) throws FileNotFoundException {
        String path = uri.getLastPathSegment();
        OPEN_COUNTS.computeIfAbsent(path, ignored -> new AtomicInteger()).incrementAndGet();
        if (!"r".equals(mode)) {
            throw new FileNotFoundException();
        }
        if ("never".equals(path)) {
            boolean released = false;
            while (!released) {
                try {
                    NEVER_GATE.get().await();
                    released = true;
                } catch (InterruptedException ignored) {
                    // Deliberately models a provider that ignores caller cancellation.
                }
            }
        }
        try {
            ParcelFileDescriptor[] pipe = ParcelFileDescriptor.createReliablePipe();
            Thread writer = new Thread(
                    () -> writeResponse(uri, pipe[1]),
                    "hostile-image-provider"
            );
            writer.setDaemon(true);
            writer.start();
            return pipe[0];
        } catch (IOException error) {
            throw new FileNotFoundException();
        }
    }

    private void writeResponse(Uri uri, ParcelFileDescriptor writeSide) {
        String path = uri.getLastPathSegment();
        try {
            if ("oversize".equals(path)
                    || "lying-size".equals(path)
                    || "unknown-size".equals(path)) {
                try (FileOutputStream output = new ParcelFileDescriptor.AutoCloseOutputStream(writeSide)) {
                    byte[] block = new byte[8192];
                    long remaining = TEST_BYTE_CAP + 1;
                    while (remaining > 0) {
                        int count = (int) Math.min(block.length, remaining);
                        output.write(block, 0, count);
                        remaining -= count;
                    }
                }
                return;
            }
            if ("exact-limit".equals(path)) {
                try (FileOutputStream output = new ParcelFileDescriptor.AutoCloseOutputStream(writeSide)) {
                    writeExactLimitPng(output);
                }
                return;
            }
            if ("slow".equals(path)) {
                Thread.sleep(30_000);
                try (FileOutputStream output = new ParcelFileDescriptor.AutoCloseOutputStream(writeSide)) {
                    output.write(VALID_PNG);
                }
                return;
            }
            if ("read-error".equals(path)) {
                FileOutputStream output = new FileOutputStream(writeSide.getFileDescriptor());
                output.write(new byte[]{1, 2, 3, 4});
                output.flush();
                writeSide.closeWithError("synthetic provider failure");
                return;
            }
            try (FileOutputStream output = new ParcelFileDescriptor.AutoCloseOutputStream(writeSide)) {
                output.write(content(uri));
            }
        } catch (InterruptedException error) {
            Thread.currentThread().interrupt();
            closeQuietly(writeSide);
        } catch (IOException error) {
            closeQuietly(writeSide);
        }
    }

    private byte[] content(Uri uri) {
        String path = uri.getLastPathSegment();
        if ("valid-jpeg".equals(path)) {
            return VALID_JPEG;
        }
        if ("text".equals(path)) {
            return "<html>not an image</html>".getBytes();
        }
        if ("truncated".equals(path)) {
            byte[] truncated = new byte[VALID_PNG.length / 2];
            System.arraycopy(VALID_PNG, 0, truncated, 0, truncated.length);
            return truncated;
        }
        return VALID_PNG;
    }

    @Override
    public Bundle call(String method, String arg, Bundle extras) {
        Bundle result = new Bundle();
        if ("reset".equals(method)) {
            OPEN_COUNTS.clear();
            NEVER_GATE.getAndSet(new CountDownLatch(1)).countDown();
            result.putBoolean("ok", true);
            return result;
        }
        if ("release-never".equals(method)) {
            NEVER_GATE.get().countDown();
            result.putBoolean("ok", true);
            return result;
        }
        if ("open-count".equals(method)) {
            AtomicInteger count = OPEN_COUNTS.get(arg);
            result.putInt("count", count == null ? 0 : count.get());
            return result;
        }
        return super.call(method, arg, extras);
    }

    @Override
    public Uri insert(Uri uri, ContentValues values) {
        return null;
    }

    @Override
    public int delete(Uri uri, String selection, String[] selectionArgs) {
        return 0;
    }

    @Override
    public int update(Uri uri, ContentValues values, String selection, String[] selectionArgs) {
        return 0;
    }

    private static void writeExactLimitPng(OutputStream output) throws IOException {
        int iendOffset = VALID_PNG.length - 12;
        int fillerLength = (int) (TEST_BYTE_CAP - VALID_PNG.length - 12L);
        if (iendOffset <= 0 || fillerLength < 0) {
            throw new IOException("PNG fixture cannot reach byte cap");
        }

        output.write(VALID_PNG, 0, iendOffset);
        DataOutputStream data = new DataOutputStream(output);
        data.writeInt(fillerLength);
        byte[] type = new byte[]{'s', 'e', 'C', 'u'};
        data.write(type);

        CRC32 crc = new CRC32();
        crc.update(type);
        byte[] block = new byte[8192];
        int remaining = fillerLength;
        while (remaining > 0) {
            int count = Math.min(block.length, remaining);
            data.write(block, 0, count);
            crc.update(block, 0, count);
            remaining -= count;
        }
        data.writeInt((int) crc.getValue());
        output.write(VALID_PNG, iendOffset, 12);
    }

    private static byte[] encode(Bitmap.CompressFormat format) {
        Bitmap bitmap = Bitmap.createBitmap(2, 2, Bitmap.Config.ARGB_8888);
        ByteArrayOutputStream output = new ByteArrayOutputStream();
        bitmap.compress(format, 100, output);
        bitmap.recycle();
        return output.toByteArray();
    }

    private static void closeQuietly(ParcelFileDescriptor descriptor) {
        try {
            descriptor.close();
        } catch (IOException ignored) {
            // The consumer may already have closed the pipe after cancellation.
        }
    }
}
