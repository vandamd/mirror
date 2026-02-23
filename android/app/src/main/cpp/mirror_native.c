// mirror_native.c — Daylight Mirror native receiver with MediaCodec H.264 decode.
//
// Receives H.264 Annex B NAL units over TCP (ADB reverse tunnel),
// feeds them into a MediaCodec hardware decoder configured with a Surface,
// and lets the hardware compositor render directly — zero CPU copy in the hot path.
//
// Protocol: [0xDA 0x7E] [flags:1B] [seq:4B LE] [length:4B LE] [H.264 Annex B payload]
//   flags bit 0: 1=IDR (keyframe), 0=inter frame
// ACK:      [0xDA 0x7A] [seq:4B LE] — sent back after each frame is queued to decoder

#include <jni.h>
#include <android/native_window.h>
#include <android/native_window_jni.h>
#include <android/log.h>
#include <media/NdkMediaCodec.h>
#include <media/NdkMediaFormat.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <errno.h>
#include <pthread.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <arpa/inet.h>
#include <sys/resource.h>

#ifndef AMEDIACODEC_BUFFER_FLAG_KEY_FRAME
#define AMEDIACODEC_BUFFER_FLAG_KEY_FRAME 2
#endif

#define TAG "DaylightMirror"
#define LOGI(...) __android_log_print(ANDROID_LOG_INFO, TAG, __VA_ARGS__)
#define LOGE(...) __android_log_print(ANDROID_LOG_ERROR, TAG, __VA_ARGS__)

// Default resolution (updated dynamically via CMD_RESOLUTION from server)
#define DEFAULT_FRAME_W 1024
#define DEFAULT_FRAME_H 768

#define MAGIC_FRAME_0 0xDA
#define MAGIC_FRAME_1 0x7E
#define MAGIC_CMD_1   0x7F
#define MAGIC_ACK_1   0x7A
#define FLAG_KEYFRAME 0x01
#define FRAME_HEADER_SIZE 11
#define CMD_BRIGHTNESS 0x01
#define CMD_RESOLUTION 0x04

// Global state
static ANativeWindow *g_window = NULL;
static pthread_t g_decode_thread;
static volatile int g_running = 0;
static JavaVM *g_jvm = NULL;
static jobject g_activity = NULL;
static char g_host[64] = "127.0.0.1";
static int g_port = 8888;
static int g_sock = -1;

static uint32_t g_frame_w = DEFAULT_FRAME_W;
static uint32_t g_frame_h = DEFAULT_FRAME_H;

// Receive buffer — reused across frames
static uint8_t *g_nal_buf = NULL;
static uint32_t g_nal_buf_capacity = 0;

// MediaCodec decoder
static AMediaCodec *g_codec = NULL;
static pthread_mutex_t g_codec_mutex = PTHREAD_MUTEX_INITIALIZER;

static void set_thread_realtime(const char *name) {
    struct sched_param param;
    param.sched_priority = sched_get_priority_max(SCHED_FIFO);
    if (pthread_setschedparam(pthread_self(), SCHED_FIFO, &param) != 0) {
        setpriority(PRIO_PROCESS, 0, -10);
        LOGI("%s: SCHED_FIFO unavailable, using nice=-10", name);
    } else {
        LOGI("%s: SCHED_FIFO priority %d", name, param.sched_priority);
    }
}

static int read_exact(int sock, void *buf, int n) {
    int total = 0;
    while (total < n) {
        int r = recv(sock, (uint8_t *)buf + total, n - total, MSG_WAITALL);
        if (r < 0 && errno == EINTR) continue;
        if (r <= 0) return -1;
        total += r;
    }
    return total;
}

static double ms_diff(struct timespec a, struct timespec b) {
    return ((b.tv_sec - a.tv_sec) * 1000.0) + ((b.tv_nsec - a.tv_nsec) / 1e6);
}

static void send_ack(int sock, uint32_t seq) {
    uint8_t ack[6];
    ack[0] = MAGIC_FRAME_0;
    ack[1] = MAGIC_ACK_1;
    ack[2] = (uint8_t)(seq & 0xFF);
    ack[3] = (uint8_t)((seq >> 8) & 0xFF);
    ack[4] = (uint8_t)((seq >> 16) & 0xFF);
    ack[5] = (uint8_t)((seq >> 24) & 0xFF);
    send(sock, ack, 6, MSG_NOSIGNAL);
}

