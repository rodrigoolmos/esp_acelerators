#ifndef __TRAIN_H__
#define __TRAIN_H__

#include <math.h>
#include <time.h>
#include <stdio.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <float.h>
#include <limits.h>
#include <omp.h>

#define POPULATION 128
#define MEMORY_ACU_SIZE 10
#define MAX_NO_IMPRU 1

#define N_BOOSTING 32

#define N_NODE_AND_LEAFS 256    // Adjust according to the maximum number of nodes and leaves in your trees
#define N_TREES 128             // Adjust according to the number of trees in your model
#define N_FEATURE 32            // Adjust according to the number of features in your model
#define MAX_TEST_SAMPLES 30000  // Adjust according to the maximum number of test samples
#define MAX_LINE_LENGTH 1024    // Adjust according to the maximum line length in your CSV file
#define N_CLASSES 32            // Adjust according to the number of classes in your model
#define MAX_BURST 5000          // Adjust according to the maximum amount of somples to process in 1 busrt
#define NULL_VOTE -1

#define FALSE 0
#define TRUE  1


typedef union {
  float f;
  int32_t i;
} float_int_union_t;

struct tree_camps {
  uint8_t leaf_or_node;
  uint8_t feature_index;
  uint8_t next_node_right_index;
  uint8_t padding;
  float_int_union_t float_int_union;
};

typedef union {
  struct tree_camps tree_camps;
  uint64_t compact_data;
} tree_data;

struct feature {
  float features[N_FEATURE];
  uint8_t prediction;
};

void generate_random_trees(tree_data trees[N_TREES][N_NODE_AND_LEAFS], 
                    uint8_t n_features, uint16_t boosting_i, float max_features[N_FEATURE],
                    float min_features[N_FEATURE], int n_classes);

void mutate_population(tree_data trees_population[POPULATION][N_TREES][N_NODE_AND_LEAFS],
                        float population_accuracy[POPULATION], float max_features[N_FEATURE],
                        float min_features[N_FEATURE], uint8_t n_features, float mutation_factor, 
                        uint32_t boosting_i, int n_classes, float class_100x100[],
                        uint32_t used_trees, int active_population);

void crossover(tree_data trees_population[POPULATION][N_TREES][N_NODE_AND_LEAFS],
               uint32_t boosting_i, int active_population);

void reorganize_population(float population_accuracy[POPULATION], 
                           tree_data trees_population[POPULATION][N_TREES][N_NODE_AND_LEAFS],
                           int used_trees, int active_population);

int augment_features(const struct feature *original_features, int n_features, int n_col,
                     float max_features[N_FEATURE], float min_features[N_FEATURE],
                     struct feature *augmented_features, int max_augmented_features, 
                     int augmentation_factor);

void find_max_min_features(struct feature features[MAX_TEST_SAMPLES],
                                float max_features[N_FEATURE], 
                                float min_features[N_FEATURE],
                                int read_samples);

float generate_random_float(float min, float max, unsigned int *seed);

void swap_features(struct feature* a, struct feature* b);

void shuffle(struct feature* array, int n);

void find_n_classes(struct feature features[MAX_TEST_SAMPLES], int *n_classes, 
                                                            int read_samples);

void initialize_trees(tree_data trees[N_TREES][N_NODE_AND_LEAFS]);
#endif // __TRAIN_H__
