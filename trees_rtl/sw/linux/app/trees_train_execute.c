// Copyright (c) 2011-2024 Columbia University, System Level Design Group
// SPDX-License-Identifier: Apache-2.0
#include "libesp.h"
#include "cfg.h"
#include "monitors.h"
#include "train.h"
#include <errno.h>
#include <fcntl.h>
#include <inttypes.h>
#include <unistd.h>

static unsigned in_words_adj;
static unsigned out_words_adj;
static unsigned in_len;
static unsigned out_len;
static unsigned in_size;
static unsigned out_size;
static unsigned out_offset;
static unsigned size;
static uint8_t quiet_esp = TRUE;
static int debug_candidates = 0;

union stamps{
    uint32_t clk[2];
    uint64_t data;
};


int read_n_features(const char *csv_file, int n, struct feature *features, int *n_col) {
    FILE *file = fopen(csv_file, "r");
    char line[MAX_LINE_LENGTH];
    int features_read = 0;
    int expected_cols = 0;
    int i;

    if (!file) {
        perror("Failed to open the file");
        return -1;
    }

    while (fgets(line, MAX_LINE_LENGTH, file) && features_read < n) {
        float temp[N_FEATURE + 1] = {0};
        char *token = strtok(line, ",; \t\r\n");
        int line_cols = 0;

        while (token != NULL && line_cols < N_FEATURE + 1) {
            temp[line_cols] = strtof(token, NULL);
            token = strtok(NULL, ",; \t\r\n");
            line_cols++;
        }

        if (line_cols < 2) {
            continue;
        }

        if (expected_cols == 0) {
            expected_cols = line_cols;
        } else if (line_cols != expected_cols) {
            printf("Invalid dataset: line %i has %i columns, expected %i\n",
                   features_read + 1, line_cols, expected_cols);
            fclose(file);
            return -1;
        }

        for (i = 0; i < line_cols - 1; i++) {
            features[features_read].features[i] = temp[i];
        }
        features[features_read].prediction = (uint8_t) temp[line_cols - 1];

        features_read++;
    }

    *n_col = expected_cols;
    fclose(file);
    return features_read;
}

static int effective_feature_count(int declared_features, const float max_features[N_FEATURE],
                                   const float min_features[N_FEATURE])
{
    int effective_features = declared_features;

    while (effective_features > 1 &&
           max_features[effective_features - 1] == 0.0f &&
           min_features[effective_features - 1] == 0.0f) {
        effective_features--;
    }

    return effective_features;
}

static int parse_int_arg(const char *arg, int min_value, int max_value, int *out)
{
    char *end;
    long value;

    errno = 0;
    value = strtol(arg, &end, 10);
    if (errno != 0 || end == arg || *end != '\0' ||
        value < min_value || value > max_value) {
        return -1;
    }

    *out = (int)value;
    return 0;
}

static void print_train_usage(const char *prog)
{
    printf("Train use   : %s --train <dataset.csv|dataset.dat> [model_out] [sample_divisor] [max_generations] [active_population] [quiet] [debug_candidates]\n",
           prog);
    printf("  model_out: default model.bin. If omitted, the second numeric argument is treated as sample_divisor.\n");
    printf("  sample_divisor: default 10. Higher is faster; 1 uses all samples.\n");
    printf("  max_generations: default 0. 0 keeps the normal stop condition.\n");
    printf("  active_population: default %i. Lower is faster for smoke tests.\n", POPULATION);
    printf("  quiet: default 1. Use 0 to show libesp per-call timing.\n");
    printf("  debug_candidates: default 0. Compare HW/SW for the first N candidates.\n");
}

static void print_execute_usage(const char *prog)
{
    printf("Execute use : %s --execute <dataset.csv|dataset.dat> <model.model|model.bin> [quiet]\n",
           prog);
    printf("  quiet: default 1. Use 0 to show libesp per-call timing.\n");
}

static void print_usage(const char *prog)
{
    print_train_usage(prog);
    print_execute_usage(prog);
}

static void run_esp_call(void)
{
    int stdout_fd;
    int devnull_fd;

    if (!quiet_esp) {
        esp_run(cfg_000, NACC);
        return;
    }

    fflush(stdout);
    stdout_fd = dup(STDOUT_FILENO);
    devnull_fd = open("/dev/null", O_WRONLY);
    if (stdout_fd < 0 || devnull_fd < 0) {
        if (stdout_fd >= 0) {
            close(stdout_fd);
        }
        if (devnull_fd >= 0) {
            close(devnull_fd);
        }
        esp_run(cfg_000, NACC);
        return;
    }

    if (dup2(devnull_fd, STDOUT_FILENO) < 0) {
        close(devnull_fd);
        close(stdout_fd);
        esp_run(cfg_000, NACC);
        return;
    }
    close(devnull_fd);

    esp_run(cfg_000, NACC);

    fflush(stdout);
    dup2(stdout_fd, STDOUT_FILENO);
    close(stdout_fd);
}

