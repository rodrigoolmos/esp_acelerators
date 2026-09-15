// Copyright (c) 2011-2026 Columbia University, System Level Design Group
// SPDX-License-Identifier: Apache-2.0
#include "cfg.h"
#include "libesp.h"

#include <errno.h>
#include <float.h>
#include <inttypes.h>
#include <limits.h>
#include <math.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>

#define TWO_PI_F 6.283185307179586476925286766559f

typedef struct {
    float re;
    float im;
} complex32_t;

typedef struct {
    uint64_t frames;
    bool ifft_mode;
    bool window_enable;
    float tolerance;
} app_options_t;

typedef struct {
    uint64_t samples;
    uint64_t mismatches;
    float max_re_err;
    float max_im_err;
} compare_stats_t;

static uint32_t float_to_bits(float value)
{
    uint32_t bits;

    memcpy(&bits, &value, sizeof(bits));
    return bits;
}

static float bits_to_float(uint32_t bits)
{
    float value;

    memcpy(&value, &bits, sizeof(value));
    return value;
}

static token_t pack_complex(float re, float im)
{
    return ((uint64_t)float_to_bits(re) << 32) | float_to_bits(im);
}

static void unpack_complex(token_t word, float *re, float *im)
{
    *re = bits_to_float((uint32_t)(word >> 32));
    *im = bits_to_float((uint32_t)word);
}

static unsigned bit_reverse(unsigned value)
{
    unsigned reversed = 0;

    for (unsigned i = 0; i < FFT_BITS; i++) {
        reversed = (reversed << 1) | (value & 1U);
        value >>= 1;
    }

    return reversed;
}

static void make_sw_twiddles(complex32_t *twiddles)
{
    for (unsigned k = 0; k < FFT_SIZE / 2; k++) {
        float angle = -TWO_PI_F * (float)k / (float)FFT_SIZE;

        twiddles[k].re = cosf(angle);
        twiddles[k].im = sinf(angle);
    }
}

static int parse_frames_option(const char *text, uint64_t *value)
{
    char *endptr = NULL;
    unsigned long long parsed;

    errno = 0;
    parsed = strtoull(text, &endptr, 10);
    if (errno != 0 || endptr == text || *endptr != '\0' || parsed == 0 || text[0] == '-' ||
        parsed > UINT64_MAX / FFT_SIZE) {
        return -1;
    }

    *value = (uint64_t)parsed;
    return 0;
}

static int parse_bool_option(const char *text, bool *value)
{
    if (!strcasecmp(text, "1") || !strcasecmp(text, "on") ||
        !strcasecmp(text, "true") || !strcasecmp(text, "yes")) {
        *value = true;
        return 0;
    }
    if (!strcasecmp(text, "0") || !strcasecmp(text, "off") ||
        !strcasecmp(text, "false") || !strcasecmp(text, "no")) {
        *value = false;
        return 0;
    }

    return -1;
}

static int parse_mode_option(const char *text, bool *ifft_mode)
{
    if (!strcasecmp(text, "FFT")) {
        *ifft_mode = false;
        return 0;
    }
    if (!strcasecmp(text, "IFFT")) {
        *ifft_mode = true;
        return 0;
    }

    return -1;
}

static int parse_tolerance_option(const char *text, float *value)
{
    char *endptr = NULL;
    float parsed;

    errno = 0;
    parsed = strtof(text, &endptr);
    if (errno != 0 || endptr == text || *endptr != '\0' || parsed < 0.0f || !isfinite(parsed)) {
        return -1;
    }

    *value = parsed;
    return 0;
}

static void print_usage(const char *prog)
{
    printf("Use: %s [frames>=1] [FFT|IFFT] [window:0|1] [tolerance]\n", prog);
    printf("Default: %u FFT(s), FFT, window disabled, tolerance %.3f\n",
           DEFAULT_FFT_FRAMES, DEFAULT_TOLERANCE);
    printf("Up to %u FFTs are sent in each hardware run; larger requests use consecutive runs.\n",
           FFT_HW_FRAMES_PER_RUN);
}