static void notify_connection_state(int connected) {
    if (!g_jvm || !g_activity) return;
    JNIEnv *env;
    int attached = 0;
    if ((*g_jvm)->GetEnv(g_jvm, (void **)&env, JNI_VERSION_1_6) != JNI_OK) {
        (*g_jvm)->AttachCurrentThread(g_jvm, &env, NULL);
        attached = 1;
    }
    jclass cls = (*env)->GetObjectClass(env, g_activity);
    jmethodID mid = (*env)->GetMethodID(env, cls, "onConnectionState", "(Z)V");
    if (mid) (*env)->CallVoidMethod(env, g_activity, mid, (jboolean)(connected ? 1 : 0));
    if (attached) (*g_jvm)->DetachCurrentThread(g_jvm);
}

// Build and start a MediaCodec H.264 decoder targeting the given Surface.
// Returns NULL on failure.
static AMediaCodec *build_decoder(ANativeWindow *window, uint32_t width, uint32_t height) {
    AMediaCodec *codec = AMediaCodec_createDecoderByType("video/avc");
    if (!codec) {
        LOGE("AMediaCodec_createDecoderByType failed");
        return NULL;
    }

    AMediaFormat *fmt = AMediaFormat_new();
    AMediaFormat_setString(fmt, AMEDIAFORMAT_KEY_MIME, "video/avc");
    AMediaFormat_setInt32(fmt, AMEDIAFORMAT_KEY_WIDTH, (int32_t)width);
    AMediaFormat_setInt32(fmt, AMEDIAFORMAT_KEY_HEIGHT, (int32_t)height);
    // Low latency mode (API 30+) — reduces decoder-side buffering
    AMediaFormat_setInt32(fmt, "low-latency", 1);

    media_status_t status = AMediaCodec_configure(codec, fmt, window, NULL, 0);
    AMediaFormat_delete(fmt);
    if (status != AMEDIA_OK) {
        LOGE("AMediaCodec_configure failed: %d (%ux%u)", status, width, height);
        AMediaCodec_delete(codec);
        return NULL;
    }

    status = AMediaCodec_start(codec);
    if (status != AMEDIA_OK) {
        LOGE("AMediaCodec_start failed: %d (%ux%u)", status, width, height);
        AMediaCodec_delete(codec);
        return NULL;
    }

    return codec;
}

// Create and start a MediaCodec H.264 decoder targeting the given Surface.
// Returns 0 on failure, 1 on success.
static int create_decoder(ANativeWindow *window, uint32_t width, uint32_t height) {
    AMediaCodec *codec = build_decoder(window, width, height);
    if (!codec) {
        // Some devices only allow one active hardware decoder instance.
        // Retry after tearing down the old instance, if any.
        pthread_mutex_lock(&g_codec_mutex);
        AMediaCodec *old = g_codec;
        g_codec = NULL;
        pthread_mutex_unlock(&g_codec_mutex);

        if (old) {
            LOGI("Retrying decoder configure after tearing down old instance");
            AMediaCodec_stop(old);
            AMediaCodec_delete(old);
            codec = build_decoder(window, width, height);
        }
    }

    if (!codec) {
        return 0;
    }

    pthread_mutex_lock(&g_codec_mutex);
    if (g_codec) {
        AMediaCodec_stop(g_codec);
        AMediaCodec_delete(g_codec);
    }
    g_codec = codec;
    g_frame_w = width;
    g_frame_h = height;
    pthread_mutex_unlock(&g_codec_mutex);

    LOGI("MediaCodec H.264 decoder started: %ux%u", width, height);
    return 1;
}

static void destroy_decoder(void) {
    pthread_mutex_lock(&g_codec_mutex);
    if (g_codec) {
        AMediaCodec_stop(g_codec);
        AMediaCodec_delete(g_codec);
        g_codec = NULL;
    }
    pthread_mutex_unlock(&g_codec_mutex);
}