/* User-defined code */
static void init_parameters()
{
    in_words_adj  = round_up(10000*32, DMA_WORD_PER_BEAT(sizeof(token_t)));
    out_words_adj = round_up(10000/4 , DMA_WORD_PER_BEAT(sizeof(token_t)));

    in_len     = in_words_adj * (1);
    out_len    = out_words_adj * (1);
    in_size    = in_len * sizeof(token_t);
    out_size   = out_len * sizeof(token_t);
    out_offset = in_len;
    size       = (out_offset * sizeof(token_t)) + out_size;
}

static token_t pack_tree_data(const tree_data *tree)
{
    uint32_t value_bits;
    uint64_t packed;

    memcpy(&value_bits, &tree->tree_camps.float_int_union, sizeof(value_bits));
    packed = ((uint64_t)(tree->tree_camps.leaf_or_node & 0x1)) |
             ((uint64_t)tree->tree_camps.feature_index << 8) |
             ((uint64_t)tree->tree_camps.next_node_right_index << 16) |
             ((uint64_t)tree->tree_camps.padding << 24) |
             ((uint64_t)value_bits << 32);

    return (token_t)packed;
}

void coppy_trees(tree_data tree[N_TREES][N_NODE_AND_LEAFS], token_t *buf)
{
    for (int t = 0; t < N_TREES; t++) {
        for (int n = 0; n < N_NODE_AND_LEAFS; n++) {
            buf[t * N_NODE_AND_LEAFS + n] = pack_tree_data(&tree[t][n]);
        }
    }
}

void copy_features_bytes(token_t *mem, const struct feature *features, int n_features)
{
    uint8_t *dst_bytes = (uint8_t *)mem;

    for (int i = 0; i < n_features; i++) {
        size_t offset = i * sizeof(float)*N_FEATURE;
        memcpy(dst_bytes + offset, features[i].features, sizeof(float)*N_FEATURE);
    }
}

void send_trees(token_t *tree_buf)
{
    
    trees_cfg_000[0].burst_len = 0;
    trees_cfg_000[0].load_trees = 1;
    cfg_000[0].hw_buf = tree_buf;
    run_esp_call();

}

void perform_inferences_hw(token_t *io_buf, struct feature *features, int read_samples,
                           uint8_t *predictions, float *exe_time_ms, uint8_t new_features)
{
    struct timespec startn, endn;
    unsigned long long hw_ns;

    if (new_features){
        trees_cfg_000[0].burst_len = read_samples;
        trees_cfg_000[0].load_trees = 0;
        copy_features_bytes(io_buf, features, read_samples);
    }else{
        trees_cfg_000[0].burst_len = 0;
        trees_cfg_000[0].load_trees = 0;
    }
    
    cfg_000[0].hw_buf = io_buf;
    gettime(&startn);
    run_esp_call();
    gettime(&endn);

    if (exe_time_ms) {
        hw_ns = ts_subtract(&startn, &endn);
        *exe_time_ms = (float)hw_ns / 1000000.0f;
    }
    
    memcpy(predictions, io_buf, read_samples);

}

void print_accuracy(struct feature *features, uint8_t *predictions, 
                        int read_samples, int n_classes)
{

    int accuracy[256]   = {0};
    int accuracy_total  = 0;
    int evaluated[256]  = {0};
    int evaluated_total = 0;

    for (int i = 0; i < read_samples; i++) {
        uint8_t expected = features[i].prediction;

        if (features[i].prediction == predictions[i]) {
            accuracy[expected]++;
            accuracy_total++;
        }
        evaluated[expected]++;
        evaluated_total++;
    }

    for (int i = 0; i <= n_classes; i++) {
        float class_accuracy = evaluated[i] > 0 ?
                               1.0f * accuracy[i] / evaluated[i] : 0.0f;
        printf("Accuracy %f class %i num instances %i\n", class_accuracy, i,
               evaluated[i]);
    }

    printf("Accuracy total %f evaluates samples %i of %i\n", 1.0f * accuracy_total / read_samples,
           evaluated_total, read_samples);
}

static int32_t float_to_ordered_int(float value)
{
    int32_t bits;

    memcpy(&bits, &value, sizeof(bits));
    return bits;
}