static int parse_args(int argc, char **argv, app_options_t *opts)
{
    opts->frames = DEFAULT_FFT_FRAMES;
    opts->ifft_mode = false;
    opts->window_enable = false;
    opts->tolerance = DEFAULT_TOLERANCE;

    if (argc >= 2 && (!strcasecmp(argv[1], "-h") || !strcasecmp(argv[1], "--help"))) {
        print_usage(argv[0]);
        return 1;
    }

    if (argc > 5) {
        print_usage(argv[0]);
        return -1;
    }

    if (argc >= 2 && parse_frames_option(argv[1], &opts->frames) != 0) {
        printf("Invalid frames value: %s\n", argv[1]);
        print_usage(argv[0]);
        return -1;
    }

    if (argc >= 3 && parse_mode_option(argv[2], &opts->ifft_mode) != 0) {
        printf("Invalid mode: %s. Use FFT or IFFT\n", argv[2]);
        return -1;
    }

    if (argc >= 4 && parse_bool_option(argv[3], &opts->window_enable) != 0) {
        printf("Invalid window option: %s. Use 0 or 1\n", argv[3]);
        return -1;
    }

    if (argc >= 5 && parse_tolerance_option(argv[4], &opts->tolerance) != 0) {
        printf("Invalid tolerance: %s\n", argv[4]);
        return -1;
    }

    return 0;
}

static void generate_input_frame(token_t *input, uint64_t frame)
{
    const unsigned frame_mod = (unsigned)(frame % FFT_SIZE);
    const float f1 = (float)((frame_mod + 3U) % FFT_SIZE);
    const float f2 = (float)((2U * frame_mod + 17U) % FFT_SIZE);
    const float a1 = 0.75f;
    const float a2 = 0.25f;

    for (unsigned i = 0; i < FFT_SIZE; i++) {
        float phase1 = TWO_PI_F * f1 * (float)i / (float)FFT_SIZE;
        float phase2 = TWO_PI_F * f2 * (float)i / (float)FFT_SIZE;
        float re = a1 * cosf(phase1) + a2 * cosf(phase2);
        float im = a1 * sinf(phase1) + a2 * sinf(phase2);

        input[i] = pack_complex(re, im);
    }
}

static void make_hann_window(float *window_values)
{
    for (unsigned i = 0; i < FFT_SIZE; i++) {
        float phase = TWO_PI_F * (float)i / (float)(FFT_SIZE - 1);
        window_values[i] = 0.5f - 0.5f * cosf(phase);
    }
}

static void write_window_to_dma(token_t *buf, const float *window_values)
{
    for (unsigned i = 0; i < FFT_SIZE; i++) {
        buf[i] = pack_complex(window_values[i], 0.0f);
    }
}

static void compute_sw_fft_frame(const token_t *input, token_t *output, bool ifft_mode,
                                 const float *window_values,
                                 const complex32_t *twiddles)
{
    complex32_t data[FFT_SIZE];
    const float inverse_scale = 1.0f / (float)FFT_SIZE;

    for (unsigned i = 0; i < FFT_SIZE; i++) {
        float re_f;
        float im_f;
        unsigned rev = bit_reverse(i);
        float window_coef = window_values ? window_values[i] : 1.0f;

        unpack_complex(input[i], &re_f, &im_f);

        if (ifft_mode) {
            data[rev].re = im_f * window_coef;
            data[rev].im = re_f * window_coef;
        } else {
            data[rev].re = re_f * window_coef;
            data[rev].im = im_f * window_coef;
        }
    }

    for (unsigned len = 2; len <= FFT_SIZE; len <<= 1) {
        unsigned half = len >> 1;
        unsigned twiddle_stride = FFT_SIZE / len;

        for (unsigned base = 0; base < FFT_SIZE; base += len) {
            for (unsigned j = 0; j < half; j++) {
                complex32_t w = twiddles[j * twiddle_stride];
                complex32_t a = data[base + j];
                complex32_t b = data[base + j + half];
                complex32_t t = {
                    .re = b.re * w.re - b.im * w.im,
                    .im = b.re * w.im + b.im * w.re,
                };

                data[base + j].re = a.re + t.re;
                data[base + j].im = a.im + t.im;
                data[base + j + half].re = a.re - t.re;
                data[base + j + half].im = a.im - t.im;
            }
        }
    }

    for (unsigned i = 0; i < FFT_SIZE; i++) {
        float re;
        float im;

        if (ifft_mode) {
            re = data[i].im * inverse_scale;
            im = data[i].re * inverse_scale;
        } else {
            re = data[i].re;
            im = data[i].im;
        }

        output[i] = pack_complex(re, im);
    }
}

