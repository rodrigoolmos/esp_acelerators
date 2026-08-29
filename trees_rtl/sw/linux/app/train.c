#include "train.h"

uint8_t right_index[255] =  {128, 65, 34, 19, 12, 9, 8, 0, 0, 11, 0, 0, 16, 15, 0, 0, 18, 0, 0, 27, 24, 23, 0, 0, 26, 0, 0, 31, 30, 0, 0, 33, 0, 0, 50, 43, 40, 39, 0, 0, 42, 0, 0, 47, 46, 0, 0, 49, 0, 0, 58, 55, 54, 0, 0, 57, 0, 0, 62, 61, 0, 0, 64, 0, 0, 97, 82, 75, 72, 71, 0, 0, 74, 0, 0, 79, 78, 0, 0, 81, 0, 0, 90, 87, 86, 0, 0, 89, 0, 0, 94, 93, 0, 0, 96, 0, 0, 113, 106, 103, 102, 0, 0, 105, 0, 0, 110, 109, 0, 0, 112, 0, 0, 121, 118, 117, 0, 0, 120, 0, 0, 125, 124, 0, 0, 127, 0, 0, 192, 161, 146, 139, 136, 135, 0, 0, 138, 0, 0, 143, 142, 0, 0, 145, 0, 0, 154, 151, 150, 0, 0, 153, 0, 0, 158, 157, 0, 0, 160, 0, 0, 177, 170, 167, 166, 0, 0, 169, 0, 0, 174, 173, 0, 0, 176, 0, 0, 185, 182, 181, 0, 0, 184, 0, 0, 189, 188, 0, 0, 191, 0, 0, 224, 209, 202, 199, 198, 0, 0, 201, 0, 0, 206, 205, 0, 0, 208, 0, 0, 217, 214, 213, 0, 0, 216, 0, 0, 221, 220, 0, 0, 223, 0, 0, 240, 233, 230, 229, 0, 0, 232, 0, 0, 237, 236, 0, 0, 239, 0, 0, 248, 245, 244, 0, 0, 247, 0, 0, 252, 251, 0, 0, 254, 0, 0};

float generate_random_float(float min, float max, unsigned int *seed) {
    if (!isfinite(min) || !isfinite(max)) {
        return 0.0f;
    }
    if (max <= min) {
        return min;
    }

    float random = (float)rand_r(seed) / RAND_MAX;

    float distance = max - min;
    float step = distance * 0.01; // 1% de la distancia

    return min + round(random * (distance / step)) * step; // Multiplicamos por step para ajustar el paso
}

float generate_random_float_0_1(unsigned int *seed) {
    int boolean = (rand_r(seed) % 2);

    return (float)boolean;
}

float generate_threshold(float min, float max, unsigned int *seed) {
    float random_threshold;

    if(min == 0 && max == 1){
        random_threshold = generate_random_float_0_1(seed);
    }else{
        random_threshold = generate_random_float(min, max, seed);
    }

    return random_threshold;
}

float generate_leaf_value(unsigned int *seed,
                          int   n_classes,           // N en tu caso (clases 0…N)
                          const float *class_accuracy)
{
    const float beta = 0.5f;          // mezcla explotación/exploración
    int K = n_classes + 1;            // clases de 0 a N
    float weights[256];
    float total_w = 0.0f;
    float const_term = (1.0f - beta * 0.5f) / (float)K;

    // Probabilidad de no votar = 25%
    if ((rand_r(seed) & 0x3) == 0) {
        return NULL_VOTE;
    }

    // 1) Calcula los pesos mixtos w[k]
    for (int k = 0; k < K; k++) {
        float err = 1.0f - class_accuracy[k];      // en [0..1]
        // w_k = 2·β·err + (1 - β/2)/K
        float w = 2.0f * beta * err + const_term;
        weights[k] = w;
        total_w   += w;
    }

    // 2) Si todas las clases están resueltas, devolvemos NULL_VOTE
    if (total_w <= 0.0f) {
        return NULL_VOTE;
    }

    // 3) Muestreo ponderado sobre [0..total_w)
    float r = ((float)rand_r(seed) / (float)RAND_MAX) * total_w;
    float cumsum = 0.0f;
    int chosen = K - 1;  // por defecto la última clase
    for (int k = 0; k < K; k++) {
        cumsum += weights[k];
        if (r < cumsum) {
            chosen = k;
            break;
        }
    }

    // 4) Si la clase elegida está al 100% de accuracy,
    //    tenemos un 50% de probabilidad de abstenernos
    if (class_accuracy[chosen] >= 0.99f) {
        // rand_r devuelve 0..RAND_MAX, comparamos con RAND_MAX/2
        if ((rand_r(seed) & 0x1) == 0) {
            return NULL_VOTE;
        }
    }

    // 5) De lo contrario devolvemos la clase elegida
    return (float)chosen;
}