// Feed one NAL unit buffer into the decoder, render output to Surface.
// Returns 0 on fatal error.
static int feed_nal(const uint8_t *data, size_t len, int is_idr, uint32_t seq, int sock,
                    double *out_decode_ms) {
    struct timespec t0, t1;
    clock_gettime(CLOCK_MONOTONIC, &t0);

    pthread_mutex_lock(&g_codec_mutex);
    AMediaCodec *codec = g_codec;
    if (!codec) {
        pthread_mutex_unlock(&g_codec_mutex);
        return 0;
    }

    // Get input buffer with 2ms timeout
    ssize_t input_idx = AMediaCodec_dequeueInputBuffer(codec, 2000);
    if (input_idx < 0) {
        pthread_mutex_unlock(&g_codec_mutex);
        // Timeout is OK — just skip this frame
        send_ack(sock, seq);
        return 1;
    }

    size_t buf_size = 0;
    uint8_t *input_buf = AMediaCodec_getInputBuffer(codec, (size_t)input_idx, &buf_size);
    if (!input_buf || len > buf_size) {
        AMediaCodec_queueInputBuffer(codec, (size_t)input_idx, 0, 0, 0, 0);
        pthread_mutex_unlock(&g_codec_mutex);
        LOGE("Input buffer too small: need %zu, have %zu", len, buf_size);
        send_ack(sock, seq);
        return 1;
    }

    memcpy(input_buf, data, len);
    uint32_t flags = is_idr ? AMEDIACODEC_BUFFER_FLAG_KEY_FRAME : 0;
    AMediaCodec_queueInputBuffer(codec, (size_t)input_idx, 0, len, 0, flags);

    // Drain all available output buffers and render to Surface
    AMediaCodecBufferInfo info;
    ssize_t output_idx;
    while ((output_idx = AMediaCodec_dequeueOutputBuffer(codec, &info, 0)) >= 0) {
        // render=true pushes directly to the configured Surface/ANativeWindow
        AMediaCodec_releaseOutputBuffer(codec, (size_t)output_idx, info.size > 0);
    }
    // AMEDIACODEC_INFO_OUTPUT_BUFFERS_CHANGED and AMEDIACODEC_INFO_OUTPUT_FORMAT_CHANGED
    // are negative values — silently ignored here, they don't require action.

    pthread_mutex_unlock(&g_codec_mutex);

    clock_gettime(CLOCK_MONOTONIC, &t1);
    *out_decode_ms = ms_diff(t0, t1);

    send_ack(sock, seq);
    return 1;
}