static void compute_sw_reference(const token_t *input, token_t *output, unsigned frames,
                                 bool ifft_mode, const float *window_values,
                                 const complex32_t *twiddles)
{
    for (unsigned frame = 0; frame < frames; frame++) {
        compute_sw_fft_frame(&input[frame * FFT_SIZE], &output[frame * FFT_SIZE],
                             ifft_mode, window_values, twiddles);
    }
}

static void run_hw(token_t *buf, unsigned burst_len_value, unsigned index_value,
                   unsigned out_index_value, unsigned window_value, unsigned ifft_value,
                   double *time_ms)
{
    struct timespec startn;
    struct timespec endn;
    unsigned long long hw_ns;

    fft_cfg_000[0].burst_len = burst_len_value;
    fft_cfg_000[0].index = index_value;
    fft_cfg_000[0].out_index = out_index_value;
    fft_cfg_000[0].window = window_value;
    fft_cfg_000[0].ifft = ifft_value;
    cfg_000[0].hw_buf = buf;

    gettime(&startn);
    esp_run(cfg_000, NACC);
    gettime(&endn);

    hw_ns = ts_subtract(&startn, &endn);
    *time_ms = (double)hw_ns / 1000000.0;
}

static void compare_results(const token_t *hw, const token_t *sw, size_t batch_samples,
                            uint64_t sample_offset, float tolerance, compare_stats_t *stats)
{
    for (size_t i = 0; i < batch_samples; i++) {
        float hw_re;
        float hw_im;
        float sw_re;
        float sw_im;
        float re_err;
        float im_err;

        unpack_complex(hw[i], &hw_re, &hw_im);
        unpack_complex(sw[i], &sw_re, &sw_im);

        re_err = fabsf(hw_re - sw_re);
        im_err = fabsf(hw_im - sw_im);

        if (re_err > stats->max_re_err) stats->max_re_err = re_err;
        if (im_err > stats->max_im_err) stats->max_im_err = im_err;

        if (re_err > tolerance || im_err > tolerance) {
            if (stats->mismatches < 16) {
                printf("Mismatch %" PRIu64 ": HW=(%f,%f) SW=(%f,%f) err=(%f,%f)\n",
                       sample_offset + (uint64_t)i, hw_re, hw_im, sw_re, sw_im,
                       re_err, im_err);
            }
            stats->mismatches++;
        }
    }

    stats->samples += (uint64_t)batch_samples;
}