uint8_t generate_leaf_node(uint8_t prob__leaf_node, unsigned int *seed) {
    uint8_t random_8 = (uint8_t)rand_r(seed) % 100;

    return random_8 > prob__leaf_node;
}

uint8_t generate_feture_index(uint8_t feature_length, unsigned int *seed) {
    uint8_t random_8 = (uint8_t)rand_r(seed) % feature_length;

    return random_8;
}

void initialize_trees(tree_data trees[N_TREES][N_NODE_AND_LEAFS]){
    
    for (int t = 0; t < N_TREES; t++)
        for (int n = 0; n < N_NODE_AND_LEAFS; n++)
            trees[t][n].tree_camps.float_int_union.i=NULL_VOTE;
    
}

void generate_random_trees(tree_data trees[N_TREES][N_NODE_AND_LEAFS], 
                    uint8_t n_features, uint16_t boosting_i, float max_features[N_FEATURE],
                    float min_features[N_FEATURE], int n_classes) {

    srand(clock());
    uint8_t n_feature;
    unsigned int seed = (unsigned int)(uintptr_t)trees;
    float class_100x100[256] = {0};

    for (uint32_t tree_i = boosting_i * N_BOOSTING; 
                tree_i < (boosting_i + 1) * N_BOOSTING && tree_i < N_TREES; tree_i++) {
        for (uint32_t node_i = 0; node_i < N_NODE_AND_LEAFS - 1; node_i++) {
            seed = seed + time(NULL) + tree_i + node_i;
            trees[tree_i][node_i].tree_camps.feature_index = generate_feture_index(n_features, &seed);
            n_feature = trees[tree_i][node_i].tree_camps.feature_index;
            
            trees[tree_i][node_i].tree_camps.leaf_or_node = 
                   (right_index[node_i] == 0) ? 0x00 : generate_leaf_node(60, &seed);

            if (node_i < 4) {
                trees[tree_i][node_i].tree_camps.leaf_or_node = 1;
            }

            if (trees[tree_i][node_i].tree_camps.leaf_or_node == 0) {
                trees[tree_i][node_i].tree_camps.float_int_union.i =
                    generate_leaf_value(&seed, n_classes, class_100x100);
            } else {
                trees[tree_i][node_i].tree_camps.float_int_union.f =
                    generate_threshold(min_features[n_feature], max_features[n_feature], &seed);
            }
               
            trees[tree_i][node_i].tree_camps.next_node_right_index = right_index[node_i];
        }
    }
}

void mutate_trees(tree_data input_tree[N_TREES][N_NODE_AND_LEAFS], 
                 tree_data output_tree[N_TREES][N_NODE_AND_LEAFS],
                 uint8_t n_features, float mutation_rate, 
                 uint32_t boosting_i, float max_features[N_FEATURE], float min_features[N_FEATURE],
                  unsigned int *seed, int n_classes, float class_100x100[],
                  uint32_t used_trees) {

    uint32_t mutation_threshold = mutation_rate * RAND_MAX;
    uint8_t n_feature;
    uint32_t mutation_value;
    memcpy(output_tree, input_tree, sizeof(tree_data) * used_trees * N_NODE_AND_LEAFS);
    
    for (uint32_t tree_i = boosting_i * N_BOOSTING; 
                tree_i < (boosting_i + 1) * N_BOOSTING && tree_i < N_TREES; tree_i++){

        for (uint32_t node_i = 0; node_i < N_NODE_AND_LEAFS - 1; node_i++){
            *seed = *seed + tree_i;
            mutation_value = rand_r(seed);
            if (mutation_value < mutation_threshold){
                *seed = *seed + node_i;
                output_tree[tree_i][node_i].tree_camps.feature_index = generate_feture_index(n_features, seed);
                n_feature = output_tree[tree_i][node_i].tree_camps.feature_index;
                output_tree[tree_i][node_i].tree_camps.leaf_or_node =  
                    (right_index[node_i] == 0) ? 0x00 : generate_leaf_node(60, seed);
                if (node_i < 4){
                    output_tree[tree_i][node_i].tree_camps.leaf_or_node = 1;
                }

                if (output_tree[tree_i][node_i].tree_camps.leaf_or_node == 0){
                    output_tree[tree_i][node_i].tree_camps.float_int_union.i =
                        generate_leaf_value(seed, n_classes, class_100x100);
                }else{
                    output_tree[tree_i][node_i].tree_camps.float_int_union.f =
                        generate_threshold(min_features[n_feature], max_features[n_feature], seed);
                }

                output_tree[tree_i][node_i].tree_camps.next_node_right_index = right_index[node_i];
            }
        }
    }
}

