# Validar si la variable no está vacía
if {$top_simu == ""} {
    error "No se especificó el nombre del módulo top.!!!!!!!!!!!!!!!!"
} else {
    puts "Simulando el módulo top: $top_simu"
}

# Define el directorio de trabajo
cd ./questasim

# Crea una librería de trabajo
vlib work

# Definir las rutas del RTL y del testbench, relativas a hw/tb/questasim.
set tb_path ..
set rtl_path ../../src/trees_rtl_basic_dma64

set sv_files [list \
    $rtl_path/tree.sv \
    $rtl_path/trees.sv \
    $rtl_path/trees_ping_pong.sv \
    $rtl_path/trees_rtl_basic_dma64.sv \
    $tb_path/tb_esp_trees.sv \
]

foreach file $sv_files {
    vlog +sv +incdir+$tb_path $file
}

# Carga el testbench o módulo principal en QuestaSim, habilitando el rastreo de aserciones.
vsim -assertdebug -voptargs=+acc work.$top_simu

# Ejecuta la simulación por un tiempo específico
run 1000ns

restart