int main(int argc, char **argv)
{
    app_options_t opts;
    token_t *buf = NULL;
    token_t *sw_output = NULL;
    complex32_t *sw_twiddles = NULL;
    float *window_values = NULL;
    compare_stats_t stats = {0};
    uint64_t frame_base = 0;
    uint64_t hardware_runs;
    unsigned batch_capacity;
    size_t max_input_words;
    size_t max_total_words;
    size_t alloc_words;
    double hw_time_ms = 0.0;
    double sw_time_ms = 0.0;
    double twiddle_setup_time_ms;
    double window_load_time_ms;
    struct timespec startn;
    struct timespec endn;
    unsigned long long sw_ns;
    int parse_rc;
    int rc = 1;

    parse_rc = parse_args(argc, argv, &opts);
    if (parse_rc > 0) return 0;
    if (parse_rc < 0) return 1;

    batch_capacity = opts.frames < FFT_HW_FRAMES_PER_RUN
                         ? (unsigned)opts.frames
                         : FFT_HW_FRAMES_PER_RUN;
    max_input_words = (size_t)batch_capacity * FFT_SIZE;
    max_total_words = max_input_words * 2;
    alloc_words = round_up(max_total_words, DMA_WORD_PER_BEAT(sizeof(token_t)));
    hardware_runs = opts.frames / FFT_HW_FRAMES_PER_RUN +
                    (opts.frames % FFT_HW_FRAMES_PER_RUN != 0);

    printf("\nExecute ====== %s ======\n\n", cfg_000[0].devname);
    printf("Config: frames=%" PRIu64 " fft_size=%u mode=%s window=%u tolerance=%f\n",
           opts.frames, FFT_SIZE, opts.ifft_mode ? "IFFT" : "FFT",
           opts.window_enable ? 1U : 0U, opts.tolerance);
    printf("Hardware runs: %" PRIu64 " (up to %u FFTs per run)\n",
           hardware_runs, FFT_HW_FRAMES_PER_RUN);

    buf = (token_t *)esp_alloc(alloc_words * sizeof(token_t));
    sw_output = (token_t *)malloc(max_input_words * sizeof(token_t));
    sw_twiddles = (complex32_t *)malloc((FFT_SIZE / 2) * sizeof(*sw_twiddles));
    if (!buf || !sw_output || !sw_twiddles) {
        printf("Allocation error: DMA=%zu bytes SW=%zu bytes twiddles=%zu bytes\n",
               alloc_words * sizeof(token_t), max_input_words * sizeof(token_t),
               (size_t)(FFT_SIZE / 2) * sizeof(*sw_twiddles));
        goto out;
    }

    gettime(&startn);
    make_sw_twiddles(sw_twiddles);
    gettime(&endn);
    twiddle_setup_time_ms = (double)ts_subtract(&startn, &endn) / 1000000.0;
    printf("Software reference: radix-2 float32, %u precomputed twiddles\n",
           FFT_SIZE / 2);
    printf("Software twiddle setup time: %f ms (excluded from FFT time)\n",
           twiddle_setup_time_ms);

    if (opts.window_enable) {
        window_values = (float *)malloc(FFT_SIZE * sizeof(float));
        if (!window_values) {
            printf("Window allocation error\n");
            goto out;
        }
        make_hann_window(window_values);
        write_window_to_dma(buf, window_values);
        printf("Loading Hann window coefficients in hardware...\n");
        run_hw(buf, 0, 0, 0, 0x3, 0, &window_load_time_ms);
        printf("Window load time: %f ms\n", window_load_time_ms);
    }

    while (frame_base < opts.frames) {
        uint64_t frames_left = opts.frames - frame_base;
        unsigned batch_frames = frames_left < FFT_HW_FRAMES_PER_RUN
                                    ? (unsigned)frames_left
                                    : FFT_HW_FRAMES_PER_RUN;
        size_t input_words = (size_t)batch_frames * FFT_SIZE;
        unsigned output_index = (unsigned)input_words;
        double batch_hw_time_ms;

        memset(buf, 0, 2 * input_words * sizeof(token_t));
        for (unsigned frame = 0; frame < batch_frames; frame++) {
            generate_input_frame(&buf[(size_t)frame * FFT_SIZE], frame_base + frame);
        }

        gettime(&startn);
        compute_sw_reference(buf, sw_output, batch_frames, opts.ifft_mode,
                             window_values, sw_twiddles);
        gettime(&endn);
        sw_ns = ts_subtract(&startn, &endn);
        sw_time_ms += (double)sw_ns / 1000000.0;

        if (hardware_runs == 1) {
            printf("Software FFT time: %f ms\n", sw_time_ms);
            printf("Running hardware FFT...\n");
        } else {
            printf("Running hardware batch %" PRIu64 "/%" PRIu64
                   ": frames=%u (global frame %" PRIu64 ")\n",
                   frame_base / FFT_HW_FRAMES_PER_RUN + 1, hardware_runs,
                   batch_frames, frame_base);
        }
        fflush(stdout);
        run_hw(buf, batch_frames, 0, output_index,
               opts.window_enable ? 0x1 : 0x0, opts.ifft_mode ? 0x1 : 0x0,
               &batch_hw_time_ms);
        hw_time_ms += batch_hw_time_ms;

        compare_results(&buf[output_index], sw_output, input_words,
                        stats.samples, opts.tolerance, &stats);
        frame_base += batch_frames;
    }

    if (hardware_runs > 1) printf("Total software FFT time: %f ms\n", sw_time_ms);
    printf("Hardware FFT time: %f ms\n", hw_time_ms);
    if (hw_time_ms > 0.0) {
        printf("Speedup SW/HW: %.2fx\n", sw_time_ms / hw_time_ms);
    } else {
        printf("Speedup SW/HW: unavailable (hardware time is zero)\n");
    }
    printf("Compared %" PRIu64 " complex samples\n", stats.samples);
    printf("Max error: re=%f im=%f tolerance=%f\n",
           stats.max_re_err, stats.max_im_err, opts.tolerance);
    printf("Mismatches: %" PRIu64 "\n", stats.mismatches);

    if (stats.mismatches == 0) {
        printf("FFT RTL check PASSED\n");
        rc = 0;
    } else {
        printf("FFT RTL check FAILED\n");
    }

out:
    free(window_values);
    free(sw_twiddles);
    free(sw_output);
    if (buf) esp_free(buf);

    return rc;
}