static void make_prediction_sw(tree_data trees[N_TREES][N_NODE_AND_LEAFS],
                               float features[N_FEATURE], uint8_t *prediction)
{
    int32_t counts[N_CLASSES] = {0};

    for (int t = 0; t < N_TREES; t++) {
        uint8_t node_index = 0;
        tree_data node;

        for (int guard = 0; guard < N_NODE_AND_LEAFS; guard++) {
            node = trees[t][node_index];
            if (!(node.tree_camps.leaf_or_node & 0x01)) {
                break;
            }

            uint8_t feature_index = node.tree_camps.feature_index % N_FEATURE;
            int32_t feature_bits = float_to_ordered_int(features[feature_index]);
            int32_t threshold_bits = float_to_ordered_int(node.tree_camps.float_int_union.f);

            node_index = feature_bits < threshold_bits ?
                         node_index + 1 : node.tree_camps.next_node_right_index;
        }

        int32_t leaf_value = node.tree_camps.float_int_union.i;
        if (leaf_value >= 0 && leaf_value < N_CLASSES) {
            counts[leaf_value]++;
        }
    }

    uint8_t best = 0;
    int32_t best_count = counts[0];

    for (int c = 1; c < N_CLASSES; c++) {
        if (counts[c] > best_count) {
            best_count = counts[c];
            best = (uint8_t)c;
        }
    }

    *prediction = best;
}

static void make_prediction_packed_sw(const token_t *tree, float features[N_FEATURE],
                                      uint8_t *prediction)
{
    int32_t counts[N_CLASSES] = {0};

    for (int t = 0; t < N_TREES; t++) {
        uint8_t node_index = 0;
        int32_t leaf_value = NULL_VOTE;

        for (int guard = 0; guard < N_NODE_AND_LEAFS; guard++) {
            uint64_t node = (uint64_t)tree[t * N_NODE_AND_LEAFS + node_index];
            uint8_t leaf_or_node = node & 0x1;
            uint8_t feature_index = (node >> 8) & (N_FEATURE - 1);
            uint8_t next_node_right_index = (node >> 16) & 0xff;
            int32_t value_bits = (int32_t)(uint32_t)(node >> 32);

            if (!(leaf_or_node & 0x01)) {
                leaf_value = value_bits;
                break;
            }

            node_index = float_to_ordered_int(features[feature_index]) < value_bits ?
                         node_index + 1 : next_node_right_index;
        }

        if (leaf_value >= 0 && leaf_value < N_CLASSES) {
            counts[leaf_value]++;
        }
    }

    uint8_t best = 0;
    int32_t best_count = counts[0];

    for (int c = 1; c < N_CLASSES; c++) {
        if (counts[c] > best_count) {
            best_count = counts[c];
            best = (uint8_t)c;
        }
    }

    *prediction = best;
}

static void software_prediction_packed(struct feature *features, int read_samples,
                                       const token_t *tree, int n_classes,
                                       uint8_t *predictions_sw,
                                       float *exe_time_ms)
{
    struct timespec startn, endn;
    unsigned long long sw_ns;

    gettime(&startn);
    for (int i = 0; i < read_samples; i++) {
        make_prediction_packed_sw(tree, features[i].features, &predictions_sw[i]);
    }
    gettime(&endn);

    sw_ns = ts_subtract(&startn, &endn);
    *exe_time_ms = (float)sw_ns / 1000000.0f;
    printf("  > Software test time: %f ms\n", *exe_time_ms);
    print_accuracy(features, predictions_sw, read_samples, n_classes);
}

static void debug_candidate_predictions(int candidate,
                                        tree_data trees[N_TREES][N_NODE_AND_LEAFS],
                                        const token_t *packed_tree,
                                        struct feature *features, int read_samples,
                                        uint8_t *hw_predictions, int n_classes,
                                        float hw_accuracy)
{
    int hw_hist[256] = {0};
    int sw_struct_hist[256] = {0};
    int sw_packed_hist[256] = {0};
    int sw_struct_correct = 0;
    int sw_packed_correct = 0;
    int hw_struct_mismatch = 0;
    int hw_packed_mismatch = 0;
    int struct_packed_mismatch = 0;

    for (int i = 0; i < read_samples; i++) {
        uint8_t sw_struct_prediction;
        uint8_t sw_packed_prediction;

        make_prediction_sw(trees, features[i].features, &sw_struct_prediction);
        make_prediction_packed_sw(packed_tree, features[i].features, &sw_packed_prediction);
        hw_hist[hw_predictions[i]]++;
        sw_struct_hist[sw_struct_prediction]++;
        sw_packed_hist[sw_packed_prediction]++;
        if (sw_struct_prediction == features[i].prediction) {
            sw_struct_correct++;
        }
        if (sw_packed_prediction == features[i].prediction) {
            sw_packed_correct++;
        }
        if (sw_struct_prediction != hw_predictions[i]) {
            hw_struct_mismatch++;
        }
        if (sw_packed_prediction != hw_predictions[i]) {
            hw_packed_mismatch++;
        }
        if (sw_struct_prediction != sw_packed_prediction) {
            struct_packed_mismatch++;
        }
    }

    printf("DEBUG candidate %i: HW acc=%f SW struct acc=%f SW packed acc=%f HW/struct mismatches=%i HW/packed mismatches=%i struct/packed mismatches=%i\n",
           candidate, hw_accuracy, (float)sw_struct_correct / (float)read_samples,
           (float)sw_packed_correct / (float)read_samples, hw_struct_mismatch,
           hw_packed_mismatch, struct_packed_mismatch);
    printf("DEBUG candidate %i: HW preds", candidate);
    for (int c = 0; c <= n_classes; c++) {
        printf(" c%i=%i", c, hw_hist[c]);
    }
    printf("\n");
    printf("DEBUG candidate %i: SW struct preds", candidate);
    for (int c = 0; c <= n_classes; c++) {
        printf(" c%i=%i", c, sw_struct_hist[c]);
    }
    printf("\n");
    printf("DEBUG candidate %i: SW packed preds", candidate);
    for (int c = 0; c <= n_classes; c++) {
        printf(" c%i=%i", c, sw_packed_hist[c]);
    }
    printf("\n");
    printf("DEBUG candidate %i: first packed nodes 0x%016" PRIx64 " 0x%016" PRIx64 "\n",
           candidate, (uint64_t)packed_tree[0], (uint64_t)packed_tree[1]);
}