static void *decode_thread(void *arg) {
    (void)arg;
    set_thread_realtime("decode_thread");
    LOGI("Decode thread started, connecting to %s:%d", g_host, g_port);

    // Ensure decoder is created before we start receiving frames
    if (g_window && !g_codec) {
        create_decoder(g_window, g_frame_w, g_frame_h);
    }

    // Initial receive buffer
    g_nal_buf_capacity = 2 * 1024 * 1024;  // 2MB — plenty for any single access unit
    g_nal_buf = (uint8_t *)malloc(g_nal_buf_capacity);
    if (!g_nal_buf) {
        LOGE("Failed to allocate NAL buffer");
        return NULL;
    }

    while (g_running) {
        int sock = socket(AF_INET, SOCK_STREAM, 0);
        if (sock < 0) {
            LOGE("socket() failed: %s", strerror(errno));
            sleep(1);
            continue;
        }

        int flag = 1;
        setsockopt(sock, IPPROTO_TCP, TCP_NODELAY, &flag, sizeof(flag));
        setsockopt(sock, IPPROTO_TCP, TCP_QUICKACK, &flag, sizeof(flag));
        int rcvbuf = 2 * 1024 * 1024;  // 2MB — H.264 frames are larger than LZ4 deltas
        setsockopt(sock, SOL_SOCKET, SO_RCVBUF, &rcvbuf, sizeof(rcvbuf));

        struct sockaddr_in addr;
        memset(&addr, 0, sizeof(addr));
        addr.sin_family = AF_INET;
        addr.sin_port = htons(g_port);
        inet_pton(AF_INET, g_host, &addr.sin_addr);

        LOGI("Connecting to %s:%d ...", g_host, g_port);
        if (connect(sock, (struct sockaddr *)&addr, sizeof(addr)) < 0) {
            LOGE("connect() failed: %s (is ADB reverse tunnel set up?)", strerror(errno));
            close(sock);
            sleep(1);
            continue;
        }

        g_sock = sock;
        LOGI("Connected to server %s:%d", g_host, g_port);

        int frame_count = 0;
        int stat_frames = 0;
        int dropped_frames = 0;
        uint32_t last_seq = 0;
        int has_last_seq = 0;
        double recv_sum = 0, decode_sum = 0;
        struct timespec stat_start;
        clock_gettime(CLOCK_MONOTONIC, &stat_start);

        while (g_running) {
            struct timespec t0, t1;
            clock_gettime(CLOCK_MONOTONIC, &t0);

            uint8_t magic[2];
            if (read_exact(sock, magic, 2) < 0) {
                LOGE("Connection lost");
                break;
            }
            if (magic[0] != MAGIC_FRAME_0) {
                LOGE("Bad magic: 0x%02x 0x%02x", magic[0], magic[1]);
                break;
            }

            // Command packet [DA 7F cmd ...]
            if (magic[1] == MAGIC_CMD_1) {
                uint8_t cmd;
                if (read_exact(sock, &cmd, 1) < 0) break;

                if (cmd == CMD_RESOLUTION) {
                    uint8_t res_data[4];
                    if (read_exact(sock, res_data, 4) < 0) break;
                    uint32_t new_w = res_data[0] | (res_data[1] << 8);
                    uint32_t new_h = res_data[2] | (res_data[3] << 8);
                    if (new_w > 0 && new_h > 0 && new_w <= 4096 && new_h <= 4096) {
                        LOGI("Resolution → %ux%u, recreating decoder", new_w, new_h);
                        if (g_window) {
                            ANativeWindow_setBuffersGeometry(g_window, (int32_t)new_w, (int32_t)new_h, 0);
                            create_decoder(g_window, new_w, new_h);
                        }

                        if (g_jvm && g_activity) {
                            JNIEnv *env2;
                            int attached2 = 0;
                            if ((*g_jvm)->GetEnv(g_jvm, (void **)&env2, JNI_VERSION_1_6) != JNI_OK) {
                                (*g_jvm)->AttachCurrentThread(g_jvm, &env2, NULL);
                                attached2 = 1;
                            }
                            jclass cls2 = (*env2)->GetObjectClass(env2, g_activity);
                            jmethodID mid2 = (*env2)->GetMethodID(env2, cls2, "setOrientation", "(Z)V");
                            if (mid2) {
                                (*env2)->CallVoidMethod(env2, g_activity, mid2,
                                    (jboolean)(new_h > new_w ? 1 : 0));
                            }
                            if (attached2) (*g_jvm)->DetachCurrentThread(g_jvm);
                        }
                    }
                    continue;
                }

                uint8_t value;
                if (read_exact(sock, &value, 1) < 0) break;
                if (g_jvm && g_activity) {
                    JNIEnv *env;
                    int attached = 0;
                    if ((*g_jvm)->GetEnv(g_jvm, (void **)&env, JNI_VERSION_1_6) != JNI_OK) {
                        (*g_jvm)->AttachCurrentThread(g_jvm, &env, NULL);
                        attached = 1;
                    }
                    jclass cls = (*env)->GetObjectClass(env, g_activity);
                    if (cmd == CMD_BRIGHTNESS) {
                        jmethodID mid = (*env)->GetMethodID(env, cls, "setBrightness", "(I)V");
                        if (mid) (*env)->CallVoidMethod(env, g_activity, mid, (jint)value);
                    } else if (cmd == 0x02) {
                        jmethodID mid = (*env)->GetMethodID(env, cls, "setWarmth", "(I)V");
                        if (mid) (*env)->CallVoidMethod(env, g_activity, mid, (jint)value);
                    }
                    if (attached) (*g_jvm)->DetachCurrentThread(g_jvm);
                }
                continue;
            }

            if (magic[1] != MAGIC_FRAME_1) {
                LOGE("Unknown packet type: 0x%02x", magic[1]);
                break;
            }

            // Frame header: [flags:1] [seq:4 LE] [len:4 LE]
            uint8_t frame_hdr[9];
            if (read_exact(sock, frame_hdr, 9) < 0) {
                LOGE("Connection lost reading frame header");
                break;
            }

            uint8_t flags       = frame_hdr[0];
            uint32_t seq        = frame_hdr[1] | ((uint32_t)frame_hdr[2] << 8) |
                                  ((uint32_t)frame_hdr[3] << 16) | ((uint32_t)frame_hdr[4] << 24);
            uint32_t payload_len = frame_hdr[5] | ((uint32_t)frame_hdr[6] << 8) |
                                   ((uint32_t)frame_hdr[7] << 16) | ((uint32_t)frame_hdr[8] << 24);

            if (has_last_seq && seq != last_seq + 1) {
                int gap = (int)(seq - last_seq - 1);
                if (gap > 0 && gap < 1000) dropped_frames += gap;
            }
            last_seq = seq;
            has_last_seq = 1;

            // Grow receive buffer if needed
            if (payload_len > g_nal_buf_capacity) {
                uint8_t *new_buf = (uint8_t *)realloc(g_nal_buf, payload_len);
                if (!new_buf) {
                    LOGE("Failed to grow NAL buffer to %u bytes", payload_len);
                    break;
                }
                g_nal_buf = new_buf;
                g_nal_buf_capacity = payload_len;
            }

            if (read_exact(sock, g_nal_buf, (int)payload_len) < 0) {
                LOGE("Failed to read payload");
                break;
            }
            clock_gettime(CLOCK_MONOTONIC, &t1);

            double decode_ms = 0.0;
            if (!feed_nal(g_nal_buf, payload_len, (flags & FLAG_KEYFRAME) != 0, seq, sock, &decode_ms)) {
                LOGE("feed_nal fatal error, reconnecting");
                break;
            }

            if (frame_count == 0) {
                notify_connection_state(1);
            }

            recv_sum += ms_diff(t0, t1);
            decode_sum += decode_ms;
            frame_count++;
            stat_frames++;

            struct timespec now;
            clock_gettime(CLOCK_MONOTONIC, &now);
            double elapsed = (now.tv_sec - stat_start.tv_sec) +
                             (now.tv_nsec - stat_start.tv_nsec) / 1e9;
            if (elapsed >= 5.0 && stat_frames > 0) {
                double fps = stat_frames / elapsed;
                LOGI("FPS: %.1f | recv: %.1fms | decode: %.1fms | %uKB %s | drops: %d | total: %d",
                     fps,
                     recv_sum / stat_frames,
                     decode_sum / stat_frames,
                     payload_len / 1024,
                     (flags & FLAG_KEYFRAME) ? "IDR" : "P",
                     dropped_frames,
                     frame_count);
                stat_frames = 0;
                recv_sum = 0;
                decode_sum = 0;
                dropped_frames = 0;
                stat_start = now;
            }
        }

        if (g_sock >= 0) {
            close(g_sock);
            g_sock = -1;
        }
        LOGI("Disconnected, reconnecting in 1s...");
        notify_connection_state(0);
        sleep(1);
    }

    free(g_nal_buf);
    g_nal_buf = NULL;
    g_nal_buf_capacity = 0;
    LOGI("Decode thread exited");
    return NULL;
}