void tune_nodes(tree_data input_tree[N_TREES][N_NODE_AND_LEAFS], 
                 tree_data output_tree[N_TREES][N_NODE_AND_LEAFS],
                 uint8_t n_features, float mutation_rate, 
                 uint32_t boosting_i, float max_features[N_FEATURE], float min_features[N_FEATURE],
                 unsigned int *seed, uint32_t used_trees) {

    uint32_t mutation_threshold = mutation_rate * RAND_MAX;
    uint8_t n_feature;
    memcpy(output_tree, input_tree, sizeof(tree_data) * used_trees * N_NODE_AND_LEAFS);
    
    for (uint32_t tree_i = boosting_i * N_BOOSTING; 
                tree_i < (boosting_i + 1) * N_BOOSTING && tree_i < N_TREES; tree_i++){

        *seed = *seed + tree_i;
        uint32_t mutation_value = rand_r(seed);
        if (mutation_value < mutation_threshold){
            for (uint32_t node_i = 0; node_i < N_NODE_AND_LEAFS - 1; node_i++){
                *seed = *seed + node_i;

                n_feature = output_tree[tree_i][node_i].tree_camps.feature_index;

                if (output_tree[tree_i][node_i].tree_camps.leaf_or_node){
                    output_tree[tree_i][node_i].tree_camps.float_int_union.f +=
                        generate_threshold(min_features[n_feature]/10, max_features[n_feature]/10, seed);
                }
            }
        }
    }
}

void reproducee_trees(tree_data mother[N_TREES][N_NODE_AND_LEAFS],
                        tree_data father[N_TREES][N_NODE_AND_LEAFS],
                        tree_data son[N_TREES][N_NODE_AND_LEAFS], uint32_t boosting_i){


    for (uint32_t tree_i = boosting_i * N_BOOSTING; 
                tree_i < (boosting_i + 1) * N_BOOSTING && tree_i < N_TREES; tree_i++){

        if(rand() % 2){
            memcpy(son[tree_i], mother[tree_i], sizeof(tree_data) * N_NODE_AND_LEAFS);
        }else{
            memcpy(son[tree_i], father[tree_i], sizeof(tree_data) * N_NODE_AND_LEAFS);
        }
    }
}

void crossover(tree_data trees_population[POPULATION][N_TREES][N_NODE_AND_LEAFS],
               uint32_t boosting_i, int active_population){

    int group_size = active_population / 80;
    if (group_size == 0) group_size = 1;

    for (uint32_t p = active_population - active_population/10;
         p < (uint32_t)active_population; p++){
        int index_mother = rand() % group_size;
        int index_father = rand() % group_size + group_size;

        reproducee_trees(trees_population[index_mother], trees_population[index_father],
                                trees_population[p], boosting_i);
    }

}

void mutate_population(tree_data trees_population[POPULATION][N_TREES][N_NODE_AND_LEAFS],
                        float population_accuracy[POPULATION], float max_features[N_FEATURE],
                        float min_features[N_FEATURE], uint8_t n_features, float mutation_factor, 
                        uint32_t boosting_i, int n_classes, float class_100x100[],
                        uint32_t used_trees, int active_population){

    int elite_count = active_population / 4;
    size_t model_bytes = sizeof(tree_data) * used_trees * N_NODE_AND_LEAFS;
    tree_data (*local_tree)[N_NODE_AND_LEAFS] = malloc(model_bytes);

    if (!local_tree) {
        perror("Failed to allocate mutation buffer");
        return;
    }

    if (elite_count < 1) {
        elite_count = 1;
    }

    for (uint32_t p = elite_count; p < (uint32_t)active_population; p++) {
        unsigned int seed = time(NULL) + p;
        int index_elite = rand_r(&seed) % elite_count;

        memcpy(local_tree, trees_population[index_elite], model_bytes);
        int threshold = (int)((active_population/8)* population_accuracy[index_elite]);
        if (index_elite < threshold || mutation_factor >= (MEMORY_ACU_SIZE - 2)*0.02){
            tune_nodes(local_tree, trees_population[p], n_features,
                        0.5 + mutation_factor*3,
                        boosting_i, max_features, min_features, &seed, used_trees);
        }else{
            mutate_trees(local_tree, trees_population[p], n_features,
                        0.5 + mutation_factor,
                        boosting_i, max_features, min_features, &seed, n_classes,
                        class_100x100, used_trees);
        }
        
    }

    free(local_tree);
}