void evaluate_model(token_t *tree_buf, token_t *io_buf, struct feature *features,
                    int read_samples, int n_classes,
                    uint8_t *predictions, uint32_t max_burst, float *exe_time_ms, uint8_t new_features)
{
    uint32_t processed = 0;
    uint32_t burst;
    float exe_t;
    *exe_time_ms = 0;

    send_trees(tree_buf);

    while (processed < read_samples) {
        burst =
            (read_samples - processed) > max_burst ? max_burst : (read_samples - processed);
        printf("Processing batch %i, processed %i of %i\n", burst, processed, read_samples);
        perform_inferences_hw(io_buf, &features[processed], 
                                burst, &predictions[processed], &exe_t, new_features);
    
        *exe_time_ms += exe_t;
        processed += burst;
    }

    print_accuracy(features, predictions, read_samples, n_classes);
}

void get_accuracy(struct feature *features, int read_samples, uint8_t *prediction, float *accuracy){

    int correct = 0;

    for (int s = 0; s < read_samples; s++){
        if (features[s].prediction == prediction[s]){
            correct++;
        }
    }
    
    *accuracy = (float) correct / (float) read_samples;

}

void print_tree(tree_data trees[N_TREES][N_NODE_AND_LEAFS]){

    for (int t = 0; t < N_TREES; t++){
        printf("Tree %i\n", t);
        for (int n = 0; n < N_NODE_AND_LEAFS; n++){
            printf("  >>  Tree %i node %i feature_index %i\n", t, n, trees[t][n].tree_camps.feature_index);
            if (trees[t][n].tree_camps.leaf_or_node == 0)
                printf("  >>  Tree %i node %i leaf val %i\n", t, n, trees[t][n].tree_camps.float_int_union.i);
            else            
                printf("  >>  Tree %i node %i node val %f\n", t, n, trees[t][n].tree_camps.float_int_union.f);
            printf("  >>  Tree %i node %i node index %i\n", t, n, trees[t][n].tree_camps.next_node_right_index);
        }
    }
    

}

void train_model(tree_data trees_population[POPULATION][N_TREES][N_NODE_AND_LEAFS], 
                    token_t *tree_buf, token_t *io_buf, struct feature *features, int read_samples, 
                    float *accuracy, uint8_t sow_log, uint32_t *trees_used, int n_classes,
                    int active_population){

    uint32_t processed;
    uint32_t burst;
    float exe_t;
    uint8_t predictions[MAX_TEST_SAMPLES];
    token_t *debug_tree_shadow = NULL;

    if (debug_candidates > 0) {
        debug_tree_shadow = malloc(N_TREES * N_NODE_AND_LEAFS * sizeof(*debug_tree_shadow));
        if (!debug_tree_shadow) {
            perror("Failed to allocate debug tree buffer");
        }
    }

    for (int p = 0; p < active_population; p++){

        processed = 0;
        
        //print_tree(trees_population[p]);
        coppy_trees(trees_population[p], tree_buf);
        if (debug_tree_shadow && p < debug_candidates) {
            memcpy(debug_tree_shadow, tree_buf,
                   N_TREES * N_NODE_AND_LEAFS * sizeof(*debug_tree_shadow));
        }
        send_trees(tree_buf);

        while (processed < read_samples) {
            burst =
                (read_samples - processed) > MAX_BURST ? MAX_BURST : (read_samples - processed);
            perform_inferences_hw(io_buf, &features[processed], 
                                    burst, &predictions[processed], &exe_t, TRUE);
        
            processed += burst;
        }

        get_accuracy(features, read_samples, predictions, &accuracy[p]);
        if (debug_tree_shadow && p < debug_candidates) {
            debug_candidate_predictions(p, trees_population[p], debug_tree_shadow,
                                        features, read_samples,
                                        predictions, n_classes, accuracy[p]);
        }

    }

    free(debug_tree_shadow);

}