// JNI: called from Kotlin when Surface is ready
JNIEXPORT void JNICALL
Java_com_daylight_mirror_MirrorActivity_nativeStart(
    JNIEnv *env, jobject thiz, jobject surface, jstring host, jint port)
{
    if (g_running) return;

    (*env)->GetJavaVM(env, &g_jvm);
    g_activity = (*env)->NewGlobalRef(env, thiz);

    g_window = ANativeWindow_fromSurface(env, surface);

    const char *host_str = (*env)->GetStringUTFChars(env, host, NULL);
    strncpy(g_host, host_str, sizeof(g_host) - 1);
    (*env)->ReleaseStringUTFChars(env, host, host_str);
    g_port = port;

    g_running = 1;

    // Create decoder now — decode thread will also check on startup
    create_decoder(g_window, g_frame_w, g_frame_h);

    pthread_create(&g_decode_thread, NULL, decode_thread, NULL);
}

// JNI: called from Kotlin when Surface is destroyed
JNIEXPORT void JNICALL
Java_com_daylight_mirror_MirrorActivity_nativeStop(
    JNIEnv *env, jobject thiz)
{
    g_running = 0;
    if (g_sock >= 0) {
        shutdown(g_sock, SHUT_RDWR);
        close(g_sock);
        g_sock = -1;
    }
    pthread_join(g_decode_thread, NULL);
    destroy_decoder();
    if (g_window) {
        ANativeWindow_release(g_window);
        g_window = NULL;
    }
    if (g_activity) {
        (*env)->DeleteGlobalRef(env, g_activity);
        g_activity = NULL;
    }
}
