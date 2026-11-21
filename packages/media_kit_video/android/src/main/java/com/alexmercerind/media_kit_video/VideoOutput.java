/**
 * This file is a part of media_kit (https://github.com/media-kit/media-kit).
 * <p>
 * Copyright © 2021 & onwards, Hitesh Kumar Saini <saini123hitesh@gmail.com>.
 * All rights reserved.
 * Use of this source code is governed by MIT license that can be found in the LICENSE file.
 */
package com.alexmercerind.media_kit_video;

import android.annotation.TargetApi;
import android.graphics.Bitmap;
import android.os.Build;
import android.os.Handler;
import android.os.Looper;
import android.os.SystemClock;
import android.util.Log;
import android.view.PixelCopy;
import android.view.Surface;

import java.lang.reflect.Method;
import java.util.HashSet;
import java.util.Locale;
import java.util.Objects;

import io.flutter.plugin.common.MethodChannel.Result;
import io.flutter.view.TextureRegistry;

public class VideoOutput implements TextureRegistry.SurfaceProducer.Callback {
    private static final String TAG = "VideoOutput";
    private static final Method newGlobalObjectRef;
    private static final Method deleteGlobalObjectRef;
    private static final HashSet<Long> deletedGlobalObjectRefs = new HashSet<>();
    private static final Handler handler = new Handler(Looper.getMainLooper());
    private static final long FRAME_TIMEOUT_MS = 1500;
    private static final long FRAME_RETRY_MS = 32;

    static {
        try {
            // com.alexmercerind.mediakitandroidhelper.MediaKitAndroidHelper is part of package:media_kit_libs_android_video & package:media_kit_libs_android_audio packages.
            // Use reflection to invoke methods of com.alexmercerind.mediakitandroidhelper.MediaKitAndroidHelper.
            Class<?> mediaKitAndroidHelperClass = Class.forName("com.alexmercerind.mediakitandroidhelper.MediaKitAndroidHelper");
            newGlobalObjectRef = mediaKitAndroidHelperClass.getDeclaredMethod("newGlobalObjectRef", Object.class);
            deleteGlobalObjectRef = mediaKitAndroidHelperClass.getDeclaredMethod("deleteGlobalObjectRef", long.class);
            newGlobalObjectRef.setAccessible(true);
            deleteGlobalObjectRef.setAccessible(true);
        } catch (Throwable e) {
            Log.i("media_kit", "package:media_kit_libs_android_video missing. Make sure you have added it to pubspec.yaml.");
            throw new RuntimeException("Failed to initialize com.alexmercerind.media_kit_video.VideoOutput.");
        }
    }

    private long id = 0;
    private long wid = 0;
    private Surface availableSurface;
    private int availableWidth;
    private int availableHeight;
    private long surfaceGeneration = 0;
    private boolean disposed = false;
    private final HashSet<FrameProbe> frameProbes = new HashSet<>();

    private final TextureUpdateCallback textureUpdateCallback;

    private final TextureRegistry.SurfaceProducer surfaceProducer;

    private final Object lock = new Object();

    VideoOutput(TextureRegistry textureRegistryReference, TextureUpdateCallback textureUpdateCallback) {
        this.textureUpdateCallback = textureUpdateCallback;

        surfaceProducer = textureRegistryReference.createSurfaceProducer();
        surfaceProducer.setCallback(this);
    }

    public void dispose() {
        synchronized (lock) {
            disposed = true;
            cancelFrameProbes("Video output disposed during frame availability check.");
            try {
                surfaceProducer.getSurface().release();
            } catch (Throwable e) {
                Log.e(TAG, "dispose", e);
            }
            try {
                surfaceProducer.release();
            } catch (Throwable e) {
                Log.e(TAG, "dispose", e);
            }
            onSurfaceCleanup();
        }
    }

    public void setSurfaceSize(int width, int height) {
        setSurfaceSize(width, height, false);
    }

    private void setSurfaceSize(int width, int height, boolean force) {
        synchronized (lock) {
            try {
                if (!force && surfaceProducer.getWidth() == width && surfaceProducer.getHeight() == height) {
                    return;
                }
                surfaceProducer.setSize(width, height);
                onSurfaceAvailable();
            } catch (Throwable e) {
                Log.e(TAG, "setSurfaceSize", e);
            }
        }
    }