static int export_model(tree_data trees[N_TREES][N_NODE_AND_LEAFS], const char* filename) {
    FILE* f = fopen(filename, "wb");
    if (!f) {
        perror("Failed to open model file");
        return -1;
    }

    // Write header
    if (fwrite("model", 1, 5, f) != 5) {
        perror("Failed to write model header");
        fclose(f);
        return -1;
    }

    for (int t = 0; t < N_TREES; ++t) {
        for (int i = 0; i < N_NODE_AND_LEAFS; ++i) {
            int64_t compact_data = pack_tree_data(&trees[t][i]);

            if (fwrite(&compact_data, sizeof(int64_t), 1, f) != 1) {
                perror("Failed to write model data");
                fclose(f);
                return -1;
            }
        }
    }

    if (fclose(f) != 0) {
        perror("Failed to close model file");
        return -1;
    }

    return 0;
}

static int load_model(token_t *tree_buf, const char *filename)
{
    char magic_number[5] = {0};
    FILE *file = fopen(filename, "rb");

    if (!file) {
        perror("Error opening the model file");
        return -1;
    }

    if (fread(magic_number, 1, sizeof(magic_number), file) != sizeof(magic_number)) {
        printf("Invalid model file %s: missing header\n", filename);
        fclose(file);
        return -1;
    }

    if (memcmp(magic_number, "model", sizeof(magic_number)) != 0) {
        printf("Invalid model file %s: unknown file type\n", filename);
        fclose(file);
        return -1;
    }

    for (int t = 0; t < N_TREES; t++) {
        for (int n = 0; n < N_NODE_AND_LEAFS; n++) {
            token_t *dst = &tree_buf[t * N_NODE_AND_LEAFS + n];

            if (fread(dst, sizeof(*dst), 1, file) != 1) {
                printf("Invalid model file %s: unexpected end of file at tree %i node %i\n",
                       filename, t, n);
                fclose(file);
                return -1;
            }
        }
    }

    fclose(file);
    printf("Loaded model from %s\n", filename);
    return 0;
}

static void get_mismatchs(uint8_t *predictions_hw, uint8_t *predictions_sw, int read_samples)
{
    int mismatchs = 0;

    for (int i = 0; i < read_samples; i++){
        if (predictions_hw[i] != predictions_sw[i]){
            mismatchs++;
            printf("Error %i predictions_hw,%i != predictions_sw,%i\n",
                   i, predictions_hw[i], predictions_sw[i]);
        }
    }

    printf("Num mismatch %i\n", mismatchs);
}

void show_logs(float population_accuracy[POPULATION], int active_population){

    int entries = active_population < 10 ? active_population : 10;

    for (int32_t p = 0; p < entries; p++){
        printf("RANKING %i -> %f \n", p, population_accuracy[p]);
    }
}