void swap_int(int *a, int *b) {
    int temp = *a;
    *a = *b;
    *b = temp;
}

void swap_float(float *a, float *b) {
    float temp = *a;
    *a = *b;
    *b = temp;
}

// Ordenamiento por índices (sin tocar los datos pesados)
int partition(const float population_accuracy[POPULATION], int idx[POPULATION], int low, int high) {
    float pivot = population_accuracy[idx[high]];
    int i = low - 1;
    for (int j = low; j < high; j++) {
        if (population_accuracy[idx[j]] > pivot) {
            i++;
            swap_int(&idx[i], &idx[j]);
        }
    }
    swap_int(&idx[i + 1], &idx[high]);
    return i + 1;
}

void quicksort_idx(const float population_accuracy[POPULATION], int idx[POPULATION], int low, int high) {
    while (low < high) {
        int pi = partition(population_accuracy, idx, low, high);
        if (pi - low < high - pi) {
            quicksort_idx(population_accuracy, idx, low, pi - 1);
            low = pi + 1;
        } else {
            quicksort_idx(population_accuracy, idx, pi + 1, high);
            high = pi - 1;
        }
    }
}

void swap_trees(float population_accuracy[POPULATION], 
                tree_data trees_population[POPULATION][N_TREES][N_NODE_AND_LEAFS],
                int used_trees, int active_population) {

    int idx[POPULATION];
    float *temp_accuracy;
    uint8_t *temp_trees;
    size_t model_bytes = sizeof(tree_data) * used_trees * N_NODE_AND_LEAFS;

    for (int i = 0; i < active_population; i++) {
        idx[i] = i;
    }

    // 1. Ordenar índices según accuracy
    quicksort_idx(population_accuracy, idx, 0, active_population - 1);

    // 2. Reordenar temporalmente los datos
    temp_accuracy = malloc(sizeof(float) * active_population);
    temp_trees = malloc(model_bytes * active_population);
    if (!temp_accuracy || !temp_trees) {
        perror("Failed to allocate sorting buffers");
        free(temp_trees);
        free(temp_accuracy);
        return;
    }

    for (int i = 0; i < active_population; i++) {
        temp_accuracy[i] = population_accuracy[idx[i]];
        memcpy(temp_trees + (size_t)i * model_bytes, trees_population[idx[i]], model_bytes);
    }

    // 3. Volcar los datos ya ordenados a las estructuras originales
    memcpy(population_accuracy, temp_accuracy, sizeof(float) * active_population);
    for (int i = 0; i < active_population; i++) {
        memcpy(trees_population[i], temp_trees + (size_t)i * model_bytes, model_bytes);
    }

    free(temp_trees);
    free(temp_accuracy);
}

void randomize_percent(float population_accuracy[POPULATION], 
                       tree_data trees_population[POPULATION][N_TREES][N_NODE_AND_LEAFS],
                       float percentage_randomize, int used_trees, int active_population) {

    int N = active_population;
    int M = (int)(N * percentage_randomize);
    if (M < 1) M = 1;
    if (M > N - 1) M = N - 1;
    if (M < 1) return;

    int selected_idx[M];
    float *tmp_accuracy;
    uint8_t *tmp_trees;
    uint8_t *tmp;
    size_t model_bytes = sizeof(tree_data) * used_trees * N_NODE_AND_LEAFS;

    tmp_accuracy = malloc(sizeof(float) * M);
    tmp_trees = malloc(model_bytes * M);
    tmp = malloc(model_bytes);

    if (!tmp_accuracy || !tmp_trees || !tmp) {
        perror("Failed to allocate randomize buffers");
        free(tmp);
        free(tmp_trees);
        free(tmp_accuracy);
        return;
    }

    for (int i = 0; i < M; i++) {
        selected_idx[i] = i + 1;  // ignoramos el índice 0
    }

    // Mezclar los índices seleccionados
    for (int i = M - 1; i > 0; i--) {
        int j = rand() % (i + 1);
        swap_int(&selected_idx[i], &selected_idx[j]);
    }

    // Reordenar localmente
    for (int i = 0; i < M; i++) {
        int idx = selected_idx[i];
        tmp_accuracy[i] = population_accuracy[idx];
        memcpy(tmp_trees + (size_t)i * model_bytes, trees_population[idx], model_bytes);
    }

    // Reordenar (mezclar)
    for (int i = M - 1; i > 0; i--) {
        int j = rand() % (i + 1);
        swap_float(&tmp_accuracy[i], &tmp_accuracy[j]);

        memcpy(tmp, tmp_trees + (size_t)i * model_bytes, model_bytes);
        memcpy(tmp_trees + (size_t)i * model_bytes, tmp_trees + (size_t)j * model_bytes,
               model_bytes);
        memcpy(tmp_trees + (size_t)j * model_bytes, tmp, model_bytes);
    }

    // Volcar elementos mezclados de vuelta
    for (int i = 0; i < M; i++) {
        int idx = selected_idx[i];
        population_accuracy[idx] = tmp_accuracy[i];
        memcpy(trees_population[idx], tmp_trees + (size_t)i * model_bytes, model_bytes);
    }

    free(tmp);
    free(tmp_trees);
    free(tmp_accuracy);
}