    @Override
    public void onSurfaceAvailable() {
        synchronized (lock) {
            if (disposed) return;
            final Surface surface = surfaceProducer.getSurface();
            final int width = surfaceProducer.getWidth();
            final int height = surfaceProducer.getHeight();
            // setSize 的主动通知与引擎回调可能重复；同一输出不能再次清空 vo。
            if (wid != 0 && surface == availableSurface
                    && width == availableWidth && height == availableHeight) {
                return;
            }
            // Advance only for the same deduplicated binding identity used below.
            surfaceGeneration++;
            cancelFrameProbes("Surface changed during frame availability check.");
            Log.i(TAG, "onSurfaceAvailable");
            final long previousWid = wid;
            id = surfaceProducer.id();
            wid = newGlobalObjectRef(surface);
            availableSurface = surface;
            availableWidth = width;
            availableHeight = height;
            textureUpdateCallback.onTextureUpdate(id, wid, width, height);
            if (previousWid != 0) {
                handler.postDelayed(() -> deleteGlobalObjectRef(previousWid), 5000);
            }
        }
    }

    @Override
    public void onSurfaceCleanup() {
        synchronized (lock) {
            Log.i(TAG, "onSurfaceCleanup");
            surfaceGeneration++;
            cancelFrameProbes("Surface cleaned up during frame availability check.");
            // 真正 cleanup 必须失效：即使引擎复用 Surface 对象也要重新绑定。
            availableSurface = null;
            textureUpdateCallback.onTextureUpdate(id, 0, surfaceProducer.getWidth(), surfaceProducer.getHeight());
            if (wid != 0) {
                final long widReference = wid;
                wid = 0;
                handler.postDelayed(() -> deleteGlobalObjectRef(widReference), 5000);
            }
        }
    }

    public void waitUntilFrameAvailable(Result result) {
        synchronized (lock) {
            // The plugin still supports API 16; never substitute a size notification
            // for PixelCopy on devices where the Surface overload is unavailable.
            if (Build.VERSION.SDK_INT < Build.VERSION_CODES.N) {
                result.error("FRAME_PROBE_UNSUPPORTED", "Surface buffer probing requires Android API 24 or newer.", null);
                return;
            }
            if (disposed || wid == 0 || availableSurface == null || !availableSurface.isValid()
                    || availableWidth <= 0 || availableHeight <= 0) {
                result.error("FRAME_SURFACE_UNAVAILABLE", "No valid bound Surface is available.", null);
                return;
            }
            final FrameProbe probe = new FrameProbe(result);
            frameProbes.add(probe);
            handler.postAtTime(probe.timeout, probe.deadline);
            handler.post(probe.retry);
        }
    }

    public void cancelFrameProbes(String message) {
        synchronized (lock) {
            // finish removes itself; iterate a snapshot to cancel concurrent callers.
            for (FrameProbe probe : new HashSet<>(frameProbes)) {
                probe.finish("FRAME_SURFACE_CHANGED", message);
            }
        }
    }

    @TargetApi(Build.VERSION_CODES.N)
    private final class FrameProbe {
        private final Surface surface = availableSurface;
        private final long generation = surfaceGeneration;
        private final long surfaceWid = wid;
        private final int width = availableWidth;
        private final int height = availableHeight;
        private final long deadline = SystemClock.uptimeMillis() + FRAME_TIMEOUT_MS;
        private final Runnable retry = this::requestCopy;
        private final Runnable timeout = this::onTimeout;
        private Result result;
        private Bitmap bitmap;
        private boolean copyPending = false;
        private boolean completed = false;

        FrameProbe(Result result) {
            this.result = result;
        }