static int run_train_mode(const char *prog, int argc, char **argv)
{
    token_t *tree_buf = NULL;
    token_t *io_buf = NULL;
    uint8_t *predictions = NULL;
    const char *dataset_path;
    const char *model_output_path = "model.bin";
    int n_classes;
    int n_features;
    int read_samples;
    int sample_divisor = 10;
    int max_generations = 0;
    int active_population = POPULATION;
    int train_samples = 0;
    float exe_time_ms_hw;
    struct timespec startn, endn;
    unsigned long long sw_ns;

    float population_accuracy[POPULATION] = {0};
    float iteration_accuracy[MEMORY_ACU_SIZE] = {0};
    float mutation_factor = 0;
    float max_features[N_FEATURE] = {0};
    float min_features[N_FEATURE] = {0};
    float class_100x100[256] = {0};

    struct feature *features = NULL;
    struct feature *features_augmented = NULL;
    int ite_no_impru = 0;
    uint32_t used_trees = 0;
    uint32_t used_trees_test = 0;
    int generation_ite = 0;
    size_t tree_size;

    tree_data (*trees_population)[N_TREES][N_NODE_AND_LEAFS] = NULL;
    tree_data (*golden_tree)[N_NODE_AND_LEAFS] = NULL;
    int rc = 1;
    int arg_i = 1;

    if (argc < 1 || argc > 7) {
        print_train_usage(prog);
        return 1;
    }

    dataset_path = argv[0];

    if (arg_i < argc) {
        int parsed_sample_divisor;

        if (parse_int_arg(argv[arg_i], 1, INT_MAX, &parsed_sample_divisor) == 0) {
            sample_divisor = parsed_sample_divisor;
            arg_i++;
        } else {
            model_output_path = argv[arg_i++];
            if (arg_i < argc &&
                parse_int_arg(argv[arg_i], 1, INT_MAX, &sample_divisor) < 0) {
                printf("Invalid sample_divisor: %s\n", argv[arg_i]);
                print_train_usage(prog);
                return 1;
            }
            if (arg_i < argc) {
                arg_i++;
            }
        }
    }

    if (arg_i < argc &&
        parse_int_arg(argv[arg_i], 0, INT_MAX, &max_generations) < 0) {
        printf("Invalid max_generations: %s\n", argv[arg_i]);
        print_train_usage(prog);
        return 1;
    }
    if (arg_i < argc) {
        arg_i++;
    }

    if (arg_i < argc &&
        parse_int_arg(argv[arg_i], 1, POPULATION, &active_population) < 0) {
        printf("Invalid active_population: %s\n", argv[arg_i]);
        print_train_usage(prog);
        return 1;
    }
    if (arg_i < argc) {
        arg_i++;
    }

    if (arg_i < argc) {
        int quiet_arg;
        if (parse_int_arg(argv[arg_i], 0, 1, &quiet_arg) < 0) {
            printf("Invalid quiet flag: %s\n", argv[arg_i]);
            print_train_usage(prog);
            return 1;
        }
        quiet_esp = quiet_arg ? TRUE : FALSE;
        arg_i++;
    }
    if (arg_i < argc &&
        parse_int_arg(argv[arg_i], 0, POPULATION, &debug_candidates) < 0) {
        printf("Invalid debug_candidates: %s\n", argv[arg_i]);
        print_train_usage(prog);
        return 1;
    }

    predictions = malloc(MAX_TEST_SAMPLES * sizeof(*predictions));
    features = calloc(MAX_TEST_SAMPLES, sizeof(*features));
    features_augmented = calloc(MAX_TEST_SAMPLES * 10, sizeof(*features_augmented));
    trees_population = calloc(POPULATION, sizeof(*trees_population));
    golden_tree = calloc(N_TREES, sizeof(*golden_tree));

    if (!predictions || !features || !features_augmented || !trees_population || !golden_tree) {
        perror("Failed to allocate training buffers");
        goto out;
    }

    for (int p = 0; p < active_population; p++)
        initialize_trees(trees_population[p]);
        
    initialize_trees(golden_tree);

    srand(clock());

    printf("\nTrain mode 1 ====== %s ======\n\n", cfg_000[0].devname);

    // Cargar dataset desde el archivo recibido por línea de comandos
    printf("Cargando features desde %s...\n", dataset_path);
    read_samples = read_n_features(dataset_path, MAX_TEST_SAMPLES, features, &n_features);
    if (read_samples < 0) {
        goto out;
    }
    if (read_samples == 0) {
        printf("No samples found in training dataset\n");
        goto out;
    }
    if (n_features < 2 || n_features > N_FEATURE + 1) {
        printf("Invalid training dataset: expected between 2 and %i columns (features + class), read %i.\n",
               N_FEATURE + 1, n_features);
        goto out;
    }
    n_features--; // remove predictions
    if (n_features < N_FEATURE) {
        printf("Detected %i features per sample; padding remaining %i features with zero for the RTL format.\n",
               n_features, N_FEATURE - n_features);
    }

    find_max_min_features(features, max_features, min_features, read_samples);
    find_n_classes(features, &n_classes, read_samples);
    if (n_classes >= N_CLASSES) {
        printf("Invalid training dataset: max class %i exceeds supported max class %i\n",
               n_classes, N_CLASSES - 1);
        goto out;
    }
    {
        int declared_features = n_features;
        n_features = effective_feature_count(n_features, max_features, min_features);
        if (n_features != declared_features) {
            printf("Detected %i active features; ignoring %i trailing zero-padded features from the input format.\n",
                   n_features, declared_features - n_features);
        }
    }
    printf("Num clases of the dataset %i\n", n_classes);
    printf("Num features_read from the dataset %i\n", read_samples);
    printf("Num n_features from the dataset %i\n", n_features);
    printf("Training config: model_out=%s sample_divisor=%i max_generations=%i active_population=%i quiet=%i debug_candidates=%i\n",
           model_output_path, sample_divisor, max_generations, active_population, quiet_esp,
           debug_candidates);
    printf("Training DMA: separate tree/io buffers\n");

    read_samples = augment_features(features, read_samples, n_features, 
                                    max_features, min_features, features_augmented,
                                    MAX_TEST_SAMPLES*10, 0);
    shuffle(features_augmented, read_samples);

    {
        int available_samples = read_samples;
        read_samples /= sample_divisor; // reduce the amount of samples
        if (read_samples < 8 && available_samples >= 8) {
            read_samples = 8;
        } else if (read_samples < 1) {
            read_samples = 1;
        }
        if (read_samples >= 8) {
            read_samples = (read_samples / 8) * 8;
        }
    }
    printf("Training samples used: %i\n", read_samples);
    train_samples = read_samples * 80 / 100;
    if (train_samples < 1) {
        train_samples = read_samples;
    }

    init_parameters();

    tree_size = N_TREES * N_NODE_AND_LEAFS * sizeof(token_t);
    tree_buf = (token_t *)esp_alloc(tree_size);
    io_buf = (token_t *)esp_alloc(size);
    if (!tree_buf || !io_buf) {
        perror("Failed to allocate ESP buffers");
        goto out;
    }

    for (size_t boosting_i = 0; boosting_i < N_TREES / N_BOOSTING; boosting_i++){
        used_trees = (boosting_i + 1)*N_BOOSTING;
        generation_ite = 0;
        shuffle(features_augmented, read_samples);

        for (uint32_t p = 0; p < (uint32_t)active_population; p++)
            generate_random_trees(trees_population[p], n_features, boosting_i,
                                    max_features, min_features, n_classes);

        while(1){
            gettime(&startn);
            train_model(trees_population, tree_buf, io_buf, features_augmented, 
                            train_samples, population_accuracy, 
                            0, &used_trees, n_classes, active_population);
            gettime(&endn);
            sw_ns = ts_subtract(&startn, &endn);
            printf("Infe\t\t time: %f s\n", sw_ns/1000000000.0);
        
            gettime(&startn);
            reorganize_population(population_accuracy, trees_population, used_trees,
                                  active_population);
            gettime(&endn);
            sw_ns = ts_subtract(&startn, &endn);
            printf("reorganize\t time: %f s\n", sw_ns/1000000000.0);

            /////////////////////////////// tests ///////////////////////////////
            show_logs(population_accuracy, active_population);
            // evaluation features from out the training dataset
            printf("Boosting iteration %zu of %i\n", boosting_i, N_TREES / N_BOOSTING);
            used_trees_test = used_trees - N_BOOSTING; // number of trees used on the previous iteration
            if (used_trees_test > 0){
                coppy_trees(golden_tree, tree_buf);
                evaluate_model(tree_buf, io_buf, features_augmented, read_samples, n_classes, 
                                        predictions, MAX_BURST, &exe_time_ms_hw, TRUE);
            }
            /////////////////////////////////////////////////////////////////////
            
            gettime(&startn);
            if(population_accuracy[0] >= 1 || ite_no_impru > MAX_NO_IMPRU ||
               (max_generations > 0 && generation_ite + 1 >= max_generations)){
                ite_no_impru = 0;
                shuffle(features_augmented, train_samples);
                for (int accuracy_i = 0; accuracy_i < MEMORY_ACU_SIZE; accuracy_i++){
                    iteration_accuracy[accuracy_i] = 0;
                }
                break;
            }

            mutate_population(trees_population, population_accuracy, max_features,
                                min_features, n_features, mutation_factor, boosting_i, n_classes,
                                class_100x100, used_trees, active_population);

            crossover(trees_population, boosting_i, active_population);

            generation_ite ++;
            mutation_factor = 0;
            iteration_accuracy[generation_ite % MEMORY_ACU_SIZE] = population_accuracy[0];
            for (int accuracy_i = 0; accuracy_i < MEMORY_ACU_SIZE; accuracy_i++){
                if(iteration_accuracy[generation_ite % MEMORY_ACU_SIZE] <= iteration_accuracy[accuracy_i]){
                    if ((generation_ite % MEMORY_ACU_SIZE) != accuracy_i){
                        mutation_factor += 0.02;
                    }
                }
            }

            if (mutation_factor >= (MEMORY_ACU_SIZE - 2)*0.02){
                ite_no_impru++;
            }else{
                ite_no_impru = 0;
            }
            
            printf("Mutation_factor %f ite_no_impru = %i\n", mutation_factor, ite_no_impru);
            printf("Generation ite %i index ite %i\n", generation_ite, generation_ite % MEMORY_ACU_SIZE);
            gettime(&endn);
            sw_ns = ts_subtract(&startn, &endn);
            printf("Rest\t\t time: %f s\n", sw_ns/1000000000.0);
        }

        // coppy the amount of trees trained up to this point
        for (uint32_t tree_i = 0; tree_i < used_trees; tree_i++){
            memcpy(golden_tree[tree_i], trees_population[0][tree_i], sizeof(tree_data) * N_NODE_AND_LEAFS);
        }
        for (uint32_t p = 1; p < (uint32_t)active_population; p++){
            for (uint32_t tree_i = 0; tree_i < used_trees; tree_i++){
                memcpy(trees_population[p][tree_i], trees_population[0][tree_i], sizeof(tree_data) * N_NODE_AND_LEAFS);
            }
        }
    }

    printf("Final evaluation !!!!\n\n");
    coppy_trees(golden_tree, tree_buf);
    evaluate_model(tree_buf, io_buf, features_augmented, read_samples, n_classes, 
        predictions, MAX_BURST, &exe_time_ms_hw, TRUE);

    printf("Exporting model to %s\n", model_output_path);
    if (export_model(golden_tree, model_output_path) < 0) {
        goto out;
    }

    rc = 0;

out:
    if (io_buf) esp_free(io_buf);
    if (tree_buf) esp_free(tree_buf);
    free(golden_tree);
    free(trees_population);
    free(features_augmented);
    free(features);
    free(predictions);

    return rc;
}

