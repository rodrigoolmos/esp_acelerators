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

#define TWO_PI 6.283185307179586476925286766559

typedef struct {
    double re;
    double im;
} complex64_t;

typedef struct {
    unsigned frames;
    bool ifft_mode;
    bool window_enable;
    float tolerance;
} app_options_t;

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

static int parse_unsigned_option(const char *text, unsigned min, unsigned max, unsigned *value)
{
    char *endptr = NULL;
    unsigned long parsed;

    errno = 0;
    parsed = strtoul(text, &endptr, 10);
    if (errno != 0 || endptr == text || *endptr != '\0' || parsed < min || parsed > max) {
        return -1;
    }

    *value = (unsigned)parsed;
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
    printf("Use: %s [frames:1-%d] [FFT|IFFT] [window:0|1] [tolerance]\n",
           prog, MAX_FFT_FRAMES);
    printf("Default: %u FFT(s), FFT, window disabled, tolerance %.3f\n",
           DEFAULT_FFT_FRAMES, DEFAULT_TOLERANCE);
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

    if (argc >= 2 &&
        parse_unsigned_option(argv[1], 1, MAX_FFT_FRAMES, &opts->frames) != 0) {
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

static void generate_input_frame(token_t *input, unsigned frame)
{
    const double f1 = 3.0 + (double)frame;
    const double f2 = 17.0 + 2.0 * (double)frame;
    const double a1 = 0.75;
    const double a2 = 0.25;

    for (unsigned i = 0; i < FFT_SIZE; i++) {
        double phase1 = TWO_PI * f1 * (double)i / (double)FFT_SIZE;
        double phase2 = TWO_PI * f2 * (double)i / (double)FFT_SIZE;
        float re = (float)(a1 * cos(phase1) + a2 * cos(phase2));
        float im = (float)(a1 * sin(phase1) + a2 * sin(phase2));

        input[i] = pack_complex(re, im);
    }
}

static void make_hann_window(float *window_values)
{
    for (unsigned i = 0; i < FFT_SIZE; i++) {
        double phase = TWO_PI * (double)i / (double)(FFT_SIZE - 1);
        window_values[i] = (float)(0.5 - 0.5 * cos(phase));
    }
}

static void write_window_to_dma(token_t *buf, const float *window_values)
{
    for (unsigned i = 0; i < FFT_SIZE; i++) {
        buf[i] = pack_complex(window_values[i], 0.0f);
    }
}

static void compute_sw_fft_frame(const token_t *input, token_t *output, bool ifft_mode,
                                 const float *window_values)
{
    complex64_t data[FFT_SIZE];

    for (unsigned i = 0; i < FFT_SIZE; i++) {
        float re_f;
        float im_f;
        unsigned rev = bit_reverse(i);
        double window_coef = window_values ? (double)window_values[i] : 1.0;

        unpack_complex(input[i], &re_f, &im_f);

        if (ifft_mode) {
            data[rev].re = (double)im_f * window_coef;
            data[rev].im = (double)re_f * window_coef;
        } else {
            data[rev].re = (double)re_f * window_coef;
            data[rev].im = (double)im_f * window_coef;
        }
    }

    for (unsigned len = 2; len <= FFT_SIZE; len <<= 1) {
        unsigned half = len >> 1;
        double angle_step = -TWO_PI / (double)len;

        for (unsigned base = 0; base < FFT_SIZE; base += len) {
            for (unsigned j = 0; j < half; j++) {
                double angle = angle_step * (double)j;
                double wr = cos(angle);
                double wi = sin(angle);
                complex64_t a = data[base + j];
                complex64_t b = data[base + j + half];
                complex64_t t = {
                    .re = b.re * wr - b.im * wi,
                    .im = b.re * wi + b.im * wr,
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
            re = (float)(data[i].im / (double)FFT_SIZE);
            im = (float)(data[i].re / (double)FFT_SIZE);
        } else {
            re = (float)data[i].re;
            im = (float)data[i].im;
        }

        output[i] = pack_complex(re, im);
    }
}

static void compute_sw_reference(const token_t *input, token_t *output, unsigned frames,
                                 bool ifft_mode, const float *window_values)
{
    for (unsigned frame = 0; frame < frames; frame++) {
        compute_sw_fft_frame(&input[frame * FFT_SIZE], &output[frame * FFT_SIZE],
                             ifft_mode, window_values);
    }
}

static void run_hw(token_t *buf, unsigned burst_len_value, unsigned index_value,
                   unsigned out_index_value, unsigned window_value, unsigned ifft_value,
                   float *time_ms)
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
    *time_ms = (float)hw_ns / 1000000.0f;
}

static void run_hw_chunked(token_t *buf, unsigned frames, unsigned output_index,
                           bool window_enable, bool ifft_mode, float *time_ms)
{
    unsigned frame_base = 0;

    *time_ms = 0.0f;

    while (frame_base < frames) {
        unsigned chunk_frames = frames - frame_base;
        unsigned input_chunk_index = frame_base * FFT_SIZE;
        unsigned output_chunk_index = output_index + input_chunk_index;
        float chunk_time_ms;

        if (chunk_frames > FFT_HW_FRAMES_PER_RUN) {
            chunk_frames = FFT_HW_FRAMES_PER_RUN;
        }

        if (frames > FFT_HW_FRAMES_PER_RUN) {
            printf("  HW chunk: frames=%u input_index=%u output_index=%u\n",
                   chunk_frames, input_chunk_index, output_chunk_index);
            fflush(stdout);
        }

        run_hw(buf, chunk_frames, input_chunk_index, output_chunk_index,
               window_enable ? 0x1 : 0x0, ifft_mode ? 0x1 : 0x0, &chunk_time_ms);

        *time_ms += chunk_time_ms;
        frame_base += chunk_frames;
    }
}

static int compare_results(const token_t *hw, const token_t *sw, unsigned total_samples,
                           float tolerance)
{
    unsigned mismatches = 0;
    float max_re_err = 0.0f;
    float max_im_err = 0.0f;

    for (unsigned i = 0; i < total_samples; i++) {
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

        if (re_err > max_re_err) max_re_err = re_err;
        if (im_err > max_im_err) max_im_err = im_err;

        if (re_err > tolerance || im_err > tolerance) {
            if (mismatches < 16) {
                printf("Mismatch %u: HW=(%f,%f) SW=(%f,%f) err=(%f,%f)\n",
                       i, hw_re, hw_im, sw_re, sw_im, re_err, im_err);
            }
            mismatches++;
        }
    }

    printf("Compared %u complex samples\n", total_samples);
    printf("Max error: re=%f im=%f tolerance=%f\n", max_re_err, max_im_err, tolerance);
    printf("Mismatches: %u\n", mismatches);

    return mismatches ? -1 : 0;
}

int main(int argc, char **argv)
{
    app_options_t opts;
    token_t *buf;
    token_t *sw_output;
    float *window_values = NULL;
    unsigned input_words;
    unsigned output_index;
    unsigned total_words;
    unsigned alloc_words;
    float hw_time_ms;
    float sw_time_ms;
    struct timespec startn;
    struct timespec endn;
    unsigned long long sw_ns;
    int parse_rc;
    int rc = 1;

    parse_rc = parse_args(argc, argv, &opts);
    if (parse_rc > 0) return 0;
    if (parse_rc < 0) return 1;

    input_words = opts.frames * FFT_SIZE;
    output_index = input_words;
    total_words = input_words * 2;
    alloc_words = round_up(total_words, DMA_WORD_PER_BEAT(sizeof(token_t)));

    printf("\nExecute ====== %s ======\n\n", cfg_000[0].devname);
    printf("Config: frames=%u fft_size=%u mode=%s window=%u tolerance=%f\n",
           opts.frames, FFT_SIZE, opts.ifft_mode ? "IFFT" : "FFT",
           opts.window_enable ? 1U : 0U, opts.tolerance);

    buf = (token_t *)esp_alloc(alloc_words * sizeof(token_t));
    sw_output = (token_t *)malloc(input_words * sizeof(token_t));
    if (!buf || !sw_output) {
        printf("Allocation error\n");
        goto out;
    }
    memset(buf, 0, alloc_words * sizeof(token_t));

    if (opts.window_enable) {
        window_values = (float *)malloc(FFT_SIZE * sizeof(float));
        if (!window_values) {
            printf("Window allocation error\n");
            goto out;
        }
        make_hann_window(window_values);
        write_window_to_dma(buf, window_values);
        printf("Loading Hann window coefficients in hardware...\n");
        run_hw(buf, 0, 0, 0, 0x3, 0, &hw_time_ms);
        printf("Window load time: %f ms\n", hw_time_ms);
    }

    for (unsigned frame = 0; frame < opts.frames; frame++) {
        generate_input_frame(&buf[frame * FFT_SIZE], frame);
    }

    gettime(&startn);
    compute_sw_reference(buf, sw_output, opts.frames, opts.ifft_mode, window_values);
    gettime(&endn);
    sw_ns = ts_subtract(&startn, &endn);
    sw_time_ms = (float)sw_ns / 1000000.0f;
    printf("Software FFT time: %f ms\n", sw_time_ms);

    printf("Running hardware FFT...\n");
    fflush(stdout);
    run_hw_chunked(buf, opts.frames, output_index, opts.window_enable, opts.ifft_mode,
                   &hw_time_ms);
    printf("Hardware FFT time: %f ms\n", hw_time_ms);

    if (compare_results(&buf[output_index], sw_output, input_words, opts.tolerance) == 0) {
        printf("FFT RTL check PASSED\n");
        rc = 0;
    } else {
        printf("FFT RTL check FAILED\n");
    }

out:
    free(window_values);
    free(sw_output);
    if (buf) esp_free(buf);

    return rc;
}