        // Called under lock before every request and before accepting every callback.
        private boolean checkCurrent() {
            if (completed) return false;
            if (disposed || generation != surfaceGeneration || surface != availableSurface
                    || surfaceWid != wid || width != availableWidth || height != availableHeight
                    || !surface.isValid()) {
                finish("FRAME_SURFACE_CHANGED", "Surface changed during frame availability check.");
                return false;
            }
            if (SystemClock.uptimeMillis() >= deadline) {
                finish("FRAME_PROBE_TIMEOUT", "Surface had no readable buffer before the 1500 ms deadline.");
                return false;
            }
            return true;
        }

        private void requestCopy() {
            synchronized (lock) {
                if (!checkCurrent()) return;
                try {
                    // API 24's Surface overload scales into this private 1x1 scratch
                    // bitmap. Never read, encode, display or send its pixels to Dart.
                    if (bitmap == null) {
                        bitmap = Bitmap.createBitmap(1, 1, Bitmap.Config.ARGB_8888);
                    }
                    copyPending = true;
                    PixelCopy.request(surface, bitmap, this::onCopyFinished, handler);
                } catch (RuntimeException e) {
                    copyPending = false;
                    finish("FRAME_PROBE_FAILED", "PixelCopy request failed: " + e.getMessage());
                }
            }
        }

        private void onCopyFinished(int status) {
            synchronized (lock) {
                copyPending = false;
                if (completed) {
                    // Cancellation/timeout already replied. PixelCopy cannot be
                    // cancelled; recycle only now, after its native write is done.
                    recycleBitmap();
                    return;
                }
                if (!checkCurrent()) return;
                if (status == PixelCopy.SUCCESS) {
                    finish(null, null);
                } else if (status == PixelCopy.ERROR_SOURCE_NO_DATA || status == PixelCopy.ERROR_TIMEOUT) {
                    // At most one copy is in flight; retries yield the main looper
                    // and are bounded by the original deadline, never reset it.
                    handler.postDelayed(retry, Math.min(FRAME_RETRY_MS, deadline - SystemClock.uptimeMillis()));
                } else {
                    finish("FRAME_PROBE_FAILED", "PixelCopy failed with status " + status + ".");
                }
            }
        }

        private void onTimeout() {
            synchronized (lock) {
                finish("FRAME_PROBE_TIMEOUT", "Surface had no readable buffer before the 1500 ms deadline.");
            }
        }

        // All completion paths hold lock. Result and scheduled work are released
        // exactly once, even when cleanup races a late PixelCopy callback.
        private void finish(String code, String message) {
            if (completed) return;
            completed = true;
            frameProbes.remove(this);
            handler.removeCallbacks(retry);
            handler.removeCallbacks(timeout);
            if (!copyPending) recycleBitmap();
            final Result completion = result;
            result = null;
            final Runnable reply = () -> {
                if (code == null) {
                    completion.success(null);
                } else {
                    completion.error(code, message, null);
                }
            };
            if (Looper.myLooper() == handler.getLooper()) {
                reply.run();
            } else {
                handler.post(reply);
            }
        }

        private void recycleBitmap() {
            if (bitmap != null) {
                bitmap.recycle();
                bitmap = null;
            }
        }
    }

    private static long newGlobalObjectRef(Object object) {
        Log.i(TAG, String.format(Locale.ENGLISH, "newGlobalRef: object = %s", object));
        try {
            return (long) Objects.requireNonNull(newGlobalObjectRef.invoke(null, object));
        } catch (Throwable e) {
            Log.e(TAG, "newGlobalRef", e);
            return 0;
        }
    }

    private static void deleteGlobalObjectRef(long ref) {
        if (deletedGlobalObjectRefs.contains(ref)) {
            Log.i(TAG, String.format(Locale.ENGLISH, "deleteGlobalObjectRef: ref = %d ALREADY DELETED", ref));
            return;
        }
        if (deletedGlobalObjectRefs.size() > 100) {
            deletedGlobalObjectRefs.clear();
        }
        deletedGlobalObjectRefs.add(ref);
        Log.i(TAG, String.format(Locale.ENGLISH, "deleteGlobalObjectRef: ref = %d", ref));
        try {
            deleteGlobalObjectRef.invoke(null, ref);
        } catch (Throwable e) {
            Log.e(TAG, "deleteGlobalObjectRef", e);
        }
    }
}