static int run_execute_mode(const char *prog, int argc, char **argv)
{
    token_t *tree_buf = NULL;
    token_t *io_buf = NULL;
    struct feature *features = NULL;
    uint8_t *predictions_sw = NULL;
    uint8_t *predictions_hw = NULL;
    const char *dataset_path;
    const char *model_path;
    int n_classes;
    int n_features;
    int read_samples;
    float exe_time_ms_hw = 0.0f;
    float exe_time_ms_sw = 0.0f;
    size_t tree_size;
    int rc = 1;

    if (argc < 2 || argc > 3) {
        print_execute_usage(prog);
        return 1;
    }

    dataset_path = argv[0];
    model_path = argv[1];

    if (argc == 3) {
        int quiet_arg;
        if (parse_int_arg(argv[2], 0, 1, &quiet_arg) < 0) {
            printf("Invalid quiet flag: %s\n", argv[2]);
            print_execute_usage(prog);
            return 1;
        }
        quiet_esp = quiet_arg ? TRUE : FALSE;
    }

    predictions_sw = malloc(MAX_TEST_SAMPLES * sizeof(*predictions_sw));
    predictions_hw = malloc(MAX_TEST_SAMPLES * sizeof(*predictions_hw));
    features = calloc(MAX_TEST_SAMPLES, sizeof(*features));
    if (!predictions_sw || !predictions_hw || !features) {
        perror("Failed to allocate execute buffers");
        goto out;
    }

    printf("\nExecute mode ====== %s ======\n\n", cfg_000[0].devname);

    printf("Cargando features desde %s...\n", dataset_path);
    read_samples = read_n_features(dataset_path, MAX_TEST_SAMPLES, features, &n_features);
    if (read_samples < 0) {
        goto out;
    }
    if (read_samples == 0) {
        printf("No samples found in execute dataset\n");
        goto out;
    }
    if (n_features < 2 || n_features > N_FEATURE + 1) {
        printf("Invalid execute dataset: expected between 2 and %i columns (features + class), read %i.\n",
               N_FEATURE + 1, n_features);
        goto out;
    }

    n_features--;
    if (n_features < N_FEATURE) {
        printf("Detected %i features per sample; padding remaining %i features with zero for the RTL format.\n",
               n_features, N_FEATURE - n_features);
    }

    find_n_classes(features, &n_classes, read_samples);
    if (n_classes >= N_CLASSES) {
        printf("Invalid execute dataset: max class %i exceeds supported max class %i\n",
               n_classes, N_CLASSES - 1);
        goto out;
    }
    printf("Num clases of the dataset %i\n", n_classes);
    printf("Num features_read from the dataset %i\n", read_samples);
    printf("Num n_features from the dataset %i\n", n_features);
    printf("Execute config: model=%s quiet=%i\n", model_path, quiet_esp);

    init_parameters();
    tree_size = N_TREES * N_NODE_AND_LEAFS * sizeof(token_t);
    tree_buf = (token_t *)esp_alloc(tree_size);
    io_buf = (token_t *)esp_alloc(size);
    if (!tree_buf || !io_buf) {
        perror("Failed to allocate ESP buffers");
        goto out;
    }

    printf("Cargando modelo desde %s...\n", model_path);
    if (load_model(tree_buf, model_path) < 0) {
        goto out;
    }

    printf("evaluate_model software\n");
    software_prediction_packed(features, read_samples, tree_buf, n_classes,
                               predictions_sw, &exe_time_ms_sw);

    printf("evaluate_model hardware\n");
    evaluate_model(tree_buf, io_buf, features, read_samples, n_classes,
                   predictions_hw, MAX_BURST, &exe_time_ms_hw, TRUE);

    if (exe_time_ms_hw > 0.0f) {
        printf("Speed up hardware vs software %f\n", exe_time_ms_sw / exe_time_ms_hw);
    }

    get_mismatchs(predictions_hw, predictions_sw, read_samples);
    rc = 0;

out:
    if (io_buf) esp_free(io_buf);
    if (tree_buf) esp_free(tree_buf);
    free(features);
    free(predictions_hw);
    free(predictions_sw);

    return rc;
}

int main(int argc, char **argv)
{
    if (argc < 2 || strcmp(argv[1], "--help") == 0 || strcmp(argv[1], "-h") == 0) {
        print_usage(argv[0]);
        return argc < 2 ? 1 : 0;
    }

    if (strcmp(argv[1], "--train") == 0 || strcmp(argv[1], "-t") == 0 ||
        strcmp(argv[1], "train") == 0) {
        return run_train_mode(argv[0], argc - 2, &argv[2]);
    }

    if (strcmp(argv[1], "--execute") == 0 || strcmp(argv[1], "-e") == 0 ||
        strcmp(argv[1], "execute") == 0) {
        return run_execute_mode(argv[0], argc - 2, &argv[2]);
    }

    printf("Unknown mode: %s\n", argv[1]);
    print_usage(argv[0]);
    return 1;
}