void reorganize_population(float population_accuracy[POPULATION], 
                    tree_data trees_population[POPULATION][N_TREES][N_NODE_AND_LEAFS],
                    int used_trees, int active_population) {

    swap_trees(population_accuracy, trees_population, used_trees, active_population);
    randomize_percent(population_accuracy, trees_population, 0.25f, used_trees,
                      active_population);
}

void find_max_min_features(struct feature features[MAX_TEST_SAMPLES],
                                float max_features[N_FEATURE], 
                                float min_features[N_FEATURE],
                                int read_samples) {

    for (int j = 0; j < N_FEATURE; j++) {
        max_features[j] = features[0].features[j];
        min_features[j] = features[0].features[j];
    }

    for (int i = 1; i < read_samples; i++) {
        for (int j = 0; j < N_FEATURE; j++) {
            if (features[i].features[j] > max_features[j]) {
                max_features[j] = features[i].features[j];
            }
            if (features[i].features[j] < min_features[j]) {
                min_features[j] = features[i].features[j];
            }
        }
    }
}

void find_n_classes(struct feature features[MAX_TEST_SAMPLES], int *n_classes, int read_samples)
{

    *n_classes = features[0].prediction;

    for (int i = 1; i < read_samples; i++) {
        if (*n_classes < features[i].prediction) { *n_classes = features[i].prediction; }
    }
}

void swap_features(struct feature* a, struct feature* b) {
    struct feature temp = *a;
    *a = *b;
    *b = temp;
}

void shuffle(struct feature* array, int n) {
    for (int i = n - 1; i > 0; i--) {
        int j = rand() % (i + 1);
        swap_features(&array[i], &array[j]);
    }
}

int augment_features(const struct feature *original_features, int n_features, int n_col,
                     float max_features[N_FEATURE], float min_features[N_FEATURE],
                     struct feature *augmented_features, int max_augmented_features, 
                     int augmentation_factor) {

    int total_augmented = 0;
    int i, j, k;
    unsigned int seed;


    // Semilla para el generador de números aleatorios
    srand((unsigned int)time(NULL));

    for (i = 0; i < n_features; i++) {
        // Verificar si hay espacio en augmented_features
        if (total_augmented >= max_augmented_features) {
            break;
        }

        // Copiar la muestra original al arreglo de aumentados
        augmented_features[total_augmented] = original_features[i];
        total_augmented++;

        // Generar muestras aumentadas
        for (j = 0; j < augmentation_factor; j++) {
            if (total_augmented >= max_augmented_features) {
                break;
            }

            struct feature new_feature = original_features[i];

            // Agregar ruido aleatorio a cada característica
            for (k = 0; k < n_col && k < N_FEATURE; k++) {
                seed = i*n_col*augmentation_factor + j*n_col + k;
                if (!(min_features == 0 && max_features == 0)){
                    float noise = generate_random_float(min_features[k]/10, max_features[k]/10, &seed);
                    new_feature.features[k] += noise;
                }
                
            }

            // Mantener la misma predicción
            new_feature.prediction = original_features[i].prediction;

            // Agregar la nueva muestra al arreglo de aumentados
            augmented_features[total_augmented] = new_feature;
            total_augmented++;
        }
    }

    return total_augmented;
}
